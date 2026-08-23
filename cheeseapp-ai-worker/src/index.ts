import { ConfigurationError, loadConfig } from "./config";
import {
  createInteractionHandler,
  CheeseAIInteractionHandler,
} from "./ai/interactionHandler";
import {
  SupabaseRepository,
  SupabaseRequestError,
} from "./supabase";
import type { Env } from "./types";

const COMMENT_EVENT_PATH = "/v1/comment-events";
const MAX_REQUEST_BYTES = 1_024;
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

export default {
  async fetch(request, env, context): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/health") {
        const config = loadConfig(env);
        return json({
          ok: true,
          enabled: config.enabled,
          geminiConfigured: config.geminiApiKey.length > 0,
          model: config.model,
          promptVersion: config.promptVersion,
        });
      }
      if (request.method === "POST" && url.pathname === COMMENT_EVENT_PATH) {
        return await handleCommentEvent(request, env, context);
      }
      return json({ error: "not_found" }, 404);
    } catch (error: unknown) {
      if (error instanceof RequestValidationError) {
        return json({ error: error.category }, error.status);
      }
      if (error instanceof ConfigurationError) {
        return json({ error: "service_not_configured" }, 503);
      }
      if (error instanceof SupabaseRequestError) {
        const status = error.status === 401 ? 401 : 502;
        return json({ error: "upstream_request_failed" }, status);
      }
      console.log(JSON.stringify({ event: "cheese_ai_request_failed" }));
      return json({ error: "internal_error" }, 500);
    }
  },

  scheduled(_controller, env, context): void {
    context.waitUntil(processScheduledWork(env).catch(logScheduledFailure));
  },
} satisfies ExportedHandler<Env>;
