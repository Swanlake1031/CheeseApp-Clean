/** Offline CLI only. Imports the frozen V1 provider; never runs on feed requests. */
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { EmbeddingProviderError, GeminiEmbeddingProvider } from "../../cheeseapp-ai-worker/src/recommendation/embeddingProvider";
import {
  RECOMMENDATION_EMBEDDING_MODEL,
  RECOMMENDATION_EMBEDDING_DIMENSION,
  RECOMMENDATION_EMBEDDING_VERSION,
  RECOMMENDATION_INPUT_FORMAT_VERSION,
} from "../../cheeseapp-ai-worker/src/config";

export interface EmbeddingInput {
  title: string;
  body: string;
  board_name: string;
}

export const contract = {
  embedding_model: RECOMMENDATION_EMBEDDING_MODEL,
  embedding_version: RECOMMENDATION_EMBEDDING_VERSION,
  input_format_version: RECOMMENDATION_INPUT_FORMAT_VERSION,
  dimension: RECOMMENDATION_EMBEDDING_DIMENSION,
};

export function canonicalInput(row: EmbeddingInput): string {
  const btrim = (s: string) => s.replace(/^ +| +$/g, "");
  return `task: sentence similarity | query: Title: ${btrim(row.title)}\nBody: ${btrim(row.body)}\nHashtags: #${row.board_name}`;
}

