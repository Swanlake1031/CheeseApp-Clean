type JSONValue =
  | string
  | number
  | boolean
  | null
  | { [key: string]: JSONValue }
  | JSONValue[];

type PushJob = {
  id: number;
  recipient_user_id: string;
  kind: string;
  title: string;
  body: string;
  payload: Record<string, JSONValue> | null;
  thread_id: string | null;
  collapse_key: string | null;
  attempts: number;
  created_at: string;
};

type PushTokenRow = {
  token: string;
  platform: string | null;
};

type DispatchRequest = {
  reason?: string;
  force?: boolean;
  batch_size?: number;
};

type APNSResult = {
  ok: boolean;
  status?: number;
  reason?: string;
  invalidToken?: boolean;
  retryable?: boolean;
  retryAfterSeconds?: number | null;
};

const DEFAULT_BATCH_SIZE = 25;
const DEFAULT_FUNCTION_TIMEOUT_MS = 2_000;
const MAX_BATCH_SIZE = 100;
const MAX_RETRY_DELAY_SECONDS = 3_600;
const MAX_BATCH_ROUNDS = 6;
const textEncoder = new TextEncoder();

let cachedSigningKeyPromise: Promise<CryptoKey> | null = null;
let cachedSigningKeyFingerprint = "";
let cachedProviderToken = {
  value: "",
  expiresAt: 0,
  keyFingerprint: "",
};

function env(name: string, fallback = ""): string {
  return Deno.env.get(name)?.trim() || fallback;
}

