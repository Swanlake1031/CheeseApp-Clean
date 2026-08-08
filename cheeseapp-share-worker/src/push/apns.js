const textEncoder = new TextEncoder();

let cachedSigningKeyPromise = null;
let cachedSigningKeyFingerprint = "";
let cachedProviderToken = {
  value: "",
  expiresAt: 0,
  keyFingerprint: ""
};

function base64URLEncode(input) {
  const bytes =
    input instanceof Uint8Array
      ? input
      : input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : textEncoder.encode(String(input));

  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function pemToArrayBuffer(pem) {
  const cleaned = String(pem || "")
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

function derLength(bytes, offset) {
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

function derToJose(signature, size = 32) {
  const bytes = signature instanceof Uint8Array ? signature : new Uint8Array(signature);
  if (bytes[0] !== 0x30) {
    throw new Error("Invalid DER signature.");
  }

  const sequenceLength = derLength(bytes, 1);
  let offset = 1 + sequenceLength.bytesRead;
  if (offset >= bytes.length || bytes[offset] !== 0x02) {
    throw new Error("Invalid DER integer prefix for r.");
  }

  const rLength = derLength(bytes, offset + 1);
  const rStart = offset + 1 + rLength.bytesRead;
  const r = bytes.slice(rStart, rStart + rLength.value);
  offset = rStart + rLength.value;

  if (offset >= bytes.length || bytes[offset] !== 0x02) {
    throw new Error("Invalid DER integer prefix for s.");
  }

  const sLength = derLength(bytes, offset + 1);
  const sStart = offset + 1 + sLength.bytesRead;
  const s = bytes.slice(sStart, sStart + sLength.value);

  const output = new Uint8Array(size * 2);
  output.set(r.slice(-size), size - Math.min(size, r.length));
  output.set(s.slice(-size), size * 2 - Math.min(size, s.length));
  return output;
}

function keyFingerprint(config) {
  return [config.appleTeamID, config.apnsKeyID, config.apnsPrivateKey].join(":");
}

async function signingKey(config) {
  const fingerprint = keyFingerprint(config);
  if (!cachedSigningKeyPromise || cachedSigningKeyFingerprint !== fingerprint) {
    cachedSigningKeyFingerprint = fingerprint;
    cachedSigningKeyPromise = crypto.subtle.importKey(
      "pkcs8",
      pemToArrayBuffer(config.apnsPrivateKey),
      {
        name: "ECDSA",
        namedCurve: "P-256"
      },
      false,
      ["sign"]
    );
  }
  return cachedSigningKeyPromise;
}

async function providerToken(config) {
  const fingerprint = keyFingerprint(config);
  if (
    cachedProviderToken.value &&
    cachedProviderToken.keyFingerprint === fingerprint &&
    cachedProviderToken.expiresAt > Date.now() + 60_000
  ) {
    return cachedProviderToken.value;
  }

  const header = base64URLEncode(JSON.stringify({
    alg: "ES256",
    kid: config.apnsKeyID
  }));
  const claims = base64URLEncode(JSON.stringify({
    iss: config.appleTeamID,
    iat: Math.floor(Date.now() / 1000)
  }));
  const signingInput = `${header}.${claims}`;

  const signatureDER = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(config),
    textEncoder.encode(signingInput)
  );
  const signatureJOSE = base64URLEncode(derToJose(signatureDER));
  const token = `${signingInput}.${signatureJOSE}`;

  cachedProviderToken = {
    value: token,
    expiresAt: Date.now() + 50 * 60_000,
    keyFingerprint: fingerprint
  };
  return token;
}

function apnsHostForPlatform(platform) {
  return String(platform || "").toLowerCase().includes("sandbox")
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";
}

function normalizePayloadValue(value) {
  if (value === null || value === undefined) {
    return undefined;
  }

  if (Array.isArray(value)) {
    return value.map(normalizePayloadValue).filter((item) => item !== undefined);
  }

  if (typeof value === "object") {
    const normalized = {};
    for (const [key, nestedValue] of Object.entries(value)) {
      const next = normalizePayloadValue(nestedValue);
      if (next !== undefined) {
        normalized[key] = next;
      }
    }
    return normalized;
  }

  return value;
}

function parseAPNSError(payload) {
  if (!payload) {
    return "";
  }
  if (typeof payload === "string") {
    return payload;
  }
  return payload.reason || JSON.stringify(payload);
}

function normalizeAPNsResponse(response, payload) {
  const reason = parseAPNSError(payload);
  const retryAfterHeader = response.headers.get("retry-after");
  const retryAfterSeconds = retryAfterHeader ? Number.parseInt(retryAfterHeader, 10) : null;

  if (response.ok) {
    return {
      ok: true
    };
  }

  const invalidTokenReasons = new Set([
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "Unregistered"
  ]);
  const retryableReasons = new Set([
    "TooManyRequests",
    "InternalServerError",
    "ServiceUnavailable",
    "Shutdown"
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
    retryAfterSeconds: Number.isFinite(retryAfterSeconds) ? retryAfterSeconds : null
  };
}

export function hasAPNsConfig(config) {
  return Boolean(
    config.apnsPrivateKey &&
    config.apnsKeyID &&
    config.appleTeamID &&
    config.apnsTopic
  );
}

export async function sendAPNSNotification({
  config,
  token,
  platform,
  title,
  body,
  payload = {},
  threadID,
  collapseKey
}) {
  const aps = {
    alert: {
      title,
      body
    },
    sound: "default"
  };

  if (threadID) {
    aps["thread-id"] = threadID;
  }

  const requestPayload = JSON.stringify({
    aps,
    ...normalizePayloadValue(payload)
  });

  const response = await fetch(
    `https://${apnsHostForPlatform(platform)}/3/device/${encodeURIComponent(token)}`,
    {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(config)}`,
        "apns-topic": config.apnsTopic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        ...(collapseKey ? { "apns-collapse-id": collapseKey } : {})
      },
      body: requestPayload
    }
  );

  let payloadBody = null;
  try {
    payloadBody = await response.json();
  } catch {
    payloadBody = null;
  }

  return normalizeAPNsResponse(response, payloadBody);
}
