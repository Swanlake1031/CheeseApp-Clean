const config = window.CHEESE_CONTENT_STUDIO_CONFIG || {};
const SESSION_KEY = "cheese-content-studio-session-v1";
const OAUTH_PKCE_VERIFIER_KEY = "cheese-content-studio-google-pkce-verifier-v1";
const state = {
  session: readSession(),
  bootstrap: null,
  kind: "forum",
  draftId: null,
  existingMedia: [],
  remoteMedia: [],
  selectedMedia: [],
  editing: null,
  publishedKind: "forum"
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

boot();

async function boot() {
  bindEvents();
  if (!configured()) {
    showLoginError("请先在 config.js 填入 Supabase URL、publishable key 和 API 地址。");
    return;
  }
  const oauthError = await consumeOAuthCallback();
  if (oauthError) showLoginError(oauthError);
  if (state.session?.access_token) {
    try {
      await enterStudio();
    } catch (error) {
      clearSession();
      showLoginError(error.message || "登录后无法打开 Content Studio，请重试。");
    }
  }
}

function bindEvents() {
  $("#login-form").addEventListener("submit", signIn);
  $("#google-login").addEventListener("click", signInWithGoogle);
  $("#logout-button").addEventListener("click", () => { clearSession(); location.reload(); });
  $("#top-create").addEventListener("click", () => startCreate());
  $("#editor-form").addEventListener("submit", publish);
  $("#save-draft").addEventListener("click", () => saveDraft(false));
  $("#media-input").addEventListener("change", chooseImages);
  $$("#editor-form input, #editor-form select, #editor-form textarea").forEach((element) => {
    element.addEventListener("input", renderPreview);
    element.addEventListener("change", renderPreview);
  });

  $$(".nav-item").forEach((button) => button.addEventListener("click", () => goTo(button.dataset.screen)));
  $$('[data-go="create"]').forEach((button) => button.addEventListener("click", startCreate));
  $$('[data-refresh="drafts"]').forEach((button) => button.addEventListener("click", loadDrafts));
  $$(".type-tab").forEach((button) => button.addEventListener("click", () => setKind(button.dataset.kind)));
  $$(".segment").forEach((button) => button.addEventListener("click", () => {
    state.publishedKind = button.dataset.postKind;
    $$(".segment").forEach((item) => item.classList.toggle("active", item === button));
    loadPublished();
  }));
}

async function consumeOAuthCallback() {
  const callbackURL = new URL(window.location.href);
  const code = callbackURL.searchParams.get("code");
  if (code) {
    const verifier = sessionStorage.getItem(OAUTH_PKCE_VERIFIER_KEY);
    if (!verifier) {
      clearOAuthCallbackURL();
      return "Google 登录未完成，请返回 CMS 后重试。";
    }

    try {
      const response = await fetch(`${stripSlash(config.supabaseUrl)}/auth/v1/token?grant_type=pkce`, {
        method: "POST",
        headers: { apikey: config.supabasePublishableKey, "Content-Type": "application/json" },
        body: JSON.stringify({ auth_code: code, code_verifier: verifier })
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error_description || payload.msg || "Google 登录失败");
      const session = payload.session || payload;
      if (!session?.access_token) throw new Error("Google 登录未返回有效会话，请重试。");
      state.session = session;
      persistSession(session);
      return "";
    } catch (error) {
      return error.message || "Google 登录失败";
    } finally {
      sessionStorage.removeItem(OAUTH_PKCE_VERIFIER_KEY);
      clearOAuthCallbackURL();
    }
  }

  const fragment = new URLSearchParams(window.location.hash.slice(1));
  const accessToken = fragment.get("access_token");
  const authError = callbackURL.searchParams.get("error_description") || callbackURL.searchParams.get("error") || fragment.get("error_description") || fragment.get("error");
  if (!accessToken && !authError) return "";

  // OAuth credentials are returned in the URL fragment. Persist them locally
  // and immediately remove the fragment so they are not left in browser history.
  if (accessToken) {
    const expiresIn = Number(fragment.get("expires_in") || 3600);
    state.session = {
      access_token: accessToken,
      refresh_token: fragment.get("refresh_token") || "",
      expires_in: expiresIn,
      expires_at: Math.floor(Date.now() / 1000) + expiresIn,
      token_type: fragment.get("token_type") || "bearer"
    };
    persistSession(state.session);
  }
  clearOAuthCallbackURL();
  return authError || "";
}

function clearOAuthCallbackURL() {
  window.history.replaceState({}, document.title, window.location.pathname);
}

function configured() {
  return Boolean(config.supabaseUrl && config.supabasePublishableKey && config.apiBaseUrl);
}

async function signIn(event) {
  event.preventDefault();
  showLoginError("");
  const email = $("#login-email").value.trim();
  const password = $("#login-password").value;
  try {
    const response = await fetch(`${stripSlash(config.supabaseUrl)}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { apikey: config.supabasePublishableKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email, password })
    });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error_description || payload.msg || "登录失败");
    state.session = payload;
    persistSession(payload);
    await enterStudio();
  } catch (error) {
    showLoginError(error.message || "登录失败");
  }
}

async function signInWithGoogle() {
  showLoginError("");
  const redirectTo = config.oauthRedirectUrl || `${window.location.origin}${window.location.pathname}`;
  const redirectURL = new URL(redirectTo);
  if (window.location.origin !== redirectURL.origin) {
    showLoginError(`请从 ${redirectURL.origin} 打开 CMS 后再使用 Google 登录。`);
    return;
  }
  if (redirectURL.protocol !== "https:") {
    showLoginError("Google 登录需要通过已部署的 HTTPS CMS 地址打开。");
    return;
  }
  try {
    const verifier = createPKCEVerifier();
    sessionStorage.setItem(OAUTH_PKCE_VERIFIER_KEY, verifier);
    const authorize = new URL(`${stripSlash(config.supabaseUrl)}/auth/v1/authorize`);
    authorize.searchParams.set("provider", "google");
    authorize.searchParams.set("redirect_to", redirectTo);
    authorize.searchParams.set("response_type", "code");
    authorize.searchParams.set("code_challenge", await createPKCEChallenge(verifier));
    authorize.searchParams.set("code_challenge_method", "S256");
    window.location.assign(authorize.toString());
  } catch (error) {
    sessionStorage.removeItem(OAUTH_PKCE_VERIFIER_KEY);
    showLoginError(error.message || "Google 登录无法启动。");
  }
}

function createPKCEVerifier() {
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  return base64URL(randomBytes);
}

async function createPKCEChallenge(verifier) {
  const input = new TextEncoder().encode(verifier);
  return base64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", input)));
}

function base64URL(bytes) {
  let binary = "";
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function enterStudio() {
  state.bootstrap = await api("/v1/bootstrap");
  $("#login-screen").classList.add("hidden");
  $("#studio").classList.remove("hidden");
  $("#viewer-email").textContent = state.bootstrap.viewer.email || state.bootstrap.viewer.id;
  $("#role-label").textContent = state.bootstrap.viewer.role === "admin" ? "管理员" : "内容编辑";
  fillSelects();
  await Promise.all([loadDraftCounts(), loadPublished()]);
}

function fillSelects() {
  const board = $("#board-id");
  board.replaceChildren(...state.bootstrap.boards.map((item) => option(item.id, `${forumBoardEmoji(item.icon)} ${item.name}`)));
  const categories = {
    home_appliances: "家居家电", daily_essentials: "生活用品", fashion_accessories: "服饰鞋包",
    beauty_care: "美妆护理", sports_outdoors: "运动户外", digital_electronics: "数码电子",
    books_academic: "图书学业", pet_supplies: "宠物用品", other: "其他"
  };
  const conditions = { new: "全新", like_new: "99新", good: "良好", fair: "一般", poor: "明显使用" };
  $("#category").replaceChildren(...state.bootstrap.secondhandCategories.map((item) => option(item, categories[item] || item)));
  $("#condition").replaceChildren(...state.bootstrap.secondhandConditions.map((item) => option(item, conditions[item] || item)));
}

// Board icons are SF Symbols identifiers for the iOS app. A browser cannot
// render those names, so Content Studio uses an equivalent, human-readable
// emoji instead of exposing implementation identifiers in the UI.
function forumBoardEmoji(icon) {
  const symbols = {
    "building.columns.fill": "🏛️",
    sparkles: "✨",
    "questionmark.bubble.fill": "❓",
    "bubble.left.and.bubble.right.fill": "💬",
    "bubble.left.and.text.bubble.right.fill": "💬",
    "theatermasks.fill": "🎭"
  };
  return symbols[icon] || "💬";
}

function option(value, label) {
  const element = document.createElement("option");
  element.value = value;
  element.textContent = label;
  return element;
}

function goTo(screen) {
  $$(".screen").forEach((item) => item.classList.toggle("active", item.id === `${screen}-screen`));
  $$(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.screen === screen));
  const title = { overview: "概览", create: "新建内容", drafts: "草稿", published: "已发布" }[screen];
  $("#page-title").textContent = title;
  if (screen === "drafts") loadDrafts();
  if (screen === "published") loadPublished();
}

function startCreate() {
  resetEditor();
  goTo("create");
}

function setKind(kind) {
  state.kind = kind;
  $$(".type-tab").forEach((button) => button.classList.toggle("active", button.dataset.kind === kind));
  $("#forum-fields").classList.toggle("hidden", kind !== "forum");
  $("#secondhand-fields").classList.toggle("hidden", kind !== "secondhand");
  $("#media-count").textContent = `${mediaCount()} / 6`;
  renderPreview();
}

function resetEditor() {
  state.kind = "forum";
  state.draftId = null;
  state.existingMedia = [];
  state.remoteMedia = [];
  clearSelectedMedia();
  state.editing = null;
  $("#editor-form").reset();
  $("#draft-id").value = "";
  $("#publish-button").textContent = "发布内容";
  $("#editor-status").textContent = "";
  setKind("forum");
  renderMedia();
  renderPreview();
}

function payloadFromEditor() {
  const common = {
    title: $("#title").value.trim(),
    description: $("#description").value.trim(),
    isAnonymous: state.kind === "forum" ? $("#forum-anonymous").checked : $("#market-anonymous").checked,
    media: state.remoteMedia
  };
  return state.kind === "forum"
    ? { ...common, boardId: $("#board-id").value }
    : {
        ...common,
        price: $("#price").value,
        originalPrice: $("#original-price").value,
        category: $("#category").value,
        condition: $("#condition").value,
        isNegotiable: $("#negotiable").checked
      };
}

async function chooseImages(event) {
  const selected = [...event.target.files];
  const remaining = 6 - mediaCount();
  if (selected.length > remaining) showToast(`最多选择 6 张图片；已保留前 ${remaining} 张。`, true);
  for (const file of selected.slice(0, Math.max(0, remaining))) {
    try {
      const jpg = await compressToJpeg(file);
      state.selectedMedia.push({ file: jpg, previewURL: URL.createObjectURL(jpg) });
    } catch {
      showToast("有一张图片无法处理，请更换后重试。", true);
    }
  }
  event.target.value = "";
  renderMedia();
}

async function saveDraft(silent = false) {
  try {
    setEditorBusy(true, "正在保存草稿…");
    const payload = payloadFromEditor();
    let draft;
    if (state.draftId) {
      draft = (await api(`/v1/drafts/${state.draftId}`, { method: "PATCH", body: { contentType: state.kind, title: payload.title, payload } })).draft;
    } else {
      draft = (await api("/v1/drafts", { method: "POST", body: { contentType: state.kind, title: payload.title, payload } })).draft;
      state.draftId = draft.id;
      $("#draft-id").value = draft.id;
    }
    if (state.selectedMedia.length) {
      const uploaded = [];
      for (const item of state.selectedMedia) uploaded.push(await uploadMedia(draft.id, item.file));
      state.remoteMedia.push(...uploaded);
      clearSelectedMedia();
      draft = (await api(`/v1/drafts/${draft.id}`, { method: "PATCH", body: { contentType: state.kind, title: payload.title, payload: payloadFromEditor() } })).draft;
    }
    renderMedia();
    if (!silent) showToast("草稿已保存。");
    await loadDraftCounts();
    return draft;
  } catch (error) {
    showToast(error.message || "草稿未能保存。", true);
    throw error;
  } finally {
    setEditorBusy(false);
  }
}

async function publish(event) {
  event.preventDefault();
  try {
    if (!confirm(state.editing ? "确认保存这次修改？" : "确认按当前预览正式发布？")) return;
    const draft = await saveDraft(true);
    const editing = state.editing;
    setEditorBusy(true, "正在通过正式发布链路发布…");
    const target = editing
      ? `/v1/posts/${editing.kind}/${editing.id}`
      : `/v1/publish/${state.kind}`;
    const result = await api(target, {
      method: editing ? "PATCH" : "POST",
      body: editing
        ? { payload: payloadFromEditor(), isPrivate: state.editing.isPrivate, keepImageIds: state.editing.keepImageIds }
        : { draftId: draft.id }
    });
    if (editing && draft?.id) await api(`/v1/drafts/${draft.id}`, { method: "DELETE" });
    showToast(editing ? "内容已更新。" : "内容已发布。", false);
    resetEditor();
    goTo("published");
    await Promise.all([loadPublished(), loadDraftCounts()]);
    return result;
  } catch (error) {
    showToast(error.message || "发布失败。", true);
  } finally {
    setEditorBusy(false);
  }
}

async function uploadMedia(draftId, file) {
  const form = new FormData();
  form.set("draftId", draftId);
  form.set("file", file, "image.jpg");
  return (await api("/v1/draft-media", { method: "POST", body: form })).media;
}

async function loadDraftCounts() {
  try {
    const { drafts } = await api("/v1/drafts");
    $("#forum-draft-count").textContent = drafts.filter((item) => item.content_type === "forum").length;
    $("#market-draft-count").textContent = drafts.filter((item) => item.content_type === "secondhand").length;
  } catch { /* The interactive view will show the failure if needed. */ }
}

async function loadDrafts() {
  const container = $("#draft-list");
  container.textContent = "";
  try {
    const { drafts } = await api("/v1/drafts");
    if (!drafts.length) return renderEmpty(container);
    drafts.forEach((draft) => container.appendChild(draftRow(draft)));
  } catch (error) {
    showToast(error.message || "草稿加载失败。", true);
  }
}

function draftRow(draft) {
  const row = contentRow({
    kind: draft.content_type,
    title: draft.title || "未命名草稿",
    description: draft.payload?.description || "尚未填写正文",
    media: draft.payload?.media || [],
    meta: `更新于 ${formatTime(draft.updated_at)}`
  });
  const actions = row.querySelector(".content-actions");
  actions.append(actionButton("继续编辑", () => resumeDraft(draft)));
  actions.append(actionButton("删除", async () => {
    if (!confirm("删除这份草稿？此操作不可恢复。")) return;
    await api(`/v1/drafts/${draft.id}`, { method: "DELETE" });
    await Promise.all([loadDrafts(), loadDraftCounts()]);
    showToast("草稿已删除。");
  }, "danger"));
  return row;
}

async function resumeDraft(draft) {
  resetEditor();
  state.draftId = draft.id;
  state.kind = draft.content_type;
  state.remoteMedia = draft.payload?.media || [];
  $("#draft-id").value = draft.id;
  $("#title").value = draft.payload?.title || draft.title || "";
  $("#description").value = draft.payload?.description || "";
  if (state.kind === "forum") {
    $("#board-id").value = draft.payload?.boardId || $("#board-id").value;
    $("#forum-anonymous").checked = Boolean(draft.payload?.isAnonymous);
  } else {
    $("#price").value = draft.payload?.price ?? "";
    $("#original-price").value = draft.payload?.originalPrice ?? "";
    $("#category").value = draft.payload?.category || "other";
    $("#condition").value = draft.payload?.condition || "good";
    $("#market-anonymous").checked = Boolean(draft.payload?.isAnonymous);
    $("#negotiable").checked = Boolean(draft.payload?.isNegotiable);
  }
  setKind(state.kind);
  await renderMedia();
  renderPreview();
  goTo("create");
}

async function loadPublished() {
  const container = $("#published-list");
  container.textContent = "";
  try {
    const { posts } = await api(`/v1/posts?kind=${state.publishedKind}`);
    if (!posts.length) return renderEmpty(container);
    posts.forEach((post) => container.appendChild(publishedRow(post, state.publishedKind)));
  } catch (error) {
    showToast(error.message || "已发布内容加载失败。", true);
  }
}

function publishedRow(post, kind) {
  const row = contentRow({
    kind,
    title: post.title,
    description: post.description || "未填写正文",
    media: post.images || [],
    meta: `${post.is_private ? "已隐藏 · " : ""}${formatTime(post.updated_at || post.created_at)}`
  });
  const actions = row.querySelector(".content-actions");
  actions.append(actionButton("编辑", () => editPost(post, kind)));
  actions.append(actionButton(post.is_private ? "恢复公开" : "隐藏", async () => {
    await api(`/v1/posts/${kind}/${post.id}/hide`, { method: "POST", body: { hidden: !post.is_private } });
    await loadPublished();
    showToast(post.is_private ? "帖子已恢复公开。" : "帖子已隐藏。");
  }));
  actions.append(actionButton("删除", async () => {
    if (!confirm("删除后无法恢复，也会删除关联图片。确定继续？")) return;
    await api(`/v1/posts/${kind}/${post.id}/delete`, { method: "POST", body: {} });
    await loadPublished();
    showToast("帖子已删除。");
  }, "danger"));
  return row;
}

function editPost(post, kind) {
  resetEditor();
  state.existingMedia = post.images || [];
  state.editing = {
    id: post.id,
    kind,
    isPrivate: Boolean(post.is_private),
    keepImageIds: state.existingMedia.map((image) => image.id)
  };
  state.kind = kind;
  $("#title").value = post.title || "";
  $("#description").value = post.description || "";
  if (kind === "forum") {
    $("#board-id").value = post.board_id;
    $("#forum-anonymous").checked = Boolean(post.is_anonymous);
  } else {
    $("#price").value = post.price ?? "";
    $("#original-price").value = post.original_price ?? "";
    $("#category").value = post.category || "other";
    $("#condition").value = post.condition || "good";
    $("#market-anonymous").checked = Boolean(post.is_anonymous);
    $("#negotiable").checked = Boolean(post.is_negotiable);
  }
  $("#publish-button").textContent = "保存修改";
  $("#editor-status").textContent = "保留原有图片；可额外添加新图片。";
  setKind(kind);
  renderPreview();
  goTo("create");
}

function contentRow({ kind, title, description, media, meta }) {
  const row = document.createElement("article");
  row.className = "content-row";
  const thumb = document.createElement("div");
  thumb.className = "content-thumb";
  const first = media[0];
  if (first?.url) { const image = new Image(); image.src = first.url; image.alt = ""; thumb.append(image); }
  else thumb.textContent = kind === "forum" ? "💬" : "🛍️";
  const copy = document.createElement("div");
  copy.className = "content-copy";
  copy.innerHTML = `<h3>${escapeHTML(title)}</h3><p>${escapeHTML(description)}</p><p class="content-meta">${escapeHTML(kind === "forum" ? "论坛" : "二手")} · ${escapeHTML(meta)}</p>`;
  const actions = document.createElement("div"); actions.className = "content-actions";
  row.append(thumb, copy, actions);
  return row;
}

function actionButton(label, handler, className = "") {
  const button = document.createElement("button");
  button.type = "button"; button.textContent = label; button.className = className;
  button.addEventListener("click", async () => {
    try { await handler(); } catch (error) { showToast(error.message || "操作失败。", true); }
  });
  return button;
}

async function renderMedia() {
  const grid = $("#media-grid");
  grid.textContent = "";
  const items = [
    ...state.existingMedia.map((media, index) => ({ type: "existing", media, index })),
    ...state.remoteMedia.map((media, index) => ({ type: "remote", media, index })),
    ...state.selectedMedia.map((media, index) => ({ type: "selected", media, index }))
  ];
  for (const item of items) {
    const tile = document.createElement("div"); tile.className = "media-tile";
    const image = new Image(); image.alt = "已选图片";
    if (item.type === "selected") image.src = item.media.previewURL;
    else if (item.type === "existing") image.src = item.media.url;
    else image.src = await draftMediaURL(item.media.path);
    tile.append(image);
    const remove = document.createElement("button"); remove.type = "button"; remove.className = "remove-media"; remove.textContent = "×";
    remove.addEventListener("click", () => {
      if (item.type === "selected") { URL.revokeObjectURL(item.media.previewURL); state.selectedMedia.splice(item.index, 1); }
      else if (item.type === "existing") {
        state.existingMedia.splice(item.index, 1);
        state.editing.keepImageIds = state.existingMedia.map((image) => image.id);
      } else state.remoteMedia.splice(item.index, 1);
      renderMedia();
    });
    tile.append(remove); grid.append(tile);
  }
  $("#media-count").textContent = `${mediaCount()} / 6`;
  renderPreview();
}

function renderPreview() {
  if (!$("#preview-title")) return;
  const isForum = state.kind === "forum";
  const title = $("#title").value.trim() || "未命名标题";
  const description = $("#description").value.trim() || "正文预览会显示在这里。";
  $("#preview-type").textContent = isForum ? "论坛" : "二手";
  $("#preview-title").textContent = title;
  $("#preview-description").textContent = description;
  $("#preview-context").textContent = isForum
    ? ($("#board-id").selectedOptions[0]?.textContent || "选择一个论坛板块")
    : `${$("#condition").selectedOptions[0]?.textContent || "成色"} · CAD ${$("#price").value || "0"}`;
  const media = $("#preview-media");
  media.textContent = (state.existingMedia.length || state.remoteMedia.length)
    ? `已保存 ${state.existingMedia.length + state.remoteMedia.length} 张图片`
    : "暂无图片";
  const selected = state.selectedMedia[0];
  if (selected?.previewURL) { const image = new Image(); image.src = selected.previewURL; image.alt = "预览图片"; media.replaceChildren(image); }
}

async function draftMediaURL(path) {
  if (!state.draftId) return "";
  try {
    const response = await apiRaw(`/v1/draft-media?draftId=${encodeURIComponent(state.draftId)}&path=${encodeURIComponent(path)}`);
    return URL.createObjectURL(await response.blob());
  } catch { return ""; }
}

function mediaCount() { return state.existingMedia.length + state.remoteMedia.length + state.selectedMedia.length; }
function clearSelectedMedia() { state.selectedMedia.forEach((item) => URL.revokeObjectURL(item.previewURL)); state.selectedMedia = []; }
function renderEmpty(container) { container.append($("#empty-template").content.cloneNode(true)); }
function setEditorBusy(busy, message = "") { $("#publish-button").disabled = busy; $("#save-draft").disabled = busy; $("#editor-status").textContent = message; }

async function api(path, { method = "GET", body } = {}) {
  const response = await apiRaw(path, { method, body });
  if (response.status === 204) return null;
  return response.json();
}

async function apiRaw(path, { method = "GET", body } = {}) {
  const headers = { Authorization: `Bearer ${state.session?.access_token || ""}` };
  const init = { method, headers };
  if (body instanceof FormData) init.body = body;
  else if (body !== undefined) { headers["Content-Type"] = "application/json"; init.body = JSON.stringify(body); }
  const response = await fetch(`${stripSlash(config.apiBaseUrl)}${path}`, init);
  if (response.status === 401) {
    let detail = "登录已过期，请重新登录。";
    try { detail = (await response.json()).error || detail; } catch { /* no JSON */ }
    clearSession();
    throw new Error(detail);
  }
  if (!response.ok) {
    let detail = "请求失败";
    try { detail = (await response.json()).error || detail; } catch { /* no JSON */ }
    throw new Error(detail);
  }
  return response;
}

async function compressToJpeg(file) {
  if (!file.type.startsWith("image/")) throw new Error("请选择图片文件");
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale); canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", .82));
  if (!blob) throw new Error("图片转换失败");
  return new File([blob], "image.jpg", { type: "image/jpeg" });
}

function persistSession(value) { localStorage.setItem(SESSION_KEY, JSON.stringify(value)); }
function readSession() { try { return JSON.parse(localStorage.getItem(SESSION_KEY) || "null"); } catch { return null; } }
function clearSession() { localStorage.removeItem(SESSION_KEY); state.session = null; }
function stripSlash(value) { return String(value || "").replace(/\/$/, ""); }
function showLoginError(message) { $("#login-error").textContent = message; }
function showToast(message, isError = false) { const toast = $("#toast"); toast.textContent = message; toast.className = `toast visible${isError ? " error" : ""}`; clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.className = "toast", 4200); }
function formatTime(value) { return new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)); }
function escapeHTML(value) { return String(value || "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[char])); }
