const DEFAULT_BATCH_LIMIT = 20;

const CLEANUP_KINDS = [
  {
    name: "post",
    claimRPC: "claim_post_media_cleanup_batch",
    completeRPC: "complete_post_media_cleanup_job"
  },
  {
    name: "chat",
    claimRPC: "claim_chat_media_cleanup_batch",
    completeRPC: "complete_chat_media_cleanup_job"
  }
];

export async function processMediaCleanup({
  config,
  fetchImpl = fetch,
  batchLimit = DEFAULT_BATCH_LIMIT
}) {
  const serviceRoleKey = normalize(config.supabaseServiceRoleKey);
  if (!serviceRoleKey) {
    return { skipped: "missing_service_role", kinds: [], metrics: null };
  }

  const limit = Math.min(Math.max(Number(batchLimit) || DEFAULT_BATCH_LIMIT, 1), 50);
  const kinds = [];
  for (const kind of CLEANUP_KINDS) {
    kinds.push(
      await processCleanupKind({
        config,
        serviceRoleKey,
        fetchImpl,
        limit,
        kind
      })
    );
  }

  const metricsRows = await callRPC({
    config,
    serviceRoleKey,
    fetchImpl,
    name: "get_media_cleanup_backlog_metrics",
    body: {}
  });

  return {
    skipped: null,
    kinds,
    metrics: Array.isArray(metricsRows) ? metricsRows[0] || null : metricsRows
  };
}

async function processCleanupKind({
  config,
  serviceRoleKey,
  fetchImpl,
  limit,
  kind
}) {
  const lockToken = crypto.randomUUID();
  const jobs = await callRPC({
    config,
    serviceRoleKey,
    fetchImpl,
    name: kind.claimRPC,
    body: { p_limit: limit, p_lock_token: lockToken }
  });

  const result = {
    kind: kind.name,
    claimed: Array.isArray(jobs) ? jobs.length : 0,
    succeeded: 0,
    failed: 0
  };

  for (const job of Array.isArray(jobs) ? jobs : []) {
    let succeeded = false;
    let errorCode = null;
    try {
      validateClaim(job, kind.name);
      await deleteStorageObject({
        config,
        serviceRoleKey,
        fetchImpl,
        bucket: job.bucket,
        objectPath: job.object_path
      });
      succeeded = true;
      result.succeeded += 1;
    } catch (error) {
      errorCode = safeErrorCode(error);
      result.failed += 1;
    }

    await callRPC({
      config,
      serviceRoleKey,
      fetchImpl,
      name: kind.completeRPC,
      body: {
        p_cleanup_id: job.cleanup_id,
        p_lock_token: lockToken,
        p_succeeded: succeeded,
        p_error_code: errorCode
      }
    });
  }

  return result;
}

async function deleteStorageObject({
  config,
  serviceRoleKey,
  fetchImpl,
  bucket,
  objectPath
}) {
  const endpoint = `${trimTrailingSlash(config.supabaseURL)}/storage/v1/object/${encodeURIComponent(bucket)}`;
  const response = await fetchImpl(endpoint, {
    method: "DELETE",
    headers: serviceHeaders(serviceRoleKey),
    body: JSON.stringify({ prefixes: [objectPath] })
  });

  // Deletion is idempotent: an already-absent object satisfies the obligation.
  if (response.ok || response.status === 404) {
    return;
  }

  const error = new Error(`Storage delete failed with ${response.status}`);
  error.code = `storage_http_${response.status}`;
  throw error;
}

async function callRPC({
  config,
  serviceRoleKey,
  fetchImpl,
  name,
  body
}) {
  const endpoint = `${trimTrailingSlash(config.supabaseURL)}/rest/v1/rpc/${name}`;
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: serviceHeaders(serviceRoleKey),
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    const error = new Error(`Cleanup RPC failed with ${response.status}`);
    error.code = `rpc_http_${response.status}`;
    throw error;
  }

  if (response.status === 204) {
    return null;
  }
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function validateClaim(job, kind) {
  const expectedBucket = kind === "chat" ? "chat-images" : "post-images";
  if (
    !job ||
    typeof job.cleanup_id !== "string" ||
    job.bucket !== expectedBucket ||
    typeof job.object_path !== "string" ||
    !job.object_path
  ) {
    const error = new Error("Invalid cleanup claim");
    error.code = "invalid_cleanup_claim";
    throw error;
  }
}

function serviceHeaders(serviceRoleKey) {
  return {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    "content-type": "application/json"
  };
}

export function safeErrorCode(error) {
  const raw = normalize(error && error.code) || normalize(error && error.name) || "cleanup_failed";
  const safe = raw.replace(/[^A-Za-z0-9_.:-]/g, "_").slice(0, 120);
  return safe || "cleanup_failed";
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function normalize(value) {
  return typeof value === "string" ? value.trim() : "";
}
