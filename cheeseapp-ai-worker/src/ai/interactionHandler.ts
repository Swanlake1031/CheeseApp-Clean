import type { AppConfig } from "../config";
import { runtimeFetch } from "../runtimeFetch";
import { SupabaseRequestError, SupabaseRepository } from "../supabase";
import type {
  CheeseAIProvider,
  EnqueueResult,
  InteractionRecord,
  ThreadContext,
} from "../types";
import { CHEESE_AI_SYSTEM_PROMPT } from "./cheeseSystemPrompt";
import {
  buildDynamicThreadContext,
  containsRawIdentifier,
} from "./contextBuilder";
import { isEligibleInvocation } from "./eligibility";
import {
  GeminiCheeseAIProvider,
  GeminiProviderError,
} from "./geminiProvider";
import {
  type CheeseAIImageLoader,
  SupabasePostImageLoader,
} from "./postImageLoader";

export interface CheeseAIRepository {
  hasAIConsent(userId: string): Promise<boolean>;
  enqueue(
    sourceCommentId: string,
    aiUserId: string,
    model: string,
    promptVersion: string,
  ): Promise<EnqueueResult>;
  claim(sourceCommentId: string): Promise<boolean>;
  getInteraction(sourceCommentId: string): Promise<InteractionRecord | null>;
  fetchThreadContext(sourceCommentId: string): Promise<ThreadContext>;
  checkRateLimit(
    sourceAuthorId: string,
    windowMinutes: number,
    windowLimit: number,
    dailyLimit: number,
  ): Promise<{
    readonly allowed: boolean;
    readonly window_count: number;
    readonly daily_count: number;
  }>;
  complete(
    sourceCommentId: string,
    outputCommentId: string,
    content: string,
    latencyMs: number,
    inputTokenCount: number,
    outputTokenCount: number,
    finishReason: string,
  ): Promise<string>;
  fail(
    sourceCommentId: string,
    category: string,
    retryAfterSeconds: number | null,
  ): Promise<void>;
}

export interface ProcessingResult {
  readonly status: "completed" | "ignored" | "failed";
  readonly category?: string;
}

function logEvent(
  event: string,
  sourceCommentId: string,
  fields: Readonly<Record<string, string | number | boolean>> = {},
): void {
  console.log(JSON.stringify({ event, source_comment_id: sourceCommentId, ...fields }));
}

function errorCategory(error: unknown): string {
  if (error instanceof GeminiProviderError) return error.category;
  if (error instanceof SupabaseRequestError) return error.category;
  return "internal_error";
}

function retryDelaySeconds(error: unknown): number | null {
  if (error instanceof GeminiProviderError) {
    return error.retryable ? 60 : null;
  }
  if (error instanceof SupabaseRequestError) {
    return error.status === 429 || error.status >= 500 ? 60 : null;
  }
  return null;
}

export class CheeseAIInteractionHandler {
  constructor(
    private readonly repository: CheeseAIRepository,
    private readonly provider: CheeseAIProvider,
    private readonly imageLoader: CheeseAIImageLoader,
    private readonly config: AppConfig,
    private readonly uuid: () => string = () => crypto.randomUUID(),
  ) {}

  enqueue(sourceCommentId: string): Promise<EnqueueResult> {
    return this.repository.enqueue(
      sourceCommentId,
      this.config.aiUserId,
      this.config.model,
      this.config.promptVersion,
    );
  }

  async process(sourceCommentId: string): Promise<ProcessingResult> {
    const claimed = await this.repository.claim(sourceCommentId);
    if (!claimed) return { status: "ignored", category: "not_claimed" };

    try {
      const [context, interaction] = await Promise.all([
        this.repository.fetchThreadContext(sourceCommentId),
        this.repository.getInteraction(sourceCommentId),
      ]);
      if (
        !interaction ||
        !isEligibleInvocation({
          context,
          aiUserId: this.config.aiUserId,
          triggerKind: interaction.trigger_kind,
        })
      ) {
        await this.repository.fail(sourceCommentId, "not_eligible", null);
        return { status: "ignored", category: "not_eligible" };
      }

      // No participant can consent on behalf of other people in thread context.
      const authors = [...new Set([context.post.user_id, context.source.user_id,
        ...context.ancestors.map(c => c.user_id), ...context.nearby.map(c => c.user_id)])]
        .filter(id => id !== this.config.aiUserId);
      const permissions = await Promise.all(authors.map(id => this.repository.hasAIConsent(id)));
      if (permissions.some(allowed => !allowed)) {
        await this.repository.fail(sourceCommentId, "ai_consent_required", null);
        return { status: "ignored", category: "ai_consent_required" };
      }

      const rate = await this.repository.checkRateLimit(
        context.source.user_id,
        this.config.perUserWindowMinutes,
        this.config.perUserWindowLimit,
        this.config.dailySoftLimit,
      );
      if (!rate.allowed) {
        await this.repository.fail(sourceCommentId, "rate_limited", null);
        logEvent("cheese_ai_rate_limited", sourceCommentId, {
          window_count: rate.window_count,
          daily_count: rate.daily_count,
        });
        return { status: "failed", category: "rate_limited" };
      }

      const images = await this.imageLoader.load(context.images);
      const threadContext = buildDynamicThreadContext(
        context,
        this.config.aiUserId,
        images.length,
      );
      if (containsRawIdentifier(threadContext)) {
        throw new Error("raw_identifier_in_prompt");
      }
      const result = await this.provider.generateCommunityReply({
        systemPrompt: CHEESE_AI_SYSTEM_PROMPT,
        threadContext,
        images,
      });
      if ((await Promise.all(authors.map(id => this.repository.hasAIConsent(id)))).some(allowed => !allowed)) {
        await this.repository.fail(sourceCommentId, "ai_consent_required", null);
        return { status: "ignored", category: "ai_consent_required" };
      }
      const outputCommentId = this.uuid();
      await this.repository.complete(
        sourceCommentId,
        outputCommentId,
        result.text,
        result.latencyMs,
        result.inputTokenCount,
        result.outputTokenCount,
        result.finishReason,
      );
      logEvent("cheese_ai_completed", sourceCommentId, {
        output_comment_id: outputCommentId,
        trigger_kind: interaction.trigger_kind,
        image_count: images.length,
        model: this.config.model,
        prompt_version: this.config.promptVersion,
        latency_ms: result.latencyMs,
        input_tokens: result.inputTokenCount,
        output_tokens: result.outputTokenCount,
      });
      return { status: "completed" };
    } catch (error: unknown) {
      const category = errorCategory(error);
      const retryAfterSeconds = retryDelaySeconds(error);
      try {
        await this.repository.fail(
          sourceCommentId,
          category,
          retryAfterSeconds,
        );
      } catch (failureRecordingError: unknown) {
        logEvent("cheese_ai_failure_recording_failed", sourceCommentId, {
          category,
          recording_category: errorCategory(failureRecordingError),
        });
      }
      logEvent("cheese_ai_failed", sourceCommentId, {
        category,
        retry_scheduled: retryAfterSeconds !== null,
      });
      return { status: "failed", category };
    }
  }
}

export function createInteractionHandler(
  config: AppConfig,
  fetcher: typeof fetch = runtimeFetch,
): CheeseAIInteractionHandler {
  const repository = new SupabaseRepository(
    config.supabaseUrl,
    config.supabaseServiceRoleKey,
    fetcher,
  );
  return new CheeseAIInteractionHandler(
    repository,
    new GeminiCheeseAIProvider(config.geminiApiKey, fetcher, config.model),
    new SupabasePostImageLoader(config.supabaseUrl, fetcher),
    config,
  );
}
