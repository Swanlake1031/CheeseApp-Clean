import assert from "node:assert/strict";
import test from "node:test";
import {
  CheeseAIInteractionHandler,
  type CheeseAIRepository,
} from "../src/ai/interactionHandler";
import { GeminiProviderError } from "../src/ai/geminiProvider";
import type { CheeseAIImageLoader } from "../src/ai/postImageLoader";
import type {
  CheeseAIImage,
  CheeseAIInput,
  CheeseAIProvider,
  CheeseAIResult,
  EnqueueResult,
  InteractionRecord,
  ThreadContext,
} from "../src/types";
import {
  SOURCE_COMMENT_ID,
  SOURCE_USER_ID,
  TEST_CONFIG,
  comment,
  post,
  threadContext,
} from "./fixtures";

class FakeRepository implements CheeseAIRepository {
  private claimed = false;
  readonly failures: Array<{
    readonly category: string;
    readonly retryAfterSeconds: number | null;
  }> = [];
  readonly completed: string[] = [];
  context: ThreadContext = threadContext();
  interaction: InteractionRecord = {
    source_comment_id: SOURCE_COMMENT_ID,
    source_author_id: SOURCE_USER_ID,
    status: "processing",
    next_attempt_at: null,
    trigger_kind: "mention",
  };
  rateAllowed = true;

  async enqueue(): Promise<EnqueueResult> {
    return { accepted: true, created: !this.claimed, status: "pending" };
  }

  async claim(): Promise<boolean> {
    if (this.claimed) return false;
    this.claimed = true;
    return true;
  }

  async fetchThreadContext(): Promise<ThreadContext> {
    return this.context;
  }

  async getInteraction(): Promise<InteractionRecord | null> {
    return this.interaction;
  }

  async checkRateLimit(): Promise<{
    readonly allowed: boolean;
    readonly window_count: number;
    readonly daily_count: number;
  }> {
    return {
      allowed: this.rateAllowed,
      window_count: this.rateAllowed ? 1 : 6,
      daily_count: this.rateAllowed ? 1 : 26,
    };
  }

  async complete(
    _sourceCommentId: string,
    outputCommentId: string,
  ): Promise<string> {
    this.completed.push(outputCommentId);
    return outputCommentId;
  }

  async fail(
    _sourceCommentId: string,
    category: string,
    retryAfterSeconds: number | null,
  ): Promise<void> {
    this.failures.push({ category, retryAfterSeconds });
  }
}

class FakeProvider implements CheeseAIProvider {
  calls = 0;
  error: Error | undefined;
  lastInput: CheeseAIInput | undefined;

  async generateCommunityReply(
    input: CheeseAIInput,
  ): Promise<CheeseAIResult> {
    this.calls += 1;
    this.lastInput = input;
    if (this.error) throw this.error;
    return {
      text: "建议先看课程大纲和评分方式，具体以学校官网为准。",
      inputTokenCount: 10,
      outputTokenCount: 8,
      finishReason: "STOP",
      latencyMs: 25,
    };
  }
}

class FakeImageLoader implements CheeseAIImageLoader {
  images: readonly CheeseAIImage[] = [];

  async load(): Promise<readonly CheeseAIImage[]> {
    return this.images;
  }
}

test("one source comment produces at most one AI reply across duplicate deliveries", async () => {
  const repository = new FakeRepository();
  const provider = new FakeProvider();
  const handler = new CheeseAIInteractionHandler(
    repository,
    provider,
    new FakeImageLoader(),
    TEST_CONFIG,
    () => "30000000-0000-4000-8000-000000000001",
  );

  assert.equal((await handler.process(SOURCE_COMMENT_ID)).status, "completed");
  assert.deepEqual(await handler.process(SOURCE_COMMENT_ID), {
    status: "ignored",
    category: "not_claimed",
  });
  assert.equal(provider.calls, 1);
  assert.equal(repository.completed.length, 1);
});

test("invalid interaction and rate limit do not call Gemini", async () => {
  for (const setup of [
    (repository: FakeRepository) => {
      repository.context = threadContext({ post: post({ is_private: true }) });
    },
    (repository: FakeRepository) => {
      repository.rateAllowed = false;
    },
  ]) {
    const repository = new FakeRepository();
    const provider = new FakeProvider();
    setup(repository);
    const handler = new CheeseAIInteractionHandler(
      repository,
      provider,
      new FakeImageLoader(),
      TEST_CONFIG,
    );
    await handler.process(SOURCE_COMMENT_ID);
    assert.equal(provider.calls, 0);
    assert.equal(repository.completed.length, 0);
  }
});

test("retryable provider failure schedules one durable retry without creating a reply", async () => {
  const repository = new FakeRepository();
  const provider = new FakeProvider();
  provider.error = new GeminiProviderError("provider_quota", true);
  const handler = new CheeseAIInteractionHandler(
    repository,
    provider,
    new FakeImageLoader(),
    TEST_CONFIG,
  );

  assert.deepEqual(await handler.process(SOURCE_COMMENT_ID), {
    status: "failed",
    category: "provider_quota",
  });
  assert.deepEqual(repository.failures, [
    { category: "provider_quota", retryAfterSeconds: 60 },
  ]);
  assert.equal(repository.completed.length, 0);
});

test("a direct reply to the AI continues without another mention", async () => {
  const repository = new FakeRepository();
  repository.interaction = {
    ...repository.interaction,
    trigger_kind: "continuation",
  };
  repository.context = threadContext({
    source: comment({ content: "那工作量具体大吗？" }),
  });
  const provider = new FakeProvider();
  const handler = new CheeseAIInteractionHandler(
    repository,
    provider,
    new FakeImageLoader(),
    TEST_CONFIG,
  );

  assert.equal((await handler.process(SOURCE_COMMENT_ID)).status, "completed");
  assert.equal(provider.calls, 1);
});

test("loaded post images are forwarded to Gemini as optional context", async () => {
  const repository = new FakeRepository();
  const provider = new FakeProvider();
  const imageLoader = new FakeImageLoader();
  imageLoader.images = [{ mimeType: "image/jpeg", data: "aGVsbG8=" }];
  const handler = new CheeseAIInteractionHandler(
    repository,
    provider,
    imageLoader,
    TEST_CONFIG,
  );

  assert.equal((await handler.process(SOURCE_COMMENT_ID)).status, "completed");
  assert.deepEqual(provider.lastInput?.images, imageLoader.images);
});
