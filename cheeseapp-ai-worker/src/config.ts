import type { Env } from "./types";

export const CHEESE_AI_MODEL = "gemini-3.5-flash-lite";
export const CHEESE_AI_PROMPT_VERSION = "cheese-community-v3";
export const CHEESE_AI_MAX_OUTPUT_TOKENS = 160;

export interface AppConfig {
  readonly enabled: boolean;
  readonly geminiApiKey: string;
  readonly aiUserId: string;
  readonly supabaseUrl: string;
  readonly supabaseServiceRoleKey: string;
  readonly model: typeof CHEESE_AI_MODEL;
  readonly promptVersion: typeof CHEESE_AI_PROMPT_VERSION;
  readonly perUserWindowMinutes: number;
  readonly perUserWindowLimit: number;
  readonly dailySoftLimit: number;
}

export class ConfigurationError extends Error {
  override readonly name = "ConfigurationError";
}

function requireValue(value: string | undefined, name: string): string {
  const trimmed = value?.trim();
  if (!trimmed) {
    throw new ConfigurationError(`Missing ${name}`);
  }
  return trimmed;
}

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function loadConfig(env: Env): AppConfig {
  const configuredModel = env.CHEESE_AI_MODEL?.trim() || CHEESE_AI_MODEL;
  const configuredPromptVersion =
    env.CHEESE_AI_PROMPT_VERSION?.trim() || CHEESE_AI_PROMPT_VERSION;

  if (configuredModel !== CHEESE_AI_MODEL) {
    throw new ConfigurationError(
      `Unsupported v1 model configuration: ${configuredModel}`,
    );
  }
  if (configuredPromptVersion !== CHEESE_AI_PROMPT_VERSION) {
    throw new ConfigurationError(
      `Unsupported v1 prompt configuration: ${configuredPromptVersion}`,
    );
  }

  return {
    enabled: (env.CHEESE_AI_ENABLED ?? "false").toLowerCase() === "true",
    // Keep health checks and controlled failure handling available even when
    // the local Gemini secret has not been configured yet.
    geminiApiKey: env.GEMINI_API_KEY?.trim() ?? "",
    aiUserId: requireValue(env.CHEESE_AI_USER_ID, "CHEESE_AI_USER_ID"),
    supabaseUrl: requireValue(env.SUPABASE_URL, "SUPABASE_URL").replace(
      /\/$/,
      "",
    ),
    supabaseServiceRoleKey: requireValue(
      env.SUPABASE_SERVICE_ROLE_KEY,
      "SUPABASE_SERVICE_ROLE_KEY",
    ),
    model: CHEESE_AI_MODEL,
    promptVersion: CHEESE_AI_PROMPT_VERSION,
    perUserWindowMinutes: positiveInteger(
      env.CHEESE_AI_PER_USER_WINDOW_MINUTES,
      10,
    ),
    perUserWindowLimit: positiveInteger(
      env.CHEESE_AI_PER_USER_WINDOW_LIMIT,
      5,
    ),
    dailySoftLimit: positiveInteger(env.CHEESE_AI_DAILY_SOFT_LIMIT, 25),
  };
}
