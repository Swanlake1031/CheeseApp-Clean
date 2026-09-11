import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("Content Studio presents a separate image-safety acknowledgement and no Gemini consent control", async () => {
  const [html, app] = await Promise.all([
    readFile(new URL("../../cheeseapp-content-studio/public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../../cheeseapp-content-studio/public/app.js", import.meta.url), "utf8")
  ]);

  assert.match(html, /id="media-safety-consent"/);
  assert.match(html, /Cloudflare Workers AI/);
  assert.doesNotMatch(html, /id="ai-consent"/);
  assert.doesNotMatch(html, /Google Gemini/);
  assert.match(app, /MEDIA_SAFETY_CONSENT_VERSION = "2026-09-11-media-v1"/);
  assert.match(app, /MAX_MEDIA_SAFETY_IMAGE_BYTES = 8 \* 1024 \* 1024/);
  assert.match(app, /blob\.size <= MAX_MEDIA_SAFETY_IMAGE_BYTES/);
  assert.match(app, /mediaSafetyConsentVersionForPublication\(\)/);
  assert.doesNotMatch(app, /\/v1\/ai-consent/);
});
