const DRAFT_BUCKET = "content-studio-drafts";
const POST_BUCKET = "post-images";
const MAX_IMAGES = 6;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

const SECONDHAND_CATEGORIES = new Set([
  "home_appliances",
  "daily_essentials",
  "fashion_accessories",
  "beauty_care",
  "sports_outdoors",
  "digital_electronics",
  "books_academic",
  "pet_supplies",
  "other"
]);
const SECONDHAND_CONDITIONS = new Set(["new", "like_new", "good", "fair", "poor"]);

export default {
  async fetch(request, env) {
    const origin = request.headers.get("Origin");
    if (request.method === "OPTIONS") return empty(204, cors(origin, env));
    if (!isAllowedOrigin(origin, env)) return problem(403, "Origin is not allowed", origin, env);

    try {
      const url = new URL(request.url);
      if (url.pathname === "/health") return json({ ok: true }, 200, origin, env);

      const context = await requireStudioUser(request, env);
      const response = await route(request, url, env, context);
      return withCors(response, origin, env);
    } catch (error) {
      return problem(error.status || 500, safeMessage(error), origin, env);
    }
  }
};

async function route(request, url, env, context) {
  const { pathname } = url;

  if (request.method === "GET" && pathname === "/v1/bootstrap") {
    const boards = await userRest(
      env,
      context.token,
      "/forum_boards_view?select=id,slug,name,description,icon,allows_anonymous_posts,status&status=eq.active&order=name.asc"
    );
    return json({
      viewer: { id: context.user.id, email: context.user.email || "", role: context.role },
      boards,
      secondhandCategories: [...SECONDHAND_CATEGORIES],
      secondhandConditions: [...SECONDHAND_CONDITIONS]
    });
  }

  if (pathname === "/v1/drafts") {
    if (request.method === "GET") return listDrafts(env, context);
    if (request.method === "POST") return createDraft(request, env, context);
  }

  const draftMatch = pathname.match(/^\/v1\/drafts\/([0-9a-f-]{36})$/i);
  if (draftMatch) {
    if (request.method === "PATCH") return updateDraft(request, env, context, draftMatch[1]);
    if (request.method === "DELETE") return deleteDraft(env, context, draftMatch[1]);
  }

  if (request.method === "POST" && pathname === "/v1/draft-media") {
    return uploadDraftMedia(request, env, context);
  }
  if (request.method === "GET" && pathname === "/v1/draft-media") {
    return readDraftMedia(url, env, context);
  }

  if (request.method === "GET" && pathname === "/v1/posts") {
    return listPosts(url, env, context);
  }

  const publishMatch = pathname.match(/^\/v1\/publish\/(forum|secondhand)$/);
  if (publishMatch && request.method === "POST") {
    return publishPost(request, env, context, publishMatch[1]);
  }

  const postMatch = pathname.match(/^\/v1\/posts\/(forum|secondhand)\/([0-9a-f-]{36})\/(hide|delete)$/i);
  if (postMatch && request.method === "POST") {
    return managePost(request, env, context, postMatch[1], postMatch[2], postMatch[3]);
  }

  const editMatch = pathname.match(/^\/v1\/posts\/(forum|secondhand)\/([0-9a-f-]{36})$/i);
  if (editMatch && request.method === "PATCH") {
    return editPost(request, env, context, editMatch[1], editMatch[2]);
  }

  throw httpError(404, "Unknown Content Studio route");
}

