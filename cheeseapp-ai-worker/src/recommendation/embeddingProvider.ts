import {
  RECOMMENDATION_EMBEDDING_DIMENSION,
  RECOMMENDATION_EMBEDDING_MODEL,
} from "../config";
import { runtimeFetch } from "../runtimeFetch";

const GEMINI_BASE_URL =
  "https://generativelanguage.googleapis.com/v1beta/models";
const REQUEST_TIMEOUT_MS = 12_000;

export type EmbeddingErrorCategory =
  | "missing_api_key"
  | "provider_auth"
  | "provider_bad_request"
  | "provider_quota"
  | "provider_unavailable"
  | "provider_timeout"
  | "provider_network"
  | "invalid_embedding";

export class EmbeddingProviderError extends Error {
  override readonly name = "EmbeddingProviderError";

  constructor(
    readonly category: EmbeddingErrorCategory,
    readonly retryable: boolean,
  ) {
    super(category);
  }
}

export interface NormalizedEmbedding {
  readonly values: readonly number[];
  readonly norm: number;
  readonly providerNorm: number;
  readonly latencyMs: number;
}

function valuesFromResponse(value: unknown): readonly number[] | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  const direct = record.embedding;
  if (typeof direct === "object" && direct !== null) {
    const values = (direct as Record<string, unknown>).values;
    if (Array.isArray(values) && values.every((item) => typeof item === "number")) {
      return values;
    }
  }
  const embeddings = record.embeddings;
  if (Array.isArray(embeddings) && embeddings.length > 0) {
    const first = embeddings[0];
    if (typeof first === "object" && first !== null) {
      const values = (first as Record<string, unknown>).values;
      if (Array.isArray(values) && values.every((item) => typeof item === "number")) {
        return values;
      }
    }
  }
  return null;
}

function classifyStatus(status: number): EmbeddingProviderError {
  if (status === 401 || status === 403) {
    return new EmbeddingProviderError("provider_auth", false);
  }
  if (status === 429) {
    return new EmbeddingProviderError("provider_quota", true);
  }
  if (status >= 500) {
    return new EmbeddingProviderError("provider_unavailable", true);
  }
  return new EmbeddingProviderError("provider_bad_request", false);
}

export function normalizeEmbedding(values: readonly number[]): {
  values: readonly number[];
  norm: number;
  providerNorm: number;
} {
  if (
    values.length !== RECOMMENDATION_EMBEDDING_DIMENSION ||
    values.some((value) => !Number.isFinite(value))
  ) {
    throw new EmbeddingProviderError("invalid_embedding", false);
  }
  const providerNorm = Math.sqrt(
    values.reduce((sum, value) => sum + value * value, 0),
  );
  if (!Number.isFinite(providerNorm) || providerNorm <= 0) {
    throw new EmbeddingProviderError("invalid_embedding", false);
  }
  const normalized = values.map((value) => value / providerNorm);
  const norm = Math.sqrt(
    normalized.reduce((sum, value) => sum + value * value, 0),
  );
  if (!Number.isFinite(norm) || Math.abs(norm - 1) > 0.000_1) {
    throw new EmbeddingProviderError("invalid_embedding", false);
  }
  return { values: normalized, norm, providerNorm };
}

export class GeminiEmbeddingProvider {
  constructor(
    private readonly apiKey: string,
    private readonly fetcher: typeof fetch = runtimeFetch,
  ) {}

  async embed(input: string): Promise<NormalizedEmbedding> {
    if (!this.apiKey.trim()) {
      throw new EmbeddingProviderError("missing_api_key", false);
    }
    const startedAt = Date.now();
    try {
      const response = await this.fetcher(
        `${GEMINI_BASE_URL}/${RECOMMENDATION_EMBEDDING_MODEL}:embedContent`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-goog-api-key": this.apiKey,
          },
          body: JSON.stringify({
            model: `models/${RECOMMENDATION_EMBEDDING_MODEL}`,
            content: { parts: [{ text: input }] },
            output_dimensionality: RECOMMENDATION_EMBEDDING_DIMENSION,
          }),
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        },
      );
      if (!response.ok) throw classifyStatus(response.status);
      const values = valuesFromResponse(await response.json());
      if (!values) throw new EmbeddingProviderError("invalid_embedding", false);
      return {
        ...normalizeEmbedding(values),
        latencyMs: Math.max(0, Date.now() - startedAt),
      };
    } catch (error: unknown) {
      if (error instanceof EmbeddingProviderError) throw error;
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new EmbeddingProviderError("provider_timeout", true);
      }
      throw new EmbeddingProviderError("provider_network", true);
    }
  }
}
