import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import worker, { handleWorkerRequest } from "../src/index";
import type { Env } from "../src/types";

const context = {
  waitUntil() {},
  passThroughOnException() {},
} as unknown as ExecutionContext;

test("disabled release hides legacy Gemini routes before authentication or provider setup", { concurrency: false }, async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("disabled route must not make a network call");
  };
  try {
    for (const path of ["/v1/comment-events", "/v1/secondhand/generate-description"]) {
      const response = await handleWorkerRequest(
        new Request(`https://ai.cheeseapp.org${path}`, { method: "POST" }),
        {} as Env,
        context,
      );
      assert.equal(response.status, 404);
      assert.deepEqual(await response.json(), { error: "not_found" });
    }
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("public health does not disclose Gemini configuration or models", async () => {
  const response = await handleWorkerRequest(
    new Request("https://ai.cheeseapp.org/health"),
    {
      CHEESE_AI_ENABLED: "true",
      CHEESE_GEMINI_RELEASE_ENABLED: "true",
      CHEESE_RECOMMENDATION_JOBS_ENABLED: "true",
      CHEESE_RECOMMENDATION_SHADOW_ENABLED: "true",
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role",
      SECONDHAND_AI_RATE_LIMITER: { limit: async () => ({ success: true }) },
    } as Env,
    context,
  );
  assert.equal(response.status, 200);
  const payload = await response.json() as Record<string, unknown>;
  assert.equal(payload.optionalAIAvailable, false);
  assert.equal(payload.recommendationProviderEnabled, false);
  assert.equal(payload.recommendationMaintenanceEnabled, true);
  assert.equal(payload.recommendationShadowEnabled, true);
  for (const key of Object.keys(payload)) assert.doesNotMatch(key.toLowerCase(), /gemini|model|prompt|embedding/);
});

test("Worker asset routing excludes disabled Gemini endpoints", async () => {
  const config = await readFile(
    new URL("../wrangler.jsonc", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(config, /"\/v1\/comment-events"/);
  assert.doesNotMatch(config, /"\/v1\/secondhand\/generate-description"/);
  assert.match(config, /"\/v1\/media\/upload"/);
});

test("the scheduled handler cannot invoke a Gemini path in the disabled release", { concurrency: false }, async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("disabled scheduler must not make a network call");
  };
  let scheduledWork: Promise<unknown> | undefined;
  const scheduledContext = {
    ...context,
    waitUntil(work: Promise<unknown>) { scheduledWork = work; },
  } as unknown as ExecutionContext;
  try {
    worker.scheduled?.(
      {} as ScheduledController,
      {
        CHEESE_AI_ENABLED: "true",
        CHEESE_GEMINI_RELEASE_ENABLED: "true",
        CHEESE_RECOMMENDATION_JOBS_ENABLED: "false",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "test-service-role",
        SECONDHAND_AI_RATE_LIMITER: { limit: async () => ({ success: true }) },
      } as Env,
      scheduledContext,
    );
    await scheduledWork;
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