async function requireStudioUser(request, env) {
  const token = bearerToken(request);
  const config = readConfig(env);
  const userResponse = await fetch(`${config.url}/auth/v1/user`, {
    headers: { apikey: config.publishableKey, Authorization: `Bearer ${token}` }
  });
  if (!userResponse.ok) {
    const detail = (await userResponse.text()).slice(0, 240);
    console.log(JSON.stringify({ event: "content_studio_session_validation_failed", status: userResponse.status, detail }));
    throw httpError(401, "CMS session validation failed");
  }
  const user = await userResponse.json();
  if (!user?.id) throw httpError(401, "Invalid session");

  const encodedUserID = encodeURIComponent(`eq.${user.id}`);
  const rows = await serviceRest(
    env,
    `/content_studio_roles?select=role&user_id=${encodedUserID}&limit=1`
  );
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw httpError(403, "This account is not authorized for Content Studio");
  }
  return { token, user, role: rows[0].role };
}

async function listDrafts(env, context) {
  const rows = await serviceRest(
    env,
    `/content_studio_drafts?select=*&user_id=eq.${encodeURIComponent(context.user.id)}&order=updated_at.desc`
  );
  return json({ drafts: rows });
}

async function createDraft(request, env, context) {
  const body = await readJSON(request);
  const contentType = validContentType(body.contentType);
  const draft = {
    id: crypto.randomUUID(),
    user_id: context.user.id,
    content_type: contentType,
    title: text(body.title),
    payload: normaliseDraftPayload(body.payload, contentType)
  };
  const rows = await serviceRest(env, "/content_studio_drafts", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(draft)
  });
  return json({ draft: rows[0] }, 201);
}

async function updateDraft(request, env, context, draftID) {
  const body = await readJSON(request);
  const existing = await ownedDraft(env, context, draftID);
  const contentType = validContentType(body.contentType || existing.content_type);
  const patch = {
    title: text(body.title ?? existing.title),
    content_type: contentType,
    payload: normaliseDraftPayload(body.payload ?? existing.payload, contentType)
  };
  const rows = await serviceRest(
    env,
    `/content_studio_drafts?id=eq.${draftID}&user_id=eq.${context.user.id}`,
    { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) }
  );
  return json({ draft: rows[0] });
}

async function deleteDraft(env, context, draftID) {
  const draft = await ownedDraft(env, context, draftID);
  await deleteDraftObjects(env, draft.payload?.media || []);
  await serviceRest(
    env,
    `/content_studio_drafts?id=eq.${draftID}&user_id=eq.${context.user.id}`,
    { method: "DELETE" }
  );
  return empty(204);
}

async function uploadDraftMedia(request, env, context) {
  const form = await request.formData();
  const draftID = text(form.get("draftId"));
  const file = form.get("file");
  if (!isUUID(draftID)) throw httpError(400, "A valid draft is required");
  if (!(file instanceof File)) throw httpError(400, "Choose an image to upload");
  if (file.type !== "image/jpeg" || file.size === 0 || file.size > MAX_IMAGE_BYTES) {
    throw httpError(400, "Images must be JPEG files no larger than 10 MB");
  }
  const draft = await ownedDraft(env, context, draftID);
  const existingMedia = Array.isArray(draft.payload?.media) ? draft.payload.media : [];
  if (existingMedia.length >= MAX_IMAGES) throw httpError(400, "A post can contain at most six images");

  const objectPath = `${context.user.id}/drafts/${draftID}/${crypto.randomUUID()}.jpg`;
  await serviceStorage(env, "PUT", DRAFT_BUCKET, objectPath, file.stream(), "image/jpeg");
  const media = { path: objectPath, contentType: "image/jpeg", size: file.size };
  return json({ media }, 201);
}

async function readDraftMedia(url, env, context) {
  const draftID = text(url.searchParams.get("draftId"));
  const path = text(url.searchParams.get("path"));
  if (!isUUID(draftID) || !path.startsWith(`${context.user.id}/drafts/${draftID}/`)) {
    throw httpError(400, "Invalid draft media path");
  }
  const draft = await ownedDraft(env, context, draftID);
  if (!Array.isArray(draft.payload?.media) || !draft.payload.media.some((item) => item?.path === path)) {
    throw httpError(404, "Draft media not found");
  }
  const response = await serviceStorage(env, "GET", DRAFT_BUCKET, path);
  return new Response(response.body, {
    headers: { "Content-Type": response.headers.get("Content-Type") || "image/jpeg", "Cache-Control": "private, max-age=300" }
  });
}