export function inputHash(row: EmbeddingInput): string {
  return createHash("sha256").update(canonicalInput(row), "utf8").digest("hex");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Allowlisted provider quota metadata only: no message, key, headers or project IDs. */
export function safeQuotaDetails(body: unknown): {quota_ids: string[]; retry_delay_seconds?: number} {
  const result: {quota_ids: string[]; retry_delay_seconds?: number} = {quota_ids: []};
  if (!isObject(body) || !isObject(body.error) || !Array.isArray(body.error.details)) return result;
  for (const detail of body.error.details) {
    if (!isObject(detail)) continue;
    if (detail["@type"] === "type.googleapis.com/google.rpc.QuotaFailure" && Array.isArray(detail.violations)) {
      for (const violation of detail.violations) {
        if (isObject(violation) && typeof violation.quotaId === "string"
            && /^[A-Za-z][A-Za-z0-9_]{0,159}$/.test(violation.quotaId)) {
          result.quota_ids.push(violation.quotaId);
        }
      }
    }
    if (detail["@type"] === "type.googleapis.com/google.rpc.RetryInfo"
        && typeof detail.retryDelay === "string" && /^\d+(?:\.\d+)?s$/.test(detail.retryDelay)) {
      const seconds = Number(detail.retryDelay.slice(0, -1));
      if (Number.isFinite(seconds)) result.retry_delay_seconds = seconds;
    }
  }
  return result;
}

export async function withProviderRetry<T>(operation: () => Promise<T>, options: {
  attempts: number;
  retryDelay: (attempt: number) => number | null;
  wait?: (ms: number) => Promise<void>;
}): Promise<T> {
  const wait = options.wait ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  for (let attempt = 1; ; attempt++) {
    try { return await operation(); } catch (error) {
      if (!(error instanceof EmbeddingProviderError) || !error.retryable || attempt >= options.attempts) throw error;
      const delay = options.retryDelay(attempt);
      // null means a terminal quota, or a provider-requested wait beyond this run's bounds.
      if (delay === null || !Number.isFinite(delay) || delay < 0 || delay > 60000) throw error;
      await wait(delay);
    }
  }
}

export function validCache(record: unknown, hash: string): boolean {
  if (!isObject(record)) return false;
  if (!Object.entries(contract).every(([k, v]) => record[k] === v)) return false;
  if (record.input_hash !== hash || typeof record.generated_at !== "string"
      || !/(?:Z|[+-]\d{2}:\d{2})$/.test(record.generated_at)
      || !Number.isFinite(Date.parse(record.generated_at))) return false;
  const vector = record.values;
  return Array.isArray(vector) && vector.length === contract.dimension
    && vector.every((v) => typeof v === "number" && Number.isFinite(v))
    && Math.abs(Math.hypot(...vector) - 1) < 0.0001;
}

export async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    dataset: { type: "string" }, cache: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    "max-requests": { type: "string", default: "300" },
    "request-interval-ms": { type: "string", default: "1000" },
    "max-attempts-per-input": { type: "string", default: "3" },
    "allow-real-external-evaluation": { type: "boolean", default: false },
  } });
  if (!values.dataset || !values.cache) throw new Error("--dataset and --cache required");
  const budget = Number(values["max-requests"]);
  if (!Number.isSafeInteger(budget) || budget < 0 || budget > 10000) {
    throw new Error("Invalid --max-requests");
  }
  const interval = Number(values["request-interval-ms"]);
  if (!Number.isSafeInteger(interval) || interval < 0 || interval > 60000) {
    throw new Error("Invalid --request-interval-ms");
  }
  const attempts = Number(values["max-attempts-per-input"]);
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > 5) {
    throw new Error("Invalid --max-attempts-per-input");
  }
  const rows: EmbeddingInput[] = [];
  const ids = new Set<string>();
  for (const line of (await readFile(values.dataset, "utf8")).split(/\r?\n/).filter(Boolean)) {
    const row: unknown = JSON.parse(line);
    if (!isObject(row) || typeof row.id !== "string" || ids.has(row.id)
        || typeof row.title !== "string" || typeof row.body !== "string"
        || typeof row.board_name !== "string" || !row.board_name
        || row.text !== [row.title, row.body].filter(Boolean).join("\n")
        || (!row.title.replace(/ /g, "") && !row.body.replace(/ /g, ""))) {
      throw new Error("Invalid embedding input; run Python dataset validation first");
    }
    if (row.dataset_kind !== "synthetic" && !(row.dataset_kind === "real_holdout"
        && row.anonymized === true && values["allow-real-external-evaluation"])) {
      throw new Error("Only synthetic text is allowed by default");
    }
    if (["user_id", "author_id", "email", "phone"].some((k) => k in row)) {
      throw new Error("Personal metadata is not allowed");
    }
    ids.add(row.id);
    rows.push({title: row.title, body: row.body, board_name: row.board_name});
  }
  if (!rows.length) throw new Error("Empty dataset");
  let cached = 0;
  const pending: { row: EmbeddingInput; hash: string; file: string }[] = [];
  const queued = new Set<string>();
  for (const row of rows) {
    const hash = inputHash(row);
    const file = join(values.cache, `${contract.embedding_version}-${contract.embedding_model}-${contract.input_format_version}-${hash}.json`);
    try {
      if (validCache(JSON.parse(await readFile(file, "utf8")), hash)) {
        cached += 1;
        continue;
      }
    } catch (error) {
      if (!(error instanceof SyntaxError) && (!isObject(error) || error.code !== "ENOENT")) {
        throw error;
      }
    }
    if (!queued.has(hash)) pending.push({row, hash, file});
    queued.add(hash);
  }
  console.log(JSON.stringify({event: "embedding_plan", ...contract, rows: rows.length,
    cache_hits: cached, requests_needed: pending.length, dry_run: values["dry-run"]}));
  if (values["dry-run"]) return;
  if (pending.length > budget) throw new Error("Request budget exceeded; no provider calls made");
  if (pending.length && !process.env.GEMINI_API_KEY?.trim()) {
    throw new Error("GEMINI_API_KEY unavailable; no provider calls made");
  }
  let quotaDetails: ReturnType<typeof safeQuotaDetails> = {quota_ids: []};
  const diagnosticFetch: typeof fetch = async (input, init) => {
    quotaDetails = {quota_ids: []};
    const response = await fetch(input, init);
    if (response.status === 429) {
      let details: unknown;
      try { details = await response.clone().json(); } catch { /* No raw error logging. */ }
      quotaDetails = safeQuotaDetails(details);
      console.error(JSON.stringify({event: "embedding_quota", http_status: 429, ...quotaDetails}));
    }
    return response;
  };
  const provider = new GeminiEmbeddingProvider(process.env.GEMINI_API_KEY ?? "", diagnosticFetch);
  await mkdir(values.cache, {recursive: true});
  let previousStarted = 0;
  let requestsMade = 0;
  let generated = 0;
  for (const {row, hash, file} of pending) {
    const embedding = await withProviderRetry(async () => {
      if (requestsMade >= budget) throw new Error("Request budget exhausted; cached progress preserved");
      const delay = Math.max(0, interval - (Date.now() - previousStarted));
      if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
      previousStarted = Date.now();
      requestsMade += 1;
      return provider.embed(canonicalInput(row));
    }, {attempts, retryDelay: (attempt) => {
      if (quotaDetails.quota_ids.some((id) => /PerDay|Daily/i.test(id))) return null;
      return Math.max(5000 * 2 ** (attempt - 1), (quotaDetails.retry_delay_seconds ?? 0) * 1000);
    }});
    // Match pgvector's float32 storage, not a second or differently normalized embedding.
    const record = {...contract, input_hash: hash, generated_at: new Date().toISOString(),
      values: embedding.values.map(Math.fround)};
    if (!validCache(record, hash)) throw new Error("Invalid provider vector");
    await writeFile(file, JSON.stringify(record) + "\n", {mode: 0o600});
    generated += 1;
    if (generated % 25 === 0) console.log(JSON.stringify({event: "embedding_progress", generated,
      cached, remaining: pending.length - generated, requests_made: requestsMade}));
  }
  console.log(JSON.stringify({event: "embedding_cache_completed", generated, cached, requests_made: requestsMade}));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error: unknown) => {
    // Provider errors contain categories only, never credentials or response bodies.
    console.error(error instanceof Error ? error.message : "Embedding CLI failed");
    process.exitCode = 1;
  });
}
