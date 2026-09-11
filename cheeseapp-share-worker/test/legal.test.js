import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
test('privacy and support remain public even without backend secrets', async () => {
  for (const page of ['privacy', 'support']) {
    const response = await worker.fetch(new Request(`https://cheeseapp.org/${page}`), {});
    assert.equal(response.status, 200);
    assert.match(response.headers.get('Content-Type'), /text\/html/);
    const text = await response.text();
    assert.match(text, /support@cheeseapp.dev/);
    if (page === 'privacy') { assert.match(text, /Google Gemini/); assert.doesNotMatch(text, /\b(housing|rentals?)\b/i); }
  }
});
