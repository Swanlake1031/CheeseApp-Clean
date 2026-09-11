import type { Env } from "./types";

export const CHEESE_AI_MODEL = "gemini-3.5-flash-lite";
export const CHEESE_AI_PROMPT_VERSION = "cheese-community-v3";
export const CHEESE_AI_MAX_OUTPUT_TOKENS = 160;
export const SECONDHAND_DESCRIPTION_PROMPT_VERSION =
  "cheese-secondhand-description-v6";
export const SECONDHAND_DESCRIPTION_MAX_OUTPUT_TOKENS = 2_048;
export const RECOMMENDATION_ALGORITHM_VERSION = "cheese-rec-v1";
export const RECOMMENDATION_EMBEDDING_VERSION = "cheese-semantic-v1";
export const RECOMMENDATION_EMBEDDING_MODEL = "gemini-embedding-2";
export const RECOMMENDATION_EMBEDDING_DIMENSION = 768;
export const RECOMMENDATION_INPUT_FORMAT_VERSION = 1;

// The App Store release serves a 13+ audience. Gemini cannot be enabled by a
// dashboard variable alone: reopening it requires a separately audited source
// change as well as the operational flags below.
export const GEMINI_PROVIDER_RELEASED = false;

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

export interface RecommendationConfig {
  /** Database-only recommendation upkeep, independent of model release. */
  readonly maintenanceEnabled: boolean;
  /** The only switch that permits scheduled embedding calls to Gemini. */
  readonly embeddingProviderEnabled: boolean;
  readonly shadowEnabled: boolean;
  readonly geminiApiKey: string;
  readonly supabaseUrl: string;
  readonly supabaseServiceRoleKey: string;
  readonly algorithmVersion: typeof RECOMMENDATION_ALGORITHM_VERSION;
  readonly embeddingVersion: typeof RECOMMENDATION_EMBEDDING_VERSION;
  readonly embeddingModel: typeof RECOMMENDATION_EMBEDDING_MODEL;
  readonly embeddingDimension: typeof RECOMMENDATION_EMBEDDING_DIMENSION;
  readonly inputFormatVersion: typeof RECOMMENDATION_INPUT_FORMAT_VERSION;
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

function isEnabled(value: string | undefined): boolean {
  return value?.trim().toLowerCase() === "true";
}

export function isGeminiProviderEnabled(env: Env): boolean {
  return (
    GEMINI_PROVIDER_RELEASED &&
    isEnabled(env.CHEESE_GEMINI_RELEASE_ENABLED) &&
    isEnabled(env.CHEESE_AI_ENABLED)
  );
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
    enabled: isGeminiProviderEnabled(env),
    // Keep health checks and controlled failure handling available even when
    // the local Gemini secret has not been configured yet.
    geminiApiKey: env.GEMINI_API_KEY?.trim() ?? "",
    // The disabled release does not need a legacy bot account. Require it only
    // if a future audited source release reopens provider execution.
    aiUserId: isGeminiProviderEnabled(env)
      ? requireValue(env.CHEESE_AI_USER_ID, "CHEESE_AI_USER_ID")
      : env.CHEESE_AI_USER_ID?.trim() ?? "",
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

export function loadRecommendationConfig(env: Env): RecommendationConfig {
  const maintenanceEnabled = isEnabled(env.CHEESE_RECOMMENDATION_JOBS_ENABLED);
  return {
    maintenanceEnabled,
    embeddingProviderEnabled:
      maintenanceEnabled && isGeminiProviderEnabled(env),
    shadowEnabled:
      maintenanceEnabled && isEnabled(env.CHEESE_RECOMMENDATION_SHADOW_ENABLED),
    geminiApiKey: env.GEMINI_API_KEY?.trim() ?? "",
    supabaseUrl: requireValue(env.SUPABASE_URL, "SUPABASE_URL").replace(/\/$/, ""),
    supabaseServiceRoleKey: requireValue(
      env.SUPABASE_SERVICE_ROLE_KEY,
      "SUPABASE_SERVICE_ROLE_KEY",
    ),
    algorithmVersion: RECOMMENDATION_ALGORITHM_VERSION,
    embeddingVersion: RECOMMENDATION_EMBEDDING_VERSION,
    embeddingModel: RECOMMENDATION_EMBEDDING_MODEL,
    embeddingDimension: RECOMMENDATION_EMBEDDING_DIMENSION,
    inputFormatVersion: RECOMMENDATION_INPUT_FORMAT_VERSION,
  };
}
