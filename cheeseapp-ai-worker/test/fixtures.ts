import {
  CHEESE_AI_MODEL,
  CHEESE_AI_PROMPT_VERSION,
  type AppConfig,
} from "../src/config";
import type {
  CommentRecord,
  PostRecord,
  ThreadContext,
} from "../src/types";

export const AI_USER_ID = "00000000-0000-4000-8000-000000000001";
export const SOURCE_USER_ID = "00000000-0000-4000-8000-000000000002";
export const POST_ID = "00000000-0000-4000-8000-000000000003";
export const SOURCE_COMMENT_ID = "00000000-0000-4000-8000-000000000004";

export const TEST_CONFIG: AppConfig = {
  enabled: true,
  geminiApiKey: "test-key",
  aiUserId: AI_USER_ID,
  supabaseUrl: "https://example.supabase.co",
  supabaseServiceRoleKey: "test-service-role",
  model: CHEESE_AI_MODEL,
  promptVersion: CHEESE_AI_PROMPT_VERSION,
  perUserWindowMinutes: 10,
  perUserWindowLimit: 5,
  dailySoftLimit: 25,
};

export function comment(
  overrides: Partial<CommentRecord> = {},
): CommentRecord {
  return {
    id: SOURCE_COMMENT_ID,
    post_id: POST_ID,
    user_id: SOURCE_USER_ID,
    parent_id: null,
    content: "@奶酪AI 这门课值得选吗？",
    is_anonymous: false,
    is_deleted: false,
    created_at: "2026-08-22T00:00:00.000Z",
    ...overrides,
  };
}

export function post(overrides: Partial<PostRecord> = {}): PostRecord {
  return {
    id: POST_ID,
    user_id: SOURCE_USER_ID,
    type: "forum",
    title: "选课求助",
    description: "想问问这门课的工作量。",
    status: "active",
    is_private: false,
    ...overrides,
  };
}

export function threadContext(
  overrides: Partial<ThreadContext> = {},
): ThreadContext {
  return {
    post: post(),
    source: comment(),
    ancestors: [],
    nearby: [],
    images: [],
    ...overrides,
  };
}
