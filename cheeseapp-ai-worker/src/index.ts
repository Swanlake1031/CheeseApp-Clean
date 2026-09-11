import { handleModeratedUpload } from "./moderation";
import {
  ConfigurationError,
  loadConfig,
  loadRecommendationConfig,
  RECOMMENDATION_ALGORITHM_VERSION,
  RECOMMENDATION_EMBEDDING_DIMENSION,
  RECOMMENDATION_EMBEDDING_MODEL,
  RECOMMENDATION_EMBEDDING_VERSION,
  SECONDHAND_DESCRIPTION_PROMPT_VERSION,
} from "./config";
import {
  createInteractionHandler,
  CheeseAIInteractionHandler,
} from "./ai/interactionHandler";
import {
  SupabaseRepository,
  SupabaseRequestError,
} from "./supabase";
import {
  GeminiCheeseAIProvider,
  GeminiProviderError,
} from "./ai/geminiProvider";
import { SupabasePostImageLoader } from "./ai/postImageLoader";
import {
  parseSecondhandDescriptionRequest,
  SecondhandDescriptionError,
  SecondhandDescriptionHandler,
} from "./ai/secondhandDescriptionHandler";
import type { Env } from "./types";
import { RecommendationProcessor } from "./recommendation/processor";

const COMMENT_EVENT_PATH = "/v1/comment-events";
const SECONDHAND_DESCRIPTION_PATH = "/v1/secondhand/generate-description";
const MAX_REQUEST_BYTES = 1_024;
const MAX_SECONDHAND_REQUEST_BYTES = 8_192;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface CommentEventBody {
  readonly source_comment_id: string;
}

function json(
  value: Readonly<Record<string, unknown>>,
  status = 200,
): Response {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("Authorization")?.trim() ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization);
  return match?.[1]?.trim() || null;
}

function isCommentEventBody(value: unknown): value is CommentEventBody {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return (
    Object.keys(record).length === 1 &&
    typeof record.source_comment_id === "string" &&
    UUID_PATTERN.test(record.source_comment_id)
  );
}

async function parseCommentEvent(request: Request): Promise<CommentEventBody> {
  const declaredLength = Number.parseInt(
    request.headers.get("Content-Length") ?? "0",
    10,
  );
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new RequestValidationError("request_too_large", 413);
  }

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    throw new RequestValidationError("invalid_json", 400);
  }
  if (new TextEncoder().encode(raw).byteLength > MAX_REQUEST_BYTES) {
    throw new RequestValidationError("request_too_large", 413);
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(raw) as unknown;
  } catch {
    throw new RequestValidationError("invalid_json", 400);
  }
  if (!isCommentEventBody(decoded)) {
    throw new RequestValidationError("invalid_comment_event", 400);
  }
  return decoded;
}

async function parseBoundedJSON(
  request: Request,
  maximumBytes: number,
): Promise<unknown> {
  const declaredLength = Number.parseInt(
    request.headers.get("Content-Length") ?? "0",
    10,
  );
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new RequestValidationError("request_too_large", 413);
  }
  let raw: string;
  try {
    raw = await request.text();
  } catch {
    throw new RequestValidationError("invalid_json", 400);
  }
  if (new TextEncoder().encode(raw).byteLength > maximumBytes) {
    throw new RequestValidationError("request_too_large", 413);
  }
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    throw new RequestValidationError("invalid_json", 400);
  }
}

class RequestValidationError extends Error {
  override readonly name = "RequestValidationError";

  constructor(
    readonly category: string,
    readonly status: number,
  ) {
    super(category);
  }
}