async function listPosts(url, env, context) {
  const kind = validContentType(url.searchParams.get("kind") || "forum");
  const view = kind === "forum" ? "forum_posts_view" : "secondhand_posts_view";
  const fields = kind === "forum"
    ? "id,title,description,board_id,board_name,board_icon,is_anonymous,created_at,updated_at,images"
    : "id,title,description,price,original_price,category,condition,is_negotiable,is_anonymous,created_at,updated_at,images";
  const rows = await userRest(
    env,
    context.token,
    `/${view}?select=${encodeURIComponent(fields)}&user_id=eq.${context.user.id}&order=created_at.desc&limit=50`
  );
  const privateRows = await serviceRest(
    env,
    `/posts?select=id,is_private&user_id=eq.${context.user.id}&type=eq.${kind}`
  );
  const privateByID = new Map(privateRows.map((post) => [post.id, Boolean(post.is_private)]));
  const postIDs = rows.map((post) => post.id);
  const images = postIDs.length
    ? await serviceRest(
        env,
        `/post_images?select=id,post_id,url,order_index&post_id=in.(${postIDs.join(",")})&order=order_index.asc`
      )
    : [];
  const imagesByPostID = new Map();
  for (const image of images) {
    const list = imagesByPostID.get(image.post_id) || [];
    list.push(image);
    imagesByPostID.set(image.post_id, list);
  }
  return json({
    posts: rows.map((post) => ({
      ...post,
      is_private: privateByID.get(post.id) || false,
      images: imagesByPostID.get(post.id) || []
    }))
  });
}

async function publishPost(request, env, context, kind) {
  const body = await readJSON(request);
  const draft = body.draftId ? await ownedDraft(env, context, text(body.draftId)) : null;
  const payload = normaliseDraftPayload(body.payload ?? draft?.payload, kind);
  validatePublishPayload(payload, kind);
  const draftMedia = payload.media || [];
  const postID = crypto.randomUUID();
  const operationID = crypto.randomUUID();

  await prepareAndUploadMedia({ env, context, kind, postID, operationID, draftMedia });
  try {
    const rpc = kind === "forum"
      ? "publish_forum_post_with_mentions"
      : "publish_secondhand_post_with_mentions";
    const params = kind === "forum"
      ? {
          p_post_id: postID, p_operation_id: operationID, p_board_id: payload.boardId,
          p_title: payload.title, p_description: payload.description,
          p_is_anonymous: Boolean(payload.isAnonymous), p_is_private: false,
          p_allow_comments: true, p_mentioned_user_ids: []
        }
      : {
          p_post_id: postID, p_operation_id: operationID,
          p_title: payload.title, p_description: payload.description,
          p_is_anonymous: Boolean(payload.isAnonymous), p_is_private: false,
          p_price: payload.price, p_original_price: payload.originalPrice ?? null,
          p_category: payload.category, p_condition: payload.condition,
          p_is_negotiable: Boolean(payload.isNegotiable), p_mentioned_user_ids: []
        };
    const publishedID = await userRPC(env, context.token, rpc, params);
    if (draft) await deleteDraft(env, context, draft.id);
    return json({ id: typeof publishedID === "string" ? publishedID : postID }, 201);
  } catch (error) {
    await abandonMediaOperation(env, context.token, operationID);
    throw error;
  }
}

async function managePost(request, env, context, kind, postID, action) {
  if (action === "hide") {
    const body = await readJSON(request);
    await userRPC(env, context.token, "set_my_post_hidden", {
      p_post_id: postID,
      p_hidden: Boolean(body.hidden)
    });
    return json({ ok: true, hidden: Boolean(body.hidden) });
  }
  const rpc = kind === "forum" ? "delete_forum_post_with_media" : "delete_secondhand_post_with_media";
  await userRPC(env, context.token, rpc, { p_post_id: postID });
  return empty(204);
}

