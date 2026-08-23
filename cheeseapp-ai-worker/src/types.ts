export interface Env {
  readonly GEMINI_API_KEY?: string;
  readonly CHEESE_AI_USER_ID?: string;
  readonly SUPABASE_URL?: string;
  readonly SUPABASE_SERVICE_ROLE_KEY?: string;
  readonly CHEESE_AI_ENABLED?: string;
  readonly CHEESE_AI_MODEL?: string;
  readonly CHEESE_AI_PROMPT_VERSION?: string;
  readonly CHEESE_AI_PER_USER_WINDOW_MINUTES?: string;
  readonly CHEESE_AI_PER_USER_WINDOW_LIMIT?: string;
  readonly CHEESE_AI_DAILY_SOFT_LIMIT?: string;
}

export interface AuthUser {
  readonly id: string;
}

export interface CommentRecord {
  readonly id: string;
  readonly post_id: string;
  readonly user_id: string;
  readonly parent_id: string | null;
  readonly content: string;
  readonly is_anonymous: boolean;
  readonly is_deleted: boolean;
  readonly created_at: string;
}

export interface PostRecord {
  readonly id: string;
  readonly user_id: string;
  readonly type: string;
  readonly title: string | null;
  readonly description: string | null;
  readonly status: string;
  readonly is_private: boolean;
}

export interface ForumPostRecord {
  readonly id: string;
  readonly allow_comments: boolean;
  readonly is_locked: boolean;
}

export type InteractionTriggerKind = "mention" | "continuation";

export interface PostImageRecord {
  readonly id: string;
  readonly post_id: string;
  readonly url: string;
  readonly bucket: string | null;
  readonly object_path: string | null;
  readonly order_index: number | null;
}

export interface InteractionRecord {
  readonly source_comment_id: string;
  readonly source_author_id: string;
  readonly status: "pending" | "processing" | "completed" | "failed";
  readonly next_attempt_at: string | null;
  readonly trigger_kind: InteractionTriggerKind;
}

export interface EnqueueResult {
  readonly accepted: boolean;
  readonly created?: boolean;
  readonly status?: string;
  readonly reason?: string;
}

export interface RateLimitResult {
  readonly allowed: boolean;
  readonly window_count: number;
  readonly daily_count: number;
}

export interface CheeseAIInput {
  readonly systemPrompt: string;
  readonly threadContext: string;
  readonly images: readonly CheeseAIImage[];
}

export interface CheeseAIImage {
  readonly mimeType: string;
  readonly data: string;
}

export interface CheeseAIResult {
  readonly text: string;
  readonly inputTokenCount: number;
  readonly outputTokenCount: number;
  readonly finishReason: string;
  readonly latencyMs: number;
}

export interface CheeseAIProvider {
  generateCommunityReply(input: CheeseAIInput): Promise<CheeseAIResult>;
}

export interface ThreadContext {
  readonly post: PostRecord;
  readonly source: CommentRecord;
  readonly ancestors: readonly CommentRecord[];
  readonly nearby: readonly CommentRecord[];
  readonly images: readonly PostImageRecord[];
}
