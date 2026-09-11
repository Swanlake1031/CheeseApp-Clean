import assert from "node:assert/strict";
import test from "node:test";
import { canonicalInput, contract, inputHash, safeQuotaDetails, validCache, withProviderRetry } from "../embed_dataset";
import { EmbeddingProviderError } from "../../../cheeseapp-ai-worker/src/recommendation/embeddingProvider";

test("offline text matches V1 SQL format including PostgreSQL BTRIM semantics", () => {
  const row = {title: "  PG\t ", body: " \n中文\t ", board_name: "校园生活"};
  assert.equal(canonicalInput(row), "task: sentence similarity | query: Title: PG\t\nBody: \n中文\t\nHashtags: #校园生活");
  assert.equal(inputHash(row).length, 64);
  assert.equal(inputHash(row), inputHash({...row}));
});

test("transient provider errors retry within bounded attempts without network test calls", async () => {
  let calls = 0;
  const delays: number[] = [];
  const result = await withProviderRetry(async () => {
    if (++calls < 3) throw new EmbeddingProviderError("provider_unavailable", true);
    return "numeric fixture";
  }, {attempts: 3, retryDelay: (attempt) => attempt * 5000, wait: async (ms) => { delays.push(ms); }});
  assert.equal(result, "numeric fixture");
  assert.equal(calls, 3);
  assert.deepEqual(delays, [5000, 10000]);
});

test("terminal errors, exhausted attempts and terminal quotas never retry indefinitely", async () => {
  for (const [retryable, delay, expected] of [[false, 1, 1], [true, null, 1], [true, 60001, 1], [true, 1, 3]] as const) {
    let calls = 0;
    await assert.rejects(withProviderRetry(async () => {
      calls++;
      throw new EmbeddingProviderError("provider_quota", retryable);
    }, {attempts: 3, retryDelay: () => delay, wait: async () => {}}));
    assert.equal(calls, expected);
  }
});

test("quota diagnostics expose only quota names and retry delay, never raw provider fields", () => {
  const body = {error: {message: "private diagnostic text", details: [
    {"@type": "type.googleapis.com/google.rpc.QuotaFailure", violations: [
      {quotaId: "EmbedContentRequestsPerDayPerProjectPerModel", subject: "private project", description: "private body"},
      {quotaId: "untrusted.url/secret"},
    ]},
    {"@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "25.5s"},
    {"@type": "type.googleapis.com/google.rpc.ErrorInfo", metadata: {consumer: "private project"}},
  ]}};
  assert.deepEqual(safeQuotaDetails(body), {
    quota_ids: ["EmbedContentRequestsPerDayPerProjectPerModel"], retry_delay_seconds: 25.5,
  });
  assert.deepEqual(safeQuotaDetails(null), {quota_ids: []});
});

test("cache uses exact V1 model and validates dimension, hash and finite unit vectors", () => {
  assert.equal(contract.embedding_model, "gemini-embedding-2");
  assert.equal(contract.dimension, 768);
  const record = {...contract, input_hash: "a".repeat(64), generated_at: "2026-09-09T00:00:00Z",
    values: [1, ...Array(767).fill(0)]};
  assert.equal(validCache(record, record.input_hash), true);
  for (const change of [{dimension: 2}, {embedding_version: "other"}, {values: [1]},
    {values: [NaN, ...Array(767).fill(0)]}, {values: Array(768).fill(0)},
    {generated_at: "bad"}, {generated_at: "2026-09-09T00:00:00"},
    {input_hash: "b".repeat(64)}]) {
    assert.equal(validCache({...record, ...change}, record.input_hash), false);
  }
});
