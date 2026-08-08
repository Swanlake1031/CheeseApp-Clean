import assert from "node:assert/strict";
import test from "node:test";

import { processMediaCleanup, safeErrorCode } from "../src/media/cleanup.js";

const config = {
  supabaseURL: "http://127.0.0.1:54321",
  supabaseServiceRoleKey: "local-service-role"
};

test("skips cleanup when the service role secret is unavailable", async () => {
  let called = false;
  const result = await processMediaCleanup({
    config: { ...config, supabaseServiceRoleKey: "" },
    fetchImpl: async () => {
      called = true;
      throw new Error("unexpected request");
    }
  });

  assert.equal(result.skipped, "missing_service_role");
  assert.equal(called, false);
});

test("records transient post deletion failure and treats missing chat object as resolved", async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    const body = JSON.parse(options.body);
    calls.push({ url, method: options.method, body, headers: options.headers });

    if (url.endsWith("/rpc/claim_post_media_cleanup_batch")) {
      return jsonResponse([{
        cleanup_id: "11111111-1111-4111-8111-111111111111",
        bucket: "post-images",
        object_path: "forum/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/0.jpg",
        attempt_count: 0
      }]);
    }
    if (url.endsWith("/object/post-images")) {
      return jsonResponse({ error: "temporary" }, 503);
    }
    if (url.endsWith("/rpc/complete_post_media_cleanup_job")) {
      return jsonResponse(null, 204);
    }
    if (url.endsWith("/rpc/claim_chat_media_cleanup_batch")) {
      return jsonResponse([{
        cleanup_id: "22222222-2222-4222-8222-222222222222",
        bucket: "chat-images",
        object_path: "direct/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/cccccccc-cccc-4ccc-8ccc-cccccccccccc/dddddddd-dddd-4ddd-8ddd-dddddddddddd.jpg",
        attempt_count: 1
      }]);
    }
    if (url.endsWith("/object/chat-images")) {
      return jsonResponse({ error: "not found" }, 404);
    }
    if (url.endsWith("/rpc/complete_chat_media_cleanup_job")) {
      return jsonResponse(null, 204);
    }
    if (url.endsWith("/rpc/get_media_cleanup_backlog_metrics")) {
      return jsonResponse([{
        post_pending: 1,
        post_blocked: 0,
        post_unresolved: 0,
        chat_pending: 0,
        chat_blocked: 0
      }]);
    }
    throw new Error(`unexpected request: ${url}`);
  };

  const result = await processMediaCleanup({ config, fetchImpl });

  assert.equal(result.skipped, null);
  assert.deepEqual(result.kinds, [
    { kind: "post", claimed: 1, succeeded: 0, failed: 1 },
    { kind: "chat", claimed: 1, succeeded: 1, failed: 0 }
  ]);

  const postCompletion = calls.find((call) =>
    call.url.endsWith("/rpc/complete_post_media_cleanup_job")
  );
  assert.equal(postCompletion.body.p_succeeded, false);
  assert.equal(postCompletion.body.p_error_code, "storage_http_503");

  const chatCompletion = calls.find((call) =>
    call.url.endsWith("/rpc/complete_chat_media_cleanup_job")
  );
  assert.equal(chatCompletion.body.p_succeeded, true);
  assert.equal(chatCompletion.body.p_error_code, null);

  for (const call of calls) {
    assert.equal(call.headers.apikey, "local-service-role");
    assert.equal(call.headers.authorization, "Bearer local-service-role");
  }
});

test("rejects a claim that crosses its feature-owned bucket", async () => {
  const completions = [];
  const fetchImpl = async (url, options) => {
    const body = JSON.parse(options.body);
    if (url.endsWith("/rpc/claim_post_media_cleanup_batch")) {
      return jsonResponse([{
        cleanup_id: "33333333-3333-4333-8333-333333333333",
        bucket: "chat-images",
        object_path: "direct/not-a-post-path",
        attempt_count: 0
      }]);
    }
    if (url.endsWith("/rpc/complete_post_media_cleanup_job")) {
      completions.push(body);
      return jsonResponse(null, 204);
    }
    if (url.endsWith("/rpc/claim_chat_media_cleanup_batch")) {
      return jsonResponse([]);
    }
    if (url.endsWith("/rpc/get_media_cleanup_backlog_metrics")) {
      return jsonResponse([{}]);
    }
    throw new Error(`unexpected request: ${url}`);
  };

  await processMediaCleanup({ config, fetchImpl });

  assert.equal(completions.length, 1);
  assert.equal(completions[0].p_succeeded, false);
  assert.equal(completions[0].p_error_code, "invalid_cleanup_claim");
});

test("sanitizes observable error codes", () => {
  assert.equal(safeErrorCode({ code: "network timeout / secret=value" }), "network_timeout___secret_value");
  assert.equal(safeErrorCode(null), "cleanup_failed");
});

function jsonResponse(value, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async text() {
      return status === 204 ? "" : JSON.stringify(value);
    }
  };
}