async function handleCommentEvent(
  request: Request,
  env: Env,
  context: ExecutionContext,
): Promise<Response> {
  const token = bearerToken(request);
  if (!token) {
    return json({ error: "unauthorized" }, 401);
  }

  const config = loadConfig(env);
  if (!config.enabled) {
    return json({ accepted: false, reason: "ai_disabled" }, 503);
  }

  const body = await parseCommentEvent(request);
  const repository = new SupabaseRepository(
    config.supabaseUrl,
    config.supabaseServiceRoleKey,
  );
  const [authenticatedUser, sourceComment] = await Promise.all([
    repository.authenticate(token),
    repository.getComment(body.source_comment_id),
  ]);
  if (!sourceComment || authenticatedUser.id !== sourceComment.user_id) {
    return json({ error: "forbidden" }, 403);
  }

  const handler = createInteractionHandler(config);
  const enqueueResult = await handler.enqueue(body.source_comment_id);
  if (!enqueueResult.accepted) {
    return json({ accepted: false, reason: "not_eligible" }, 200);
  }

  context.waitUntil(handler.process(body.source_comment_id));
  return json(
    {
      accepted: true,
      queued: enqueueResult.status !== "completed",
    },
    202,
  );
}

async function handleSecondhandDescription(
  request: Request,
  env: Env,
): Promise<Response> {
  const token = bearerToken(request);
  if (!token) return json({ error: "unauthorized" }, 401);

  const config = loadConfig(env);
  if (!config.enabled) return json({ error: "ai_disabled" }, 503);

  const parsed = parseSecondhandDescriptionRequest(
    await parseBoundedJSON(request, MAX_SECONDHAND_REQUEST_BYTES),
  );
  const handler = new SecondhandDescriptionHandler(
    new SupabaseRepository(
      config.supabaseUrl,
      config.supabaseServiceRoleKey,
    ),
    env.SECONDHAND_AI_RATE_LIMITER,
    new SupabasePostImageLoader(config.supabaseUrl),
    new GeminiCheeseAIProvider(config.geminiApiKey),
  );
  const result = await handler.generate(token, parsed);
  console.log(
    JSON.stringify({
      event: "secondhand_ai_description_completed",
      image_count: result.imageCount,
      latency_ms: result.latencyMs,
      input_tokens: result.inputTokenCount,
      output_tokens: result.outputTokenCount,
      finish_reason: result.finishReason,
      prompt_version: SECONDHAND_DESCRIPTION_PROMPT_VERSION,
    }),
  );
  return json({ description: result.description });
}

async function processScheduledWork(env: Env): Promise<void> {
  const config = loadConfig(env);
  if (!config.enabled) {
    return;
  }

  const repository = new SupabaseRepository(
    config.supabaseUrl,
    config.supabaseServiceRoleKey,
  );
  const handler = createInteractionHandler(config);
  const candidateIds = await repository.candidateInteractionIds(config.aiUserId);
  const pendingIds = await repository.pendingInteractionIds();
  const ids = [...new Set([...candidateIds, ...pendingIds])].slice(0, 20);

  for (let offset = 0; offset < ids.length; offset += 2) {
    await Promise.all(
      ids
        .slice(offset, offset + 2)
        .map((sourceCommentId) => enqueueAndProcess(handler, sourceCommentId)),
    );
  }
}

async function processScheduledRecommendationWork(env: Env): Promise<void> {
  const config = loadRecommendationConfig(env);
  if (!config.enabled) return;
  await new RecommendationProcessor(config).runScheduledBatch();
}

function logScheduledFailure(error: unknown): void {
  console.error(
    JSON.stringify({
      event: "cheese_ai_schedule_failed",
      category:
        error instanceof SupabaseRequestError
          ? error.category
          : error instanceof ConfigurationError
            ? "configuration_error"
            : "scheduled_processing_error",
      status: error instanceof SupabaseRequestError ? error.status : undefined,
    }),
  );
}

async function enqueueAndProcess(
  handler: CheeseAIInteractionHandler,
  sourceCommentId: string,
): Promise<void> {
  try {
    const result = await handler.enqueue(sourceCommentId);
    if (result.accepted) {
      await handler.process(sourceCommentId);
    }
  } catch (error: unknown) {
    const category =
      error instanceof SupabaseRequestError
        ? error.category
        : error instanceof ConfigurationError
          ? "configuration_error"
          : "scheduled_processing_error";
    console.log(
      JSON.stringify({
        event: "cheese_ai_scheduled_item_failed",
        source_comment_id: sourceCommentId,
        category,
      }),
    );
  }
}