async function editPost(request, env, context, kind, postID) {
  const body = await readJSON(request);
  const existingPost = await ownedPost(env, context, postID, kind);
  const payload = normaliseDraftPayload(body.payload, kind);
  validatePublishPayload(payload, kind);

  const allImageRows = await serviceRest(
    env,
    `/post_images?select=id,order_index&post_id=eq.${postID}&order=order_index.asc`
  );
  const validImageIDs = new Set(allImageRows.map((image) => image.id));
  const keepImageIDs = Array.isArray(body.keepImageIds)
    ? body.keepImageIds.filter((id) => validImageIDs.has(id))
    : [...validImageIDs];
  if (keepImageIDs.length + payload.media.length > MAX_IMAGES) {
    throw httpError(400, "A post can contain at most six images");
  }
  if (kind === "secondhand" && keepImageIDs.length + payload.media.length < 1) {
    throw httpError(400, "Secondhand listings need at least one image");
  }

  const operationID = crypto.randomUUID();
  const isPrivate = typeof body.isPrivate === "boolean" ? body.isPrivate : Boolean(existingPost.is_private);
  await prepareAndUploadMedia({ env, context, kind, postID, operationID, draftMedia: payload.media });
  try {
    if (kind === "forum") {
      await userRPC(env, context.token, "update_forum_post_with_media", {
        p_post_id: postID, p_operation_id: operationID, p_board_id: payload.boardId,
        p_title: payload.title, p_description: payload.description,
        p_is_anonymous: Boolean(payload.isAnonymous), p_is_private: isPrivate,
        p_allow_comments: true, p_keep_image_ids: keepImageIDs
      });
    } else {
      await userRPC(env, context.token, "update_secondhand_post_with_media", {
        p_post_id: postID, p_operation_id: operationID,
        p_title: payload.title, p_description: payload.description,
        p_is_private: isPrivate, p_price: payload.price,
        p_original_price: payload.originalPrice ?? null, p_category: payload.category,
        p_condition: payload.condition, p_is_negotiable: Boolean(payload.isNegotiable),
        p_keep_image_ids: keepImageIDs
      });
    }
    return json({ ok: true });
  } catch (error) {
    await abandonMediaOperation(env, context.token, operationID);
    throw error;
  }
}

async function prepareAndUploadMedia({ env, context, kind, postID, operationID, draftMedia }) {
  if (draftMedia.length > MAX_IMAGES) throw httpError(400, "A post can contain at most six images");
  const plans = draftMedia.map((media, orderIndex) => {
    const sourcePath = text(media.path);
    if (!sourcePath.startsWith(`${context.user.id}/drafts/`)) {
      throw httpError(400, "Draft media does not belong to this account");
    }
    const objectPath = `${context.user.id}/posts/${postID}/${operationID}/${String(orderIndex).padStart(3, "0")}.jpg`;
    return {
      bucket: POST_BUCKET,
      object_path: objectPath,
      url: `${readConfig(env).url}/storage/v1/object/public/${POST_BUCKET}/${objectPath}`,
      order_index: orderIndex,
      sourcePath
    };
  });
  await userRPC(env, context.token, "prepare_post_media_operation", {
    p_operation_id: operationID,
    p_post_id: postID,
    p_post_type: kind,
    p_media: plans.map(({ sourcePath, ...plan }) => plan)
  });

  for (const plan of plans) {
    const source = await serviceStorage(env, "GET", DRAFT_BUCKET, plan.sourcePath);
    if (!source.ok || !source.body) throw httpError(409, "A draft image could not be read");
    await userStorage(env, context.token, "PUT", POST_BUCKET, plan.object_path, source.body, "image/jpeg");
    await userRPC(env, context.token, "mark_post_media_uploaded", {
      p_operation_id: operationID,
      p_order_index: plan.order_index
    });
  }
}

