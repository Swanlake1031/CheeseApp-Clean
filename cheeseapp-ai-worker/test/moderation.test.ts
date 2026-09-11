import test from 'node:test';
import assert from 'node:assert/strict';
import { approvedVerdict, boundedBytes, handleModeratedUpload } from '../src/moderation';
import type { Env } from '../src/types';

const owner = '11111111-1111-4111-8111-111111111111';
const bytes = new Uint8Array([255,216,255,224,0,0,0,0]);
const verdict = (allowed: boolean) => ({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify({ allowed }) }] } }] });
function fixture(options: { allowed?: boolean; access?: boolean; providerStatus?: number; receiptStatus?: number } = {}) {
  const calls: string[] = [];
  const fetcher: typeof fetch = async (input) => {
    const url = String(input); calls.push(url);
    if (url.includes('/auth/v1/user')) return Response.json({ id: owner });
    if (url.includes('/rpc/can_upload_moderated_media')) return Response.json(options.access ?? true);
    if (url.includes('generativelanguage')) return Response.json(verdict(options.allowed ?? true), { status: options.providerStatus ?? 200 });
    if (url.includes('/storage/')) return Response.json({ ok: true });
    if (url.includes('/moderated_media')) return new Response(null, { status: options.receiptStatus ?? 201 });
    throw new Error('unexpected test fetch');
  };
  const env = { SUPABASE_URL: 'https://test.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'test-service-key', GEMINI_API_KEY: 'test-provider-key', CHEESE_MEDIA_MODERATION_ENABLED: 'true', SECONDHAND_AI_RATE_LIMITER: { limit: async () => ({ success: true }) } } as Env;
  const request = (consent = true) => new Request(`https://ai.cheeseapp.org/v1/media/upload?bucket=avatars&path=${owner}/photo.jpg`, {
    method: 'POST', headers: { Authorization: 'Bearer test-session', 'Content-Type': 'image/jpeg', ...(consent ? { 'X-Cheese-AI-Consent': '2026-09-11' } : {}) }, body: bytes,
  });
  return { calls, fetcher, env, request };
}

test('only a complete unambiguous classifier approval is accepted', () => {
  assert.equal(approvedVerdict(verdict(true)), true);
  for (const item of [null, {}, verdict(false), { candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: '{"allowed":true}' }] } }] }, { ...verdict(true), promptFeedback: { blockReason: 'SAFETY' } }]) assert.equal(approvedVerdict(item), false);
});
test('permission must precede provider or Storage calls', async () => {
  const f = fixture();
  assert.equal((await handleModeratedUpload(f.request(false), f.env, f.fetcher)).status, 403);
  assert.equal(f.calls.length, 0);
});
test('unauthorized media never reaches classifier or Storage', async () => {
  const f = fixture({ access: false });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 403);
  assert.equal(f.calls.some(url => url.includes('generativelanguage') || url.includes('/storage/')), false);
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
  assert.ok(f.calls.findIndex(x => x.includes('generativelanguage')) < f.calls.findIndex(x => x.includes('/storage/')));
  assert.ok(f.calls.findIndex(x => x.includes('/storage/')) < f.calls.findIndex(x => x.includes('/moderated_media')));
});
test('missing approval receipt never reports upload success', async () => {
  const f = fixture({ receiptStatus: 503 });
  assert.equal((await handleModeratedUpload(f.request(), f.env, f.fetcher)).status, 503);
});
test('chunked body limit cancels before unbounded buffering', async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ pull(c) { c.enqueue(new Uint8Array(8)); }, cancel() { cancelled = true; } });
  await assert.rejects(boundedBytes(stream, 10), /image_too_large/);
  assert.equal(cancelled, true);
});
