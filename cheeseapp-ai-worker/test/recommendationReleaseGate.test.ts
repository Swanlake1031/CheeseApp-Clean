import assert from "node:assert/strict";
import test from "node:test";
import {
  CHEESE_AI_MODEL,
  CHEESE_AI_PROMPT_VERSION,
  RECOMMENDATION_ALGORITHM_VERSION,
  RECOMMENDATION_EMBEDDING_DIMENSION,
  RECOMMENDATION_EMBEDDING_MODEL,
  RECOMMENDATION_EMBEDDING_VERSION,
  RECOMMENDATION_INPUT_FORMAT_VERSION,
  GEMINI_PROVIDER_RELEASED,
  loadConfig,
  loadRecommendationConfig,
  type RecommendationConfig,
} from "../src/config";
import {
  RecommendationProcessor,
  type RecommendationEmbeddingProvider,
  type RecommendationProcessorRepository,
} from "../src/recommendation/processor";
import type { Env, PostEmbeddingJob } from "../src/types";

const commonEnv = {
  CHEESE_AI_USER_ID: "00000000-0000-4000-8000-000000000001",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role",
  CHEESE_AI_ENABLED: "true",
  CHEESE_RECOMMENDATION_JOBS_ENABLED: "true",
  CHEESE_RECOMMENDATION_SHADOW_ENABLED: "true",
} as Env;

function recommendationConfig(
  overrides: Partial<RecommendationConfig> = {},
): RecommendationConfig {
  return {
    maintenanceEnabled: true,
    embeddingProviderEnabled: false,
    shadowEnabled: true,
    geminiApiKey: "test-key",
    supabaseUrl: "https://example.supabase.co",
    supabaseServiceRoleKey: "test-service-role",
    algorithmVersion: RECOMMENDATION_ALGORITHM_VERSION,
    embeddingVersion: RECOMMENDATION_EMBEDDING_VERSION,
    embeddingModel: RECOMMENDATION_EMBEDDING_MODEL,
    embeddingDimension: RECOMMENDATION_EMBEDDING_DIMENSION,
    inputFormatVersion: RECOMMENDATION_INPUT_FORMAT_VERSION,
    ...overrides,
  };
}

function repository(
  calls: string[],
  jobs: readonly PostEmbeddingJob[] = [],
): RecommendationProcessorRepository {
  return {
    async backfillForumEmbeddingJobs() {
      calls.push("backfill");
      return 3;
    },
    async backfillRecommendationSignalState() {
      calls.push("signals");
      return 4;
    },
    async refreshRecommendationMetrics() {
      calls.push("metrics");
      return true;
    },
    async claimPostEmbeddingJobs() {
      calls.push("claim");
      return jobs;
    },
    async listRecommendationShadowUsers() {
      calls.push("shadow-users");
      return ["shadow-user"];
    },
    async createRecommendationShadowSession() {
      calls.push("shadow-session");
      return "session-id";
    },
    async getPost(postId) {
      return {
        id: postId,
        user_id: "00000000-0000-4000-8000-000000000002",
        type: "forum",
        title: "Title",
        description: "Description",
        status: "active",
        is_private: false,
      };
    },
    async hasAIConsent() {
      return true;
    },
    async completePostEmbeddingJob() {
      calls.push("complete");
      return true;
    },
    async failPostEmbeddingJob() {
      calls.push("fail");
    },
  };
}

test("the 13+ release keeps Gemini disabled even when operational variables are true", () => {
  assert.equal(GEMINI_PROVIDER_RELEASED, false);
  const blocked = loadRecommendationConfig({
    ...commonEnv,
    CHEESE_GEMINI_RELEASE_ENABLED: "false",
  });
  assert.equal(blocked.maintenanceEnabled, true);
  assert.equal(blocked.embeddingProviderEnabled, false);
  assert.equal(blocked.shadowEnabled, true);

  const attemptedEnable = loadRecommendationConfig({
    ...commonEnv,
    CHEESE_GEMINI_RELEASE_ENABLED: " TRUE ",
  });
  assert.equal(attemptedEnable.maintenanceEnabled, true);
  assert.equal(attemptedEnable.embeddingProviderEnabled, false);
  assert.equal(attemptedEnable.shadowEnabled, true);

  const stopped = loadRecommendationConfig({
    ...commonEnv,
    CHEESE_RECOMMENDATION_JOBS_ENABLED: "false",
    CHEESE_GEMINI_RELEASE_ENABLED: "true",
  });
  assert.equal(stopped.maintenanceEnabled, false);
  assert.equal(stopped.embeddingProviderEnabled, false);
  assert.equal(stopped.shadowEnabled, false);

  const generalAiBlocked = loadConfig({
    ...commonEnv,
    CHEESE_GEMINI_RELEASE_ENABLED: "false",
  });
  assert.equal(generalAiBlocked.enabled, false);
  const attemptedGeneralAiEnable = loadConfig({
    ...commonEnv,
    CHEESE_GEMINI_RELEASE_ENABLED: "true",
  });
  assert.equal(attemptedGeneralAiEnable.enabled, false);
  assert.equal(attemptedGeneralAiEnable.model, CHEESE_AI_MODEL);
  assert.equal(attemptedGeneralAiEnable.promptVersion, CHEESE_AI_PROMPT_VERSION);
});

test("disabled Gemini release gate runs maintenance without claiming or sending embedding jobs", async () => {
  const calls: string[] = [];
  let providerCalls = 0;
  const provider: RecommendationEmbeddingProvider = {
    async embed() {
      providerCalls += 1;
      throw new Error("provider must not be called while disabled");
    },
  };

  await new RecommendationProcessor(recommendationConfig(), {
    repository: repository(calls),
    provider,
  }).runScheduledBatch();

  assert.equal(providerCalls, 0);
  assert.equal(calls.includes("claim"), false);
  assert.equal(calls.includes("backfill"), true);
  assert.equal(calls.includes("signals"), true);
  assert.equal(calls.includes("metrics"), true);
  assert.equal(calls.includes("shadow-users"), true);
  assert.equal(calls.includes("shadow-session"), true);
});

test("a separately injected provider remains testable behind an explicit enabled configuration", async () => {
  const calls: string[] = [];
  let providerCalls = 0;
  const job: PostEmbeddingJob = {
    job_id: "00000000-0000-4000-8000-000000000003",
    post_id: "00000000-0000-4000-8000-000000000004",
    input_hash: "input-hash",
    embedding_version: RECOMMENDATION_EMBEDDING_VERSION,
    model: RECOMMENDATION_EMBEDDING_MODEL,
    input_format_version: RECOMMENDATION_INPUT_FORMAT_VERSION,
    embedding_input: "Title: Test\nBody: Content",
    attempt: 1,
  };
  const provider: RecommendationEmbeddingProvider = {
    async embed() {
      providerCalls += 1;
      return {
        values: Array.from(
          { length: RECOMMENDATION_EMBEDDING_DIMENSION },
          (_, index) => (index === 0 ? 1 : 0),
        ),
        norm: 1,
        providerNorm: 1,
        latencyMs: 0,
      };
    },
  };

  await new RecommendationProcessor(
    recommendationConfig({
      embeddingProviderEnabled: true,
      shadowEnabled: false,
    }),
    {
      repository: repository(calls, [job]),
      provider,
    },
  ).runScheduledBatch();

  assert.equal(providerCalls, 1);
  assert.equal(calls.filter((call) => call === "claim").length, 1);
  assert.equal(calls.filter((call) => call === "complete").length, 1);
});
