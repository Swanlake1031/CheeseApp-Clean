import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const userID = "11111111-1111-4111-8111-111111111111";
const draftID = "22222222-2222-4222-8222-222222222222";
const boardID = "33333333-3333-4333-8333-333333333333";
const mediaPath = `${userID}/drafts/${draftID}/photo.jpg`;
const mediaSafetyConsentVersion = "2026-09-11-media-v1";
const env = {
  SUPABASE_URL: "https://project.invalid",
  SUPABASE_PUBLISHABLE_KEY: "public-test",
  SUPABASE_SERVICE_ROLE_KEY: "sb_secret_test",
  CONTENT_STUDIO_ORIGIN: "https://studio.cheeseapp.org"
};

function draft() {
  return {
    id: draftID,
    content_type: "forum",
    payload: {
      title: "Safety-reviewed image",
      description: "",
      boardId: boardID,
      media: [{ path: mediaPath, contentType: "image/jpeg", size: 3 }]
    }
  };
}

function publication(body) {
  return new Request("https://studio-api.invalid/v1/publish/forum", {
    method: "POST",
    headers: {
      Authorization: "Bearer synthetic-user-session-token",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body)
  });
}

function draftMediaUpload(file) {
  const form = new FormData();
  form.set("draftId", draftID);
  form.set("file", file, "image.jpg");
  return new Request("https://studio-api.invalid/v1/draft-media", {
    method: "POST",
    headers: {
      Authorization: "Bearer synthetic-user-session-token",
      Origin: "https://studio.cheeseapp.org"
    },
    body: form
  });
}

async function withMockedFetch(handler, action) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    return handler(String(url), options, calls);
  };
  try {
    return await action(calls);
  } finally {
    globalThis.fetch = original;
  }
}

function authenticatedStudioUser(url) {
  if (url.endsWith("/auth/v1/user")) return Response.json({ id: userID });
  if (url.includes("/content_studio_roles?")) return Response.json([{ role: "editor" }]);
  return null;
}

test("Content Studio rejects draft images above the moderation transport budget before storage", { concurrency: false }, async () => {
  const image = new File(
    [new Uint8Array(8 * 1024 * 1024 + 1)],
    "image.jpg",
    { type: "image/jpeg" }
  );
  await withMockedFetch((url) => {
    const response = authenticatedStudioUser(url);
    if (response) return response;
    throw new Error(`draft media must be rejected before storage: ${url}`);
  }, async (calls) => {
    const response = await worker.fetch(draftMediaUpload(image), env);
    const payload = await response.json();
    assert.equal(response.status, 400);
    assert.match(payload.error, /no larger than 8 MB/);
    assert.equal(calls.length, 2);
    assert.equal(calls.some((call) => call.url.includes("/storage/")), false);
  });
});

test("a publication with a new image cannot start the media operation without the separate safety acknowledgement", { concurrency: false }, async () => {
  await withMockedFetch((url) => {
    const response = authenticatedStudioUser(url);
    if (response) return response;
    if (url.includes("/content_studio_drafts?")) return Response.json([draft()]);
    throw new Error(`unexpected request: ${url}`);
  }, async (calls) => {
    const response = await worker.fetch(publication({ draftId: draftID }), env);
    const payload = await response.json();
    assert.equal(response.status, 400);
    assert.match(payload.error, /Confirm image safety review/);
    assert.equal(calls.some((call) => call.url.includes("prepare_post_media_operation")), false);
    assert.equal(calls.some((call) => call.url.startsWith("https://ai.cheeseapp.org/")), false);
  });
});

test("the acknowledged publication forwards only the dedicated media-safety header", { concurrency: false }, async () => {
  await withMockedFetch((url, options) => {
    const response = authenticatedStudioUser(url);
    if (response) return response;
    if (url.includes("/content_studio_drafts?")) {
      return options.method === "DELETE" ? new Response(null, { status: 204 }) : Response.json([draft()]);
    }
    if (url.includes("/rpc/prepare_post_media_operation")) return Response.json(true);
    if (url.includes("/storage/v1/object/content-studio-drafts/")) {
      return options.method === "DELETE"
        ? new Response(null, { status: 200 })
        : new Response(new Uint8Array([255, 216, 255]), { status: 200 });
    }
    if (url.startsWith("https://ai.cheeseapp.org/v1/media/upload")) return Response.json({ ok: true });
    if (url.includes("/rpc/mark_post_media_uploaded")) return Response.json(true);
    if (url.includes("/rpc/publish_forum_post_with_mentions")) return Response.json("44444444-4444-4444-8444-444444444444");
    throw new Error(`unexpected request: ${url}`);
  }, async (calls) => {
    const response = await worker.fetch(publication({ draftId: draftID, mediaSafetyConsentVersion }), env);
    assert.equal(response.status, 201);
    const moderationCall = calls.find((call) => call.url.startsWith("https://ai.cheeseapp.org/v1/media/upload"));
    assert.ok(moderationCall);
    assert.equal(moderationCall.options.headers["X-Cheese-Media-Safety-Consent"], mediaSafetyConsentVersion);
    assert.equal(moderationCall.options.headers["X-Cheese-AI-Consent"], undefined);
  });
});

test("a failed media review abandons the prepared operation", { concurrency: false }, async () => {
  await withMockedFetch((url) => {
    const response = authenticatedStudioUser(url);
    if (response) return response;
    if (url.includes("/content_studio_drafts?")) return Response.json([draft()]);
    if (url.includes("/rpc/prepare_post_media_operation")) return Response.json(true);
    if (url.includes("/storage/v1/object/content-studio-drafts/")) return new Response(new Uint8Array([255, 216, 255]), { status: 200 });
    if (url.startsWith("https://ai.cheeseapp.org/v1/media/upload")) return Response.json({ error: "content_not_allowed" }, { status: 422 });
    if (url.includes("/rpc/abandon_post_media_operation")) return Response.json(true);
    throw new Error(`unexpected request: ${url}`);
  }, async (calls) => {
    const response = await worker.fetch(publication({ draftId: draftID, mediaSafetyConsentVersion }), env);
    assert.equal(response.status, 422);
    assert.equal(calls.some((call) => call.url.includes("abandon_post_media_operation")), true);
  });
});

test("a media-review service outage remains retryable to the editor", { concurrency: false }, async () => {
  await withMockedFetch((url) => {
    const response = authenticatedStudioUser(url);
    if (response) return response;
    if (url.includes("/content_studio_drafts?")) return Response.json([draft()]);
    if (url.includes("/rpc/prepare_post_media_operation")) return Response.json(true);
    if (url.includes("/storage/v1/object/content-studio-drafts/")) return new Response(new Uint8Array([255, 216, 255]), { status: 200 });
    if (url.startsWith("https://ai.cheeseapp.org/v1/media/upload")) return Response.json({ error: "moderation_unavailable" }, { status: 503 });
    if (url.includes("/rpc/abandon_post_media_operation")) return Response.json(true);
    throw new Error(`unexpected request: ${url}`);
  }, async () => {
    const response = await worker.fetch(publication({ draftId: draftID, mediaSafetyConsentVersion }), env);
    const payload = await response.json();
    assert.equal(response.status, 503);
    assert.match(payload.error, /temporarily unavailable/);
  });
});
