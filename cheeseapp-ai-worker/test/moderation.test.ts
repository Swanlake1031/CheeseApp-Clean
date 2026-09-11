import test from 'node:test';
import assert from 'node:assert/strict';
import { approvedVerdict, boundedBytes, handleModeratedUpload, MEDIA_MODEL } from '../src/moderation';
import type { Env } from '../src/types';

const owner = '11111111-1111-4111-8111-111111111111';
const bytes = new Uint8Array([255,216,255,224,0,0,0,0]);
const verdict = (allowed: boolean) => ({ response: JSON.stringify({ allowed }) });
function fixture(options: {
  allowed?: boolean;
  access?: boolean;
  providerStatus?: number;
  receiptStatus?: number;
  receiptExists?: boolean;
  receiptLookupStatus?: number;
} = {}) {
  const calls: string[] = [];
  const storageMethods: string[] = [];
  const aiRequests: Array<{ model: unknown; input: unknown }> = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input); calls.push(url);
    if (url.includes('/auth/v1/user')) return Response.json({ id: owner });
    if (url.includes('/rpc/can_upload_moderated_media')) return Response.json(options.access ?? true);
    if (url.includes('/storage/')) {
      storageMethods.push(init?.method || 'GET');
      return Response.json({ ok: true });
    }
    if (url.includes('/moderated_media')) {
      if (init?.method === 'GET') {
        if (options.receiptLookupStatus) return new Response(null, { status: options.receiptLookupStatus });
        return Response.json(options.receiptExists ? [{ bucket: 'avatars' }] : []);
      }
      return new Response(null, { status: options.receiptStatus ?? 201 });
    }
    throw new Error('unexpected test fetch');
  };
  const env = { SUPABASE_URL: 'https://test.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', AI: { run: async (model: unknown, input: unknown) => { calls.push('workers-ai'); aiRequests.push({ model, input }); if (options.providerStatus === 503) throw new Error('provider unavailable'); return verdict(options.allowed ?? true); } }, CHEESE_MEDIA_MODERATION_ENABLED: 'true', SECONDHAND_AI_RATE_LIMITER: { limit: async () => ({ success: true }) } } as unknown as Env;
  const request = (consent = true) => new Request(`https://ai.cheeseapp.org/v1/media/upload?bucket=avatars&path=${owner}/photo.jpg`, {
    method: 'POST', headers: { Authorization: 'Bearer test-session', 'Content-Type': 'image/jpeg', ...(consent ? { 'X-Cheese-Media-Safety-Consent': '2026-09-11-media-v1' } : {}) }, body: bytes,
  });
  return { calls, storageMethods, aiRequests, fetcher, env, request };
}

test('only a complete unambiguous classifier approval is accepted', () => {
  assert.equal(approvedVerdict(verdict(true)), true);
  for (const item of [null, {}, verdict(false), { response: '[]' }, { response: '{"allowed":true,"extra":true}' }]) assert.equal(approvedVerdict(item), false);
});
test('permission must precede provider or Storage calls', async () => {
  const f = fixture();
  assert.equal((await handleModeratedUpload(f.request(false), f.env, f.fetcher)).status, 403);
  assert.equal(f.calls.length, 0);
});
test('unauthorized media never reaches classifier or Storage', async () => {
  const f = fixture({ access: false });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 403);
  assert.equal(f.calls.some(url => url.includes('workers-ai') || url.includes('/storage/')), false);
});
test('rejected content never reaches Storage', async () => {
  const f = fixture({ allowed: false });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 422);
  assert.equal(f.calls.some(url => url.includes('/storage/')), false);
});
test('provider outage fails closed before publishing media', async () => {
  const f = fixture({ providerStatus: 503 });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 503);
  assert.equal(f.calls.some(url => url.includes('/storage/')), false);
});
test('approval precedes upload and upload precedes receipt', async () => {
  const f = fixture();
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 200);
  assert.ok(f.calls.findIndex(x => x.includes('workers-ai')) < f.calls.findIndex(x => x.includes('/storage/')));
  assert.ok(f.calls.findIndex(x => x.includes('/storage/')) < f.calls.findIndex(x => x.includes('/moderated_media')));
});
test('the vision model receives the image as a data URI with a strict verdict schema', async () => {
  const f = fixture();
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 200);
  assert.equal(f.aiRequests.length, 1);
  const aiRequest = f.aiRequests[0];
  assert.ok(aiRequest);
  assert.equal(aiRequest.model, MEDIA_MODEL);
  const input = aiRequest.input as {
    messages: Array<{ content: unknown }>;
    guided_json: unknown;
  };
  const userMessage = input.messages[1];
  assert.ok(userMessage);
  const imageContent = userMessage.content as Array<{
    type: string;
    image_url: { url: string };
  }>;
  const suppliedImage = imageContent[0];
  assert.ok(suppliedImage);
  assert.equal(suppliedImage.type, 'image_url');
  assert.match(suppliedImage.image_url.url, /^data:image\/jpeg;base64,/);
  assert.deepEqual(input.guided_json, {
    type: 'object', properties: { allowed: { type: 'boolean' } },
    required: ['allowed'], additionalProperties: false,
  });
});
test('missing approval receipt removes the unreferenced object and never reports upload success', async () => {
  const f = fixture({ receiptStatus: 503 });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 503);
  assert.deepEqual(f.storageMethods, ['POST', 'DELETE']);
});
test('receipt failure never deletes an object that may already have a committed receipt', async () => {
  const f = fixture({ receiptStatus: 503, receiptExists: true });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 503);
  assert.deepEqual(f.storageMethods, ['POST']);
});
test('an unavailable receipt lookup preserves the object for account-cleanup recovery', async () => {
  const f = fixture({ receiptStatus: 503, receiptLookupStatus: 503 });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 503);
  assert.deepEqual(f.storageMethods, ['POST']);
});
test('chunked body limit cancels before unbounded buffering', async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ pull(c) { c.enqueue(new Uint8Array(8)); }, cancel() { cancelled = true; } });
  await assert.rejects(boundedBytes(stream, 10), /image_too_large/);
  assert.equal(cancelled, true);
});
