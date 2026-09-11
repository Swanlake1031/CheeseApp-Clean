import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
test('privacy and support remain public even without backend secrets', async () => {
  for (const page of ['privacy', 'support']) {
    const response = await worker.fetch(new Request(`https://cheeseapp.org/${page}`), {});
    assert.equal(response.status, 200);
    assert.match(response.headers.get('Content-Type'), /text\/html/);
    const text = await response.text();
    assert.match(text, /support.cheeseteam@gmail.com/);
    if (page === 'privacy') {
      assert.match(text, /Cloudflare Workers AI/);
      assert.match(text, /withdraw the local image-review acknowledgement/);
      assert.match(text, /Optional Google Gemini features are not available/);
      assert.match(text, /direct and group-message content/);
      assert.match(text, /We do not retain your original message text or photos/);
      assert.match(text, /required gender selection/);
      assert.match(text, /in-app social graph/);
      assert.match(text, /completed transaction history/);
      assert.doesNotMatch(text, /\b(housing|rentals?)\b/i);
      assert.doesNotMatch(text, /Messages already delivered/);
    }
  }
});