function requiredEnv(name: string): string {
  const value = env(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function projectURL(): string {
  return env("SUPABASE_URL", "https://zeuivahkowbxmfzsnagt.supabase.co");
}

function serviceRoleKey(): string {
  return requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
}

function apnsPrivateKey(): string {
  return requiredEnv("APNS_AUTH_KEY");
}

function apnsKeyID(): string {
  return requiredEnv("APNS_KEY_ID");
}

function appleTeamID(): string {
  return requiredEnv("APPLE_TEAM_ID");
}

function appBundleID(): string {
  return env("APP_BUNDLE_ID", "com.timonayf.cheeseapp");
}

function dispatchToken(): string {
  return requiredEnv("PUSH_DISPATCH_TOKEN");
}

function jsonResponse(status: number, payload: Record<string, JSONValue>): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function authorized(req: Request): boolean {
  const expected = dispatchToken();
  const headerToken = req.headers.get("x-push-dispatch-token")?.trim();
  if (headerToken && headerToken === expected) {
    return true;
  }

  const bearer = req.headers.get("authorization")?.trim();
  return bearer === `Bearer ${expected}`;
}

function parseJSON<T>(text: string): T | null {
  if (!text.trim()) {
    return null;
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

function authHeaders(extra: Record<string, string> = {}): HeadersInit {
  const key = serviceRoleKey();
  return {
    Authorization: `Bearer ${key}`,
    apikey: key,
    ...extra,
  };
}

function restURL(path: string): string {
  return `${projectURL().replace(/\/+$/, "")}/rest/v1/${path.replace(/^\/+/, "")}`;
}

function rpcURL(name: string): string {
  return `${projectURL().replace(/\/+$/, "")}/rest/v1/rpc/${name}`;
}

async function parseResponse(response: Response): Promise<JSONValue | string | null> {
  const text = await response.text();
  if (!text) {
    return null;
  }

  const parsed = parseJSON<JSONValue>(text);
  return parsed ?? text;
}

function encodeQuery(query: Record<string, string>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (!value) {
      continue;
    }
    params.set(key, value);
  }
  return params.toString();
}

async function callRPC<T>(name: string, body: Record<string, JSONValue>): Promise<T> {
  const response = await fetch(rpcURL(name), {
    method: "POST",
    headers: authHeaders({
      "Content-Type": "application/json",
    }),
    body: JSON.stringify(body),
  });

  const payload = await parseResponse(response);
  if (!response.ok) {
    throw new Error(
      `RPC ${name} failed (${response.status}): ${
        typeof payload === "string" ? payload : JSON.stringify(payload)
      }`,
    );
  }

  return payload as T;
}

async function selectRows<T>(table: string, query: Record<string, string>): Promise<T[]> {
  const qs = encodeQuery(query);
  const response = await fetch(`${restURL(table)}${qs ? `?${qs}` : ""}`, {
    headers: authHeaders({
      Accept: "application/json",
    }),
  });

  const payload = await parseResponse(response);
  if (!response.ok) {
    throw new Error(
      `Select ${table} failed (${response.status}): ${
        typeof payload === "string" ? payload : JSON.stringify(payload)
      }`,
    );
  }

  return Array.isArray(payload) ? (payload as T[]) : [];
}

async function patchRows(
  table: string,
  query: Record<string, string>,
  patch: Record<string, JSONValue>,
): Promise<void> {
  const qs = encodeQuery(query);
  const response = await fetch(`${restURL(table)}${qs ? `?${qs}` : ""}`, {
    method: "PATCH",
    headers: authHeaders({
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    }),
    body: JSON.stringify(patch),
  });

  if (!response.ok) {
    const payload = await parseResponse(response);
    throw new Error(
      `Patch ${table} failed (${response.status}): ${
        typeof payload === "string" ? payload : JSON.stringify(payload)
      }`,
    );
  }
}

async function deleteRows(table: string, query: Record<string, string>): Promise<void> {
  const qs = encodeQuery(query);
  const response = await fetch(`${restURL(table)}${qs ? `?${qs}` : ""}`, {
    method: "DELETE",
    headers: authHeaders({
      Prefer: "return=minimal",
    }),
  });

  if (!response.ok) {
    const payload = await parseResponse(response);
    throw new Error(
      `Delete ${table} failed (${response.status}): ${
        typeof payload === "string" ? payload : JSON.stringify(payload)
      }`,
    );
  }
}

function nowISO(): string {
  return new Date().toISOString();
}

function retryDelaySeconds(attempts: number, fallbackSeconds = 60): number {
  const base = Math.max(Number.isFinite(fallbackSeconds) ? fallbackSeconds : 60, 15);
  const exponent = Math.max(attempts, 1) - 1;
  return Math.min(base * (2 ** exponent), MAX_RETRY_DELAY_SECONDS);
}

async function updateJob(id: number, patch: Record<string, JSONValue>): Promise<void> {
  await patchRows("push_notification_jobs", { id: `eq.${id}` }, patch);
}

async function markSent(jobID: number): Promise<void> {
  await updateJob(jobID, {
    status: "sent",
    sent_at: nowISO(),
    locked_at: null,
    locked_by: null,
    last_error: null,
    updated_at: nowISO(),
  });
}

async function markCanceled(jobID: number, reason: string): Promise<void> {
  await updateJob(jobID, {
    status: "canceled",
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO(),
  });
}

async function markFailed(jobID: number, reason: string): Promise<void> {
  await updateJob(jobID, {
    status: "failed",
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO(),
  });
}

async function markRetry(
  job: PushJob,
  reason: string,
  retryAfterSeconds: number | null,
): Promise<void> {
  const delay = retryDelaySeconds(job.attempts, retryAfterSeconds ?? 60);
  await updateJob(job.id, {
    status: "pending",
    available_at: new Date(Date.now() + delay * 1_000).toISOString(),
    locked_at: null,
    locked_by: null,
    last_error: reason || null,
    updated_at: nowISO(),
  });
}

async function claimJobs(limit: number): Promise<PushJob[]> {
  return await callRPC<PushJob[]>("claim_push_notification_jobs", {
    p_limit: limit,
    p_worker_id: `supabase-edge:${Date.now()}`,
  });
}

async function activeTokensForUser(userID: string): Promise<PushTokenRow[]> {
  return await selectRows<PushTokenRow>("user_push_tokens", {
    select: "token,platform",
    user_id: `eq.${userID}`,
  });
}

async function removeInvalidToken(token: string): Promise<void> {
  try {
    await deleteRows("user_push_tokens", {
      token: `eq.${token}`,
    });
  } catch (error) {
    console.error("Failed to delete invalid push token", error);
  }
}

function base64URLEncode(input: string | Uint8Array | ArrayBuffer): string {
  const bytes = input instanceof Uint8Array
    ? input
    : input instanceof ArrayBuffer
    ? new Uint8Array(input)
    : textEncoder.encode(input);

  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const cleaned = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/-----BEGIN EC PRIVATE KEY-----/g, "")
    .replace(/-----END EC PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");

  const binary = atob(cleaned);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

function derLength(bytes: Uint8Array, offset: number): { value: number; bytesRead: number } {
  const first = bytes[offset];
  if ((first & 0x80) === 0) {
    return { value: first, bytesRead: 1 };
  }

  const byteCount = first & 0x7f;
  let value = 0;
  for (let index = 0; index < byteCount; index += 1) {
    value = (value << 8) | bytes[offset + 1 + index];
  }
  return { value, bytesRead: 1 + byteCount };
}

function derToJose(signature: Uint8Array, size = 32): Uint8Array {
  if (signature[0] !== 0x30) {
    throw new Error("Invalid DER signature.");
  }

  const sequenceLength = derLength(signature, 1);
  let offset = 1 + sequenceLength.bytesRead;
  if (offset >= signature.length || signature[offset] !== 0x02) {
    throw new Error("Invalid DER integer prefix for r.");
  }

  const rLength = derLength(signature, offset + 1);
  const rStart = offset + 1 + rLength.bytesRead;
  const r = signature.slice(rStart, rStart + rLength.value);
  offset = rStart + rLength.value;

  if (offset >= signature.length || signature[offset] !== 0x02) {
    throw new Error("Invalid DER integer prefix for s.");
  }

  const sLength = derLength(signature, offset + 1);
  const sStart = offset + 1 + sLength.bytesRead;
  const s = signature.slice(sStart, sStart + sLength.value);

  const output = new Uint8Array(size * 2);
  output.set(r.slice(-size), size - Math.min(size, r.length));
  output.set(s.slice(-size), size * 2 - Math.min(size, s.length));
  return output;
}

function signatureToJose(signature: Uint8Array, size = 32): Uint8Array {
  // Some WebCrypto runtimes return raw IEEE-P1363 signatures for ECDSA,
  // while others return DER-encoded ASN.1. APNs expects JOSE raw (r || s).
  if (signature.length === size * 2) {
    return signature;
  }
  return derToJose(signature, size);
}

function apnsFingerprint(): string {
  return [appleTeamID(), apnsKeyID(), apnsPrivateKey()].join(":");
}

async function signingKey(): Promise<CryptoKey> {
  const fingerprint = apnsFingerprint();
  if (!cachedSigningKeyPromise || cachedSigningKeyFingerprint !== fingerprint) {
    cachedSigningKeyFingerprint = fingerprint;
    cachedSigningKeyPromise = crypto.subtle.importKey(
      "pkcs8",
      pemToArrayBuffer(apnsPrivateKey()),
      {
        name: "ECDSA",
        namedCurve: "P-256",
      },
      false,
      ["sign"],
    );
  }
  return await cachedSigningKeyPromise;
}

async function providerToken(): Promise<string> {
  const fingerprint = apnsFingerprint();
  if (
    cachedProviderToken.value &&
    cachedProviderToken.keyFingerprint === fingerprint &&
    cachedProviderToken.expiresAt > Date.now() + 60_000
  ) {
    return cachedProviderToken.value;
  }

  const header = base64URLEncode(JSON.stringify({
    alg: "ES256",
    kid: apnsKeyID(),
  }));
  const claims = base64URLEncode(JSON.stringify({
    iss: appleTeamID(),
    iat: Math.floor(Date.now() / 1_000),
  }));
  const signingInput = `${header}.${claims}`;
  const signatureDER = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await signingKey(),
      textEncoder.encode(signingInput),
    ),
  );

  const token = `${signingInput}.${base64URLEncode(signatureToJose(signatureDER))}`;
  cachedProviderToken = {
    value: token,
    expiresAt: Date.now() + 50 * 60_000,
    keyFingerprint: fingerprint,
  };
  return token;
}

function apnsHost(platform: string | null): string {
  return (platform || "").toLowerCase().includes("sandbox")
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";
}

function normalizePayloadValue(value: JSONValue | undefined): JSONValue | undefined {
  if (value === null || value === undefined) {
    return undefined;
  }

  if (Array.isArray(value)) {
    return value
      .map((item) => normalizePayloadValue(item))
      .filter((item) => item !== undefined) as JSONValue[];
  }

  if (typeof value === "object") {
    const normalized: Record<string, JSONValue> = {};
    for (const [key, nestedValue] of Object.entries(value)) {
      const next = normalizePayloadValue(nestedValue as JSONValue);
      if (next !== undefined) {
        normalized[key] = next;
      }
    }
    return normalized;
  }

  return value;
}

function parseAPNSError(payload: JSONValue | string | null): string {
  if (!payload) {
    return "";
  }
  if (typeof payload === "string") {
    return payload;
  }
  if (typeof payload === "object" && !Array.isArray(payload) && payload.reason) {
    return String(payload.reason);
  }
  return JSON.stringify(payload);
}

function normalizeAPNSResponse(response: Response, payload: JSONValue | string | null): APNSResult {
  const reason = parseAPNSError(payload);
  const retryAfterHeader = response.headers.get("retry-after");
  const retryAfterSeconds = retryAfterHeader ? Number.parseInt(retryAfterHeader, 10) : null;

  if (response.ok) {
    return { ok: true };
  }

  const invalidTokenReasons = new Set([
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "Unregistered",
  ]);
  const retryableReasons = new Set([
    "TooManyRequests",
    "InternalServerError",
    "ServiceUnavailable",
    "Shutdown",
  ]);

  return {
    ok: false,
    status: response.status,
    reason,
    invalidToken: invalidTokenReasons.has(reason),
    retryable:
      response.status >= 500 ||
      response.status === 429 ||
      retryableReasons.has(reason),
    retryAfterSeconds: Number.isFinite(retryAfterSeconds) ? retryAfterSeconds : null,
  };
}

async function sendAPNSNotification(
  token: string,
  platform: string | null,
  title: string,
  body: string,
  payload: Record<string, JSONValue> | null,
  threadID: string | null,
  collapseKey: string | null,
): Promise<APNSResult> {
  const aps: Record<string, JSONValue> = {
    alert: { title, body },
    sound: "default",
  };
  const normalizedPayload = normalizePayloadValue(payload || {});

  if (threadID) {
    aps["thread-id"] = threadID;
  }

  const requestPayload = JSON.stringify({
    aps,
    ...((normalizedPayload && typeof normalizedPayload === "object" && !Array.isArray(normalizedPayload))
      ? normalizedPayload
      : {}),
  });

  const response = await fetch(`https://${apnsHost(platform)}/3/device/${encodeURIComponent(token)}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": appBundleID(),
      "apns-push-type": "alert",
      "apns-priority": "10",
      ...(collapseKey ? { "apns-collapse-id": collapseKey } : {}),
    },
    body: requestPayload,
  });

  let payloadBody: JSONValue | string | null = null;
  try {
    payloadBody = await response.json() as JSONValue;
  } catch {
    payloadBody = null;
  }

  return normalizeAPNSResponse(response, payloadBody);
}

async function deliverJob(job: PushJob): Promise<void> {
  const tokens = await activeTokensForUser(job.recipient_user_id);
  const validTokens = tokens.filter((row) => row.token?.trim());

  if (!validTokens.length) {
    await markCanceled(job.id, "No active push tokens.");
    return;
  }

  let sent = false;
  let hasRetryableFailure = false;
  let retryAfterSeconds: number | null = null;
  let lastFailureReason = "";

  for (const tokenRow of validTokens) {
    const result = await sendAPNSNotification(
      tokenRow.token,
      tokenRow.platform,
      job.title,
      job.body,
      job.payload,
      job.thread_id,
      job.collapse_key,
    );

    if (result.ok) {
      sent = true;
      continue;
    }

    lastFailureReason = result.reason || `APNs ${result.status || "error"}`;

    if (result.invalidToken) {
      await removeInvalidToken(tokenRow.token);
      continue;
    }

    if (result.retryable) {
      hasRetryableFailure = true;
      if (Number.isFinite(result.retryAfterSeconds)) {
        retryAfterSeconds = result.retryAfterSeconds ?? null;
      }
    }
  }

  if (sent) {
    await markSent(job.id);
    return;
  }

  const remainingTokens = await activeTokensForUser(job.recipient_user_id);
  const stillHasTokens = remainingTokens.some((row) => row.token?.trim());
  if (!stillHasTokens) {
    await markCanceled(job.id, lastFailureReason || "No valid tokens remain.");
    return;
  }

  if (hasRetryableFailure) {
    await markRetry(job, lastFailureReason, retryAfterSeconds);
    return;
  }

  await markFailed(job.id, lastFailureReason || "Permanent APNs failure.");
}

async function processPushQueue(force: boolean, batchSize: number): Promise<{ processed: number; batches: number }> {
  let processed = 0;
  let batches = 0;
  const rounds = force ? MAX_BATCH_ROUNDS : 2;

  for (let round = 0; round < rounds; round += 1) {
    const jobs = await claimJobs(batchSize);
    if (!jobs.length) {
      break;
    }

    batches += 1;
    for (const job of jobs) {
      try {
        await deliverJob(job);
      } catch (error) {
        console.error("Unexpected push delivery failure", job.id, error);
        await markRetry(
          job,
          error instanceof Error ? error.message : String(error),
          null,
        );
      }
      processed += 1;
    }

    if (jobs.length < batchSize) {
      break;
    }
  }

  return { processed, batches };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse(405, {
      ok: false,
      error: "Method not allowed.",
    });
  }

  let bodyText = "";
  try {
    bodyText = await req.text();
  } catch {
    bodyText = "";
  }

  try {
    if (!authorized(req)) {
      return jsonResponse(401, {
        ok: false,
        error: "Unauthorized.",
      });
    }

    const payload = parseJSON<DispatchRequest>(bodyText) || {};
    const force = payload.force === true;
    const batchSize = Math.max(
      1,
      Math.min(Number(payload.batch_size) || DEFAULT_BATCH_SIZE, MAX_BATCH_SIZE),
    );
    const startedAt = Date.now();
    const result = await processPushQueue(force, batchSize);

    return jsonResponse(200, {
      ok: true,
      reason: payload.reason || "manual",
      force,
      batch_size: batchSize,
      processed: result.processed,
      batches: result.batches,
      duration_ms: Date.now() - startedAt,
    });
  } catch (error) {
    console.error("push-dispatch failed", error);
    return jsonResponse(500, {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      timeout_ms: DEFAULT_FUNCTION_TIMEOUT_MS,
    });
  }
});
