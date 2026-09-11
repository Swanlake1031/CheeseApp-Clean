import type {
  AuthUser,
  CommentRecord,
  EnqueueResult,
  ForumPostRecord,
  InteractionRecord,
  PostImageRecord,
  PostEmbeddingJob,
  PostRecord,
  RateLimitResult,
  SecondhandImageReference,
  ThreadContext,
} from "./types";
import { runtimeFetch } from "./runtimeFetch";

export class SupabaseRequestError extends Error {
  override readonly name = "SupabaseRequestError";

  constructor(
    readonly status: number,
    readonly category: string,
  ) {
    super(`${category}:${status}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isAuthUser(value: unknown): value is AuthUser {
  return isRecord(value) && typeof value.id === "string";
}

export class SupabaseRepository {
  constructor(
    private readonly baseUrl: string,
    private readonly serviceRoleKey: string,
    private readonly fetcher: typeof fetch = runtimeFetch,
  ) {}

  private serviceHeaders(): HeadersInit {
    const headers: Record<string, string> = {
      apikey: this.serviceRoleKey,
      "Content-Type": "application/json",
    };

    // Supabase's current sb_secret_* keys authenticate through `apikey` and
    // are not JWTs. Only legacy service_role JWTs belong in Authorization.
    if (!this.serviceRoleKey.startsWith("sb_secret_")) {
      headers.Authorization = `Bearer ${this.serviceRoleKey}`;
    }
    return headers;
  }

  private async decode<T>(response: Response, category: string): Promise<T> {
    if (!response.ok) {
      throw new SupabaseRequestError(response.status, category);
    }
    return (await response.json()) as T;
  }

  async authenticate(accessToken: string): Promise<AuthUser> {
    const response = await this.fetcher(`${this.baseUrl}/auth/v1/user`, {
      headers: {
        apikey: this.serviceRoleKey,
        Authorization: `Bearer ${accessToken}`,
      },
    });
    const decoded: unknown = await this.decode<unknown>(
      response,
      "auth_validation_failed",
    );
    if (!isAuthUser(decoded)) {
      throw new SupabaseRequestError(401, "auth_user_invalid");
    }
    return decoded;
  }

  private async restList<T>(path: string): Promise<readonly T[]> {
    const response = await this.fetcher(`${this.baseUrl}/rest/v1/${path}`, {
      headers: this.serviceHeaders(),
    });
    return this.decode<readonly T[]>(response, "supabase_read_failed");
  }

  private async restOne<T>(path: string): Promise<T | null> {
    const rows = await this.restList<T>(path);
    return rows[0] ?? null;
  }

  async rpc<T>(name: string, parameters: Readonly<Record<string, unknown>>): Promise<T> {
    const response = await this.fetcher(
      `${this.baseUrl}/rest/v1/rpc/${encodeURIComponent(name)}`,
      {
        method: "POST",
        headers: this.serviceHeaders(),
        body: JSON.stringify(parameters),
      },
    );
    return this.decode<T>(response, `rpc_${name}_failed`);
  }

  async getComment(commentId: string): Promise<CommentRecord | null> {
    return this.restOne<CommentRecord>(
      `comments?select=id,post_id,user_id,parent_id,content,is_anonymous,is_deleted,created_at&id=eq.${encodeURIComponent(commentId)}&limit=1`,
    );
  }

  async hasAIConsent(userId: string): Promise<boolean> {
    const consent = await this.restOne<{ user_id: string }>(
      `ai_processing_consents?select=user_id&user_id=eq.${encodeURIComponent(userId)}&version=eq.2026-09-11&limit=1`,
    );
    return consent !== null;
  }

  async getPost(postId: string): Promise<PostRecord | null> {
    return this.restOne<PostRecord>(
      `posts?select=id,user_id,type,title,description,status,is_private&id=eq.${encodeURIComponent(postId)}&limit=1`,
    );
  }

  async getForumPost(postId: string): Promise<ForumPostRecord | null> {
    return this.restOne<ForumPostRecord>(
      `forum_posts?select=id,allow_comments,is_locked&id=eq.${encodeURIComponent(postId)}&limit=1`,
    );
  }

  async getInteraction(
    sourceCommentId: string,
  ): Promise<InteractionRecord | null> {
    return this.restOne<InteractionRecord>(
      `cheese_ai_interactions?select=source_comment_id,source_author_id,status,next_attempt_at,trigger_kind&source_comment_id=eq.${encodeURIComponent(sourceCommentId)}&limit=1`,
    );
  }

  async fetchThreadContext(sourceCommentId: string): Promise<ThreadContext> {
    const source = await this.getComment(sourceCommentId);
    if (!source || source.is_deleted) {
      throw new SupabaseRequestError(404, "source_comment_unavailable");
    }

    const post = await this.getPost(source.post_id);
    const forum = await this.getForumPost(source.post_id);
    if (
      !post ||
      !forum ||
      post.type !== "forum" ||
      post.status !== "active" ||
      post.is_private ||
      !forum.allow_comments ||
      forum.is_locked
    ) {
      throw new SupabaseRequestError(404, "source_post_unavailable");
    }

    const ancestors: CommentRecord[] = [];
    let parentId = source.parent_id;
    for (let depth = 0; depth < 4 && parentId; depth += 1) {
      const parent = await this.getComment(parentId);
      if (!parent || parent.is_deleted || parent.post_id !== source.post_id) {
        break;
      }
      ancestors.unshift(parent);
      parentId = parent.parent_id;
    }

    const nearbyCandidates = await this.restList<CommentRecord>(
      `comments?select=id,post_id,user_id,parent_id,content,is_anonymous,is_deleted,created_at&post_id=eq.${encodeURIComponent(source.post_id)}&is_deleted=eq.false&created_at=lte.${encodeURIComponent(source.created_at)}&order=created_at.desc&limit=16`,
    );
    const excluded = new Set([source.id, ...ancestors.map((comment) => comment.id)]);
    const nearby = nearbyCandidates
      .filter((comment) => !excluded.has(comment.id))
      .slice(0, 6)
      .reverse();

    const images = await this.restList<PostImageRecord>(
      `post_images?select=id,post_id,url,bucket,object_path,order_index&post_id=eq.${encodeURIComponent(source.post_id)}&order=order_index.asc.nullslast,created_at.asc&limit=3`,
    );

    return { post, source, ancestors, nearby, images };
  }

  async getOwnedSecondhandImages(
    ownerId: string,
    references: readonly SecondhandImageReference[],
  ): Promise<readonly PostImageRecord[]> {
    const images: PostImageRecord[] = [];
    for (const reference of references) {
      const image = await this.restOne<PostImageRecord>(
        `post_media_staging?select=id,post_id,url,bucket,object_path,order_index&owner_id=eq.${encodeURIComponent(ownerId)}&post_type=eq.secondhand&bucket=eq.post-images&object_path=eq.${encodeURIComponent(reference.object_path)}&status=in.(uploaded,finalized)&limit=1`,
      );
      if (image) images.push(image);
    }
    return images;
  }

  enqueue(
    sourceCommentId: string,
    aiUserId: string,
    model: string,
    promptVersion: string,
  ): Promise<EnqueueResult> {
    return this.rpc<EnqueueResult>("enqueue_cheese_ai_interaction", {
      p_source_comment_id: sourceCommentId,
      p_ai_user_id: aiUserId,
      p_model: model,
      p_prompt_version: promptVersion,
    });
  }

  claim(sourceCommentId: string): Promise<boolean> {
    return this.rpc<boolean>("claim_cheese_ai_interaction", {
      p_source_comment_id: sourceCommentId,
    });
  }

  checkRateLimit(
    sourceAuthorId: string,
    windowMinutes: number,
    windowLimit: number,
    dailyLimit: number,
  ): Promise<RateLimitResult> {
    return this.rpc<RateLimitResult>("check_cheese_ai_rate_limit", {
      p_source_author_id: sourceAuthorId,
      p_window_minutes: windowMinutes,
      p_window_limit: windowLimit,
      p_daily_limit: dailyLimit,
    });
  }

  complete(
    sourceCommentId: string,
    outputCommentId: string,
    content: string,
    latencyMs: number,
    inputTokenCount: number,
    outputTokenCount: number,
    finishReason: string,
  ): Promise<string> {
    return this.rpc<string>("complete_cheese_ai_interaction", {
      p_source_comment_id: sourceCommentId,
      p_output_comment_id: outputCommentId,
      p_content: content,
      p_latency_ms: latencyMs,
      p_input_token_count: inputTokenCount,
      p_output_token_count: outputTokenCount,
      p_finish_reason: finishReason,
    });
  }

  fail(
    sourceCommentId: string,
    category: string,
    retryAfterSeconds: number | null,
  ): Promise<void> {
    return this.rpc<void>("fail_cheese_ai_interaction", {
      p_source_comment_id: sourceCommentId,
      p_error_category: category,
      p_retry_after_seconds: retryAfterSeconds,
    });
  }

  async candidateInteractionIds(
    aiUserId: string,
    lookbackHours = 168,
  ): Promise<readonly string[]> {
    const since = new Date(
      Date.now() - Math.max(1, lookbackHours) * 60 * 60_000,
    ).toISOString();
    return this.rpc<readonly string[]>("list_cheese_ai_candidate_comment_ids", {
      p_ai_user_id: aiUserId,
      p_since: since,
      p_limit: 50,
    });
  }

  async pendingInteractionIds(): Promise<readonly string[]> {
    const rows = await this.restList<InteractionRecord>(
      "cheese_ai_interactions?select=source_comment_id,source_author_id,status,next_attempt_at,trigger_kind&status=in.(pending,processing,failed)&order=created_at.asc&limit=50",
    );
    const now = Date.now();
    return rows
      .filter(
        (row) =>
          row.status !== "failed" ||
          (row.next_attempt_at !== null && Date.parse(row.next_attempt_at) <= now),
      )
      .map((row) => row.source_comment_id);
  }

  backfillForumEmbeddingJobs(limit = 100): Promise<number> {
    return this.rpc<number>("backfill_forum_embedding_jobs", { p_limit: limit });
  }

  claimPostEmbeddingJobs(limit = 8): Promise<readonly PostEmbeddingJob[]> {
    return this.rpc<readonly PostEmbeddingJob[]>("claim_post_embedding_jobs", {
      p_limit: limit,
    });
  }

  completePostEmbeddingJob(
    jobId: string,
    inputHash: string,
    embedding: readonly number[],
    norm: number,
  ): Promise<boolean> {
    return this.rpc<boolean>("complete_post_embedding_job", {
      p_job_id: jobId,
      p_input_hash: inputHash,
      p_embedding: embedding,
      p_norm: norm,
    });
  }

  failPostEmbeddingJob(
    jobId: string,
    category: string,
    retryable: boolean,
  ): Promise<void> {
    return this.rpc<void>("fail_post_embedding_job", {
      p_job_id: jobId,
      p_error: category,
      p_retryable: retryable,
    });
  }

  refreshRecommendationMetrics(force = false): Promise<boolean> {
    return this.rpc<boolean>("refresh_post_recommendation_metrics", {
      p_force: force,
    });
  }

  backfillRecommendationSignalState(limit = 500): Promise<number> {
    return this.rpc<number>("backfill_recommendation_signal_state", {
      p_limit: limit,
    });
  }

  listRecommendationShadowUsers(limit = 20): Promise<readonly string[]> {
    return this.rpc<readonly string[]>("list_recommendation_shadow_users", {
      p_limit: limit,
    });
  }

  createRecommendationShadowSession(userId: string): Promise<string | null> {
    return this.rpc<string | null>("create_recommendation_feed_session", {
      p_force_refresh: true,
      p_shadow: true,
      p_user_id: userId,
    });
  }
}
