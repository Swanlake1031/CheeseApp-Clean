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
    } else {
      assert.match(text, /<title>奶酪帮助与支持 \| CheeseApp<\/title>/);
      assert.match(text, /<meta name="robots" content="index, follow" \/>/);
      assert.match(text, /奶酪帮助与支持/);
      assert.match(text, /CheeseApp Support/);
      assert.match(text, /遇到问题？我们会尽力帮你解决。/);
      for (const heading of [
        '账号与登录',
        '校园社区',
        '二手市场',
        '聊天与消息',
        '隐私与安全',
        'Account &amp; Login',
        'Campus Community',
        'Marketplace',
        'Chat &amp; Messaging',
        'Privacy &amp; Safety'
      ]) {
        assert.match(text, new RegExp(heading));
      }
      assert.match(text, /不直接参与交易、付款、配送或履约/);
      assert.match(text, /does not directly participate in transactions/);
      assert.match(text, /href="mailto:support\.cheeseteam@gmail\.com"/);
      assert.match(text, /href="\/privacy"/);
      assert.match(text, /href="\/support"/);
      assert.match(text, /用户协议/);
      assert.match(text, /TODO/);
      assert.doesNotMatch(text, /href="\/terms"/);
    }
  }

  const englishResponse = await worker.fetch(
    new Request('https://cheeseapp.org/support?lang=en'),
    {}
  );
  assert.equal(englishResponse.status, 200);
  const englishText = await englishResponse.text();
  assert.match(englishText, /<html lang="en">/);
  assert.match(englishText, /<title>CheeseApp Support<\/title>/);
  assert.match(
    englishText,
    /<meta name="description" content="Get help with CheeseApp account access/
  );

  const headResponse = await worker.fetch(
    new Request('https://cheeseapp.org/support/', { method: 'HEAD' }),
    {}
  );
  assert.equal(headResponse.status, 200);
  assert.equal(await headResponse.text(), '');
});
