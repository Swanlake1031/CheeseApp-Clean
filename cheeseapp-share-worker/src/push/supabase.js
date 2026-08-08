function buildAuthHeaders(config) {
  if (!config.supabaseAuthKey) {
    throw new Error("Missing Supabase service-role key for push processing.");
  }

  return {
    Authorization: `Bearer ${config.supabaseAuthKey}`,
    apikey: config.supabaseAuthKey
  };
}

function buildRESTURL(config, path) {
  return `${config.supabaseURL}/rest/v1/${path.replace(/^\/+/, "")}`;
}

function buildRPCURL(config, fn) {
  return `${config.supabaseURL}/rest/v1/rpc/${fn}`;
}

async function parseResponse(response) {
  const text = await response.text();
  if (!text) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function encodeQuery(query = {}) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === "") {
      continue;
    }
    params.set(key, String(value));
  }
  return params.toString();
}

export async function callSupabaseRPC({ config, fn, body = {} }) {
  const response = await fetch(buildRPCURL(config, fn), {
    method: "POST",
    headers: {
      ...buildAuthHeaders(config),
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body)
  });

  const payload = await parseResponse(response);
  if (!response.ok) {
    throw new Error(
      `Supabase RPC ${fn} failed (${response.status}): ${typeof payload === "string" ? payload : JSON.stringify(payload)}`
    );
  }

  return payload;
}

export async function selectRows({ config, table, query = {} }) {
  const qs = encodeQuery(query);
  const url = `${buildRESTURL(config, table)}${qs ? `?${qs}` : ""}`;
  const response = await fetch(url, {
    headers: {
      ...buildAuthHeaders(config),
      Accept: "application/json"
    }
  });

  const payload = await parseResponse(response);
  if (!response.ok) {
    throw new Error(
      `Supabase select ${table} failed (${response.status}): ${typeof payload === "string" ? payload : JSON.stringify(payload)}`
    );
  }

  return Array.isArray(payload) ? payload : [];
}

export async function patchRows({ config, table, query = {}, patch }) {
  const qs = encodeQuery(query);
  const url = `${buildRESTURL(config, table)}${qs ? `?${qs}` : ""}`;
  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      ...buildAuthHeaders(config),
      "Content-Type": "application/json",
      Prefer: "return=minimal"
    },
    body: JSON.stringify(patch)
  });

  if (!response.ok) {
    const payload = await parseResponse(response);
    throw new Error(
      `Supabase patch ${table} failed (${response.status}): ${typeof payload === "string" ? payload : JSON.stringify(payload)}`
    );
  }
}

export async function deleteRows({ config, table, query = {} }) {
  const qs = encodeQuery(query);
  const url = `${buildRESTURL(config, table)}${qs ? `?${qs}` : ""}`;
  const response = await fetch(url, {
    method: "DELETE",
    headers: {
      ...buildAuthHeaders(config),
      Prefer: "return=minimal"
    }
  });

  if (!response.ok) {
    const payload = await parseResponse(response);
    throw new Error(
      `Supabase delete ${table} failed (${response.status}): ${typeof payload === "string" ? payload : JSON.stringify(payload)}`
    );
  }
}