export async function handleWorkerRequest(
  request: Request,
  env: Env,
  context: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);
  try {
    if (request.method === "POST" && url.pathname === "/v1/media/upload") return handleModeratedUpload(request, env);
    if (request.method === "GET" && url.pathname === "/health") {
      const config = loadConfig(env);
      return json({
        ok: true,
        enabled: config.enabled,
        geminiConfigured: config.geminiApiKey.length > 0,
        model: config.model,
        promptVersion: config.promptVersion,
        secondhandPromptVersion: SECONDHAND_DESCRIPTION_PROMPT_VERSION,
        recommendationJobsEnabled:
          loadRecommendationConfig(env).enabled,
        recommendationAlgorithmVersion: RECOMMENDATION_ALGORITHM_VERSION,
        recommendationEmbeddingVersion: RECOMMENDATION_EMBEDDING_VERSION,
        recommendationEmbeddingModel: RECOMMENDATION_EMBEDDING_MODEL,
        recommendationEmbeddingDimension: RECOMMENDATION_EMBEDDING_DIMENSION,
      });
    }
    if (request.method === "POST" && url.pathname === COMMENT_EVENT_PATH) {
      return await handleCommentEvent(request, env, context);
    }
    if (
      request.method === "POST" &&
      url.pathname === SECONDHAND_DESCRIPTION_PATH
    ) {
      return await handleSecondhandDescription(request, env);
    }
    return json({ error: "not_found" }, 404);
  } catch (error: unknown) {
    if (error instanceof RequestValidationError) {
      return json({ error: error.category }, error.status);
    }
    if (error instanceof ConfigurationError) {
      return json({ error: "service_not_configured" }, 503);
    }
    if (error instanceof SecondhandDescriptionError) {
      console.log(
        JSON.stringify({
          event: "secondhand_ai_description_failed",
          category: error.category,
          status: error.status,
          prompt_version: SECONDHAND_DESCRIPTION_PROMPT_VERSION,
        }),
      );
      return json({ error: error.category }, error.status);
    }
    if (error instanceof GeminiProviderError) {
      const status =
        error.category === "provider_timeout"
          ? 504
          : error.retryable
            ? 503
            : 422;
      if (url.pathname === SECONDHAND_DESCRIPTION_PATH) {
        console.log(
          JSON.stringify({
            event: "secondhand_ai_description_failed",
            category: error.category,
            status,
            retryable: error.retryable,
            prompt_version: SECONDHAND_DESCRIPTION_PROMPT_VERSION,
          }),
        );
      }
      return json({ error: "generation_failed" }, status);
    }
    if (error instanceof SupabaseRequestError) {
      if (
        error.status === 401 &&
        url.pathname === SECONDHAND_DESCRIPTION_PATH
      ) {
        return json({ error: "unauthorized" }, 401);
      }
      if (error.status === 401) {
        return json({ error: "upstream_request_failed" }, 401);
      }
      return json({ error: "upstream_request_failed" }, 502);
    }
    console.log(JSON.stringify({ event: "cheese_ai_request_failed" }));
    return json({ error: "internal_error" }, 500);
  }
}

export default {
  fetch: handleWorkerRequest,

  scheduled(_controller, env, context): void {
    context.waitUntil(Promise.all([
      processScheduledWork(env).catch(logScheduledFailure),
      processScheduledRecommendationWork(env).catch((error: unknown) => {
        console.error(JSON.stringify({
          event: "recommendation_schedule_failed",
          category:
            error instanceof SupabaseRequestError
              ? error.category
              : error instanceof ConfigurationError
                ? "configuration_error"
                : "scheduled_processing_error",
        }));
      }),
    ]).then(() => undefined));
  },
} satisfies ExportedHandler<Env>;
