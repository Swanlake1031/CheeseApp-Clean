import assert from "node:assert/strict";
import test from "node:test";
import {
  RECOMMENDATION_EMBEDDING_DIMENSION,
  RECOMMENDATION_EMBEDDING_MODEL,
  RECOMMENDATION_EMBEDDING_VERSION,
  RECOMMENDATION_INPUT_FORMAT_VERSION,
} from "../src/config";
import {
  EmbeddingProviderError,
  GeminiEmbeddingProvider,
  normalizeEmbedding,
} from "../src/recommendation/embeddingProvider";

const unitValues = Array.from(
  { length: RECOMMENDATION_EMBEDDING_DIMENSION },
  (_, index) => (index === 0 ? 1 : 0),
);

test("recommendation semantic version constants are exact and centralized", () => {
  assert.equal(RECOMMENDATION_EMBEDDING_MODEL, "gemini-embedding-2");
  assert.equal(RECOMMENDATION_EMBEDDING_VERSION, "cheese-semantic-v1");
  assert.equal(RECOMMENDATION_INPUT_FORMAT_VERSION, 1);
  assert.equal(RECOMMENDATION_EMBEDDING_DIMENSION, 768);
});

test("Gemini embedding request uses Embedding 2 REST shape without legacy taskType", async () => {
  let capturedUrl = "";
  let capturedBody: Record<string, unknown> = {};
  const provider = new GeminiEmbeddingProvider(
    "secret",
    (async (input, init) => {
      capturedUrl = String(input);
      capturedBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Response.json({ embedding: { values: unitValues } });
    }) as typeof fetch,
  );
  const result = await provider.embed(
    "task: sentence similarity | query: Title: Test\nBody: Text\nHashtags: #Campus",
  );

  assert.match(capturedUrl, /gemini-embedding-2:embedContent$/);
  assert.equal(capturedBody.output_dimensionality, 768);
  assert.equal("taskType" in capturedBody, false);
  assert.equal("task_type" in capturedBody, false);
  assert.equal(result.values.length, 768);
  assert.ok(Math.abs(result.norm - 1) < 0.000_001);
});

test("normalization preserves behavioral magnitude separation and yields a unit vector", () => {
  const unnormalized = Array.from(
    { length: RECOMMENDATION_EMBEDDING_DIMENSION },
    (_, index) => (index === 0 ? 3 : index === 1 ? 4 : 0),
  );
  const result = normalizeEmbedding(unnormalized);
  assert.equal(result.providerNorm, 5);
  assert.ok(Math.abs(result.values[0]! - 0.6) < 0.000_001);
  assert.ok(Math.abs(result.values[1]! - 0.8) < 0.000_001);
  assert.ok(Math.abs(result.norm - 1) < 0.000_001);
});

test("invalid dimension, zero norm, and non-finite values are rejected", () => {
  for (const values of [
    [1, 0],
    Array(RECOMMENDATION_EMBEDDING_DIMENSION).fill(0),
    [Number.NaN, ...Array(RECOMMENDATION_EMBEDDING_DIMENSION - 1).fill(0)],
  ]) {
    assert.throws(
      () => normalizeEmbedding(values),
      (error: unknown) =>
        error instanceof EmbeddingProviderError &&
        error.category === "invalid_embedding",
    );
  }
});

test("429 and 5xx are retryable while bad requests are terminal", async () => {
  for (const [status, retryable] of [[429, true], [503, true], [400, false]] as const) {
    const provider = new GeminiEmbeddingProvider(
      "secret",
      (async () => new Response("upstream", { status })) as typeof fetch,
    );
    await assert.rejects(
      provider.embed("task: sentence similarity | query: test"),
      (error: unknown) =>
        error instanceof EmbeddingProviderError && error.retryable === retryable,
    );
  }
});