async function abandonMediaOperation(env, token, operationID) {
  try {
    await userRPC(env, token, "abandon_post_media_operation", {
      p_operation_id: operationID,
      p_reason: "content_studio_publication_failed"
    });
  } catch {
    // The existing cleanup backlog handles any object that cannot be removed now.
  }
}

async function ownedDraft(env, context, draftID) {
  const rows = await serviceRest(
    env,
    `/content_studio_drafts?select=*&id=eq.${draftID}&user_id=eq.${context.user.id}&limit=1`
  );
  if (!rows[0]) throw httpError(404, "Draft not found");
  return rows[0];
}

async function ownedPost(env, context, postID, kind) {
  const rows = await serviceRest(
    env,
    `/posts?select=id,type,is_private&user_id=eq.${context.user.id}&id=eq.${postID}&type=eq.${kind}&limit=1`
  );
  if (!rows[0]) throw httpError(404, "Post not found");
  return rows[0];
}

async function deleteDraftObjects(env, media) {
  for (const item of media) {
    const path = text(item?.path);
    if (path) await serviceStorage(env, "DELETE", DRAFT_BUCKET, path);
  }
}

async function serviceRest(env, path, init = {}) {
  const config = readConfig(env);
  return supabaseJSON(`${config.url}/rest/v1${path}`, {
    ...init,
    headers: {
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
      "Content-Type": "application/json",
      ...(init.headers || {})
    }
  });
}

async function userRest(env, token, path, init = {}) {
  const config = readConfig(env);
  return supabaseJSON(`${config.url}/rest/v1${path}`, {
    ...init,
    headers: {
      apikey: config.publishableKey,
      Authorization: `Bearer ${token}`,
      ...(init.headers || {})
    }
  });
}

