const DEFAULT_BATCH_LIMIT = 50;

export async function processSecondhandLifecycle({
  config,
  fetchImpl = fetch,
  batchLimit = DEFAULT_BATCH_LIMIT
}) {
  const serviceRoleKey = normalize(config.supabaseServiceRoleKey);
  if (!serviceRoleKey) {
    return { skipped: "missing_service_role", remindersCreated: 0, listingsHidden: 0 };
  }

  const limit = Math.min(
    Math.max(Number(batchLimit) || DEFAULT_BATCH_LIMIT, 1),
    100
  );
  const endpoint =
    `${trimTrailingSlash(config.supabaseURL)}` +
    "/rest/v1/rpc/process_secondhand_availability_lifecycle";
  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: serviceHeaders(serviceRoleKey),
    body: JSON.stringify({ p_limit: limit })
  });

  if (!response.ok) {
    const error = new Error(`Secondhand lifecycle RPC failed with ${response.status}`);
    error.code = `secondhand_lifecycle_http_${response.status}`;
    throw error;
  }

  const text = await response.text();
  const payload = text ? JSON.parse(text) : [];
  const summary = Array.isArray(payload) ? payload[0] || {} : payload || {};
  return {
    skipped: null,
    remindersCreated: finiteCount(summary.reminders_created),
    listingsHidden: finiteCount(summary.listings_hidden)
  };
}

function finiteCount(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

function serviceHeaders(serviceRoleKey) {
  return {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    "content-type": "application/json"
  };
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function normalize(value) {
  return typeof value === "string" ? value.trim() : "";
}