async function userRPC(env, token, name, params) {
  return userRest(env, token, `/rpc/${name}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(params)
  });
}

async function serviceStorage(env, method, bucket, path, body, contentType) {
  return storageRequest(env, method, bucket, path, body, contentType, readConfig(env).serviceRoleKey, true);
}

async function userStorage(env, token, method, bucket, path, body, contentType) {
  return storageRequest(env, method, bucket, path, body, contentType, token, false);
}

async function storageRequest(env, method, bucket, path, body, contentType, token, serviceRole) {
  const config = readConfig(env);
  const response = await fetch(`${config.url}/storage/v1/object/${encodeURIComponent(bucket)}/${encodePath(path)}`, {
    method,
    headers: {
      apikey: serviceRole ? config.serviceRoleKey : config.publishableKey,
      Authorization: `Bearer ${token}`,
      ...(contentType ? { "Content-Type": contentType } : {}),
      ...(method === "PUT" ? { "x-upsert": "true" } : {})
    },
    body
  });
  if (!response.ok) throw await asSupabaseError(response);
  return response;
}

async function supabaseJSON(url, init) {
  const response = await fetch(url, init);
  if (!response.ok) throw await asSupabaseError(response);
  if (response.status === 204) return null;
  const raw = await response.text();
  return raw ? JSON.parse(raw) : null;
}

async function asSupabaseError(response) {
  const fallback = response.status === 401 || response.status === 403 ? "Request was not authorized" : "Supabase request failed";
  try {
    const payload = await response.json();
    return httpError(response.status, payload.message || payload.error || fallback);
  } catch {
    return httpError(response.status, fallback);
  }
}

function normaliseDraftPayload(payload, contentType) {
  const source = payload && typeof payload === "object" && !Array.isArray(payload) ? payload : {};
  const media = Array.isArray(source.media)
    ? source.media.slice(0, MAX_IMAGES).map((item) => ({
        path: text(item?.path), contentType: "image/jpeg", size: Number(item?.size) || 0
      })).filter((item) => item.path)
    : [];
  const base = {
    title: text(source.title),
    description: text(source.description),
    isAnonymous: Boolean(source.isAnonymous),
    media
  };
  return contentType === "forum"
    ? { ...base, boardId: text(source.boardId) }
    : {
        ...base,
        price: finiteNumber(source.price),
        originalPrice: source.originalPrice === null || source.originalPrice === "" ? null : finiteNumber(source.originalPrice),
        category: text(source.category),
        condition: text(source.condition),
        isNegotiable: Boolean(source.isNegotiable)
      };
}

function validatePublishPayload(payload, kind) {
  if (!payload.title) throw httpError(400, "Title is required");
  if (kind === "forum") {
    if (!isUUID(payload.boardId)) throw httpError(400, "Choose a forum board");
    return;
  }
  if (!Number.isFinite(payload.price) || payload.price < 0) throw httpError(400, "Enter a valid selling price");
  if (payload.originalPrice !== null && (!Number.isFinite(payload.originalPrice) || payload.originalPrice < payload.price)) {
    throw httpError(400, "Original price cannot be below selling price");
  }
  if (!SECONDHAND_CATEGORIES.has(payload.category) || !SECONDHAND_CONDITIONS.has(payload.condition)) {
    throw httpError(400, "Choose a valid category and condition");
  }
  if (!payload.media?.length) throw httpError(400, "Secondhand listings need at least one image");
}

function validContentType(value) {
  if (value !== "forum" && value !== "secondhand") throw httpError(400, "Unsupported content type");
  return value;
}

function readConfig(env) {
  const url = text(env.SUPABASE_URL).replace(/\/$/, "");
  const publishableKey = text(env.SUPABASE_PUBLISHABLE_KEY);
  const serviceRoleKey = text(env.SUPABASE_SERVICE_ROLE_KEY);
  if (!url || !publishableKey || !serviceRoleKey) throw httpError(500, "Content Studio API is not configured");
  return { url, publishableKey, serviceRoleKey };
}

function bearerToken(request) {
  const value = request.headers.get("Authorization") || "";
  if (!value.startsWith("Bearer ") || value.length < 20) {
    throw httpError(401, "CMS API did not receive a valid session token");
  }
  return value.slice(7);
}

function encodePath(path) {
  return path.split("/").map(encodeURIComponent).join("/");
}

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function finiteNumber(value) {
  if (value === "" || value === null || value === undefined) return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

function isUUID(value) {
  // Forum boards include legacy fixed UUIDs whose version segment is `0`.
  // They are valid database UUID values even though they are not RFC v1–v5
  // generated identifiers, so validate the canonical UUID shape here.
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function isAllowedOrigin(origin, env) {
  if (!origin) return true;
  const configured = text(env.CONTENT_STUDIO_ORIGIN);
  return origin === configured || (configured.startsWith("http://localhost") && origin.startsWith("http://localhost"));
}

function cors(origin, env) {
  const allowed = origin && isAllowedOrigin(origin, env) ? origin : text(env.CONTENT_STUDIO_ORIGIN);
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin"
  };
}

function withCors(response, origin, env) {
  const headers = new Headers(response.headers);
  Object.entries(cors(origin, env)).forEach(([key, value]) => headers.set(key, value));
  return new Response(response.body, { status: response.status, headers });
}

function json(value, status = 200, origin, env) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...(origin ? cors(origin, env) : {}) }
  });
}

function empty(status = 204, headers = {}) {
  return new Response(null, { status, headers });
}

function problem(status, message, origin, env) {
  return json({ error: message }, status, origin, env);
}

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function safeMessage(error) {
  if (error?.status && error.status < 500) return error.message;
  console.error("Content Studio API failure", error);
  return "The request could not be completed";
}

async function readJSON(request) {
  try {
    return await request.json();
  } catch {
    throw httpError(400, "A JSON request body is required");
  }
}
