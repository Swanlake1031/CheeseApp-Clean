import {
  fallbackDescription,
  fallbackTitle,
  kindDisplayLabel,
  normalizeText
} from "./utils/format.js";
import {
  buildPreviewImageURL,
  isFallbackPreviewImagePath,
  isAASAPath,
  isDownloadPath,
  matchOpenPath,
  isWWWHost,
  matchCanonicalPostPath,
  matchPreviewImagePath,
  normalizeGateTarget,
  redirectToCanonicalHost
} from "./utils/routes.js";
import {
  renderDownloadPage,
  renderDownloadPageFromData
} from "./pages/download.js";
import { renderForumDetailPage } from "./pages/forum.js";
import { renderSecondhandDetailPage } from "./pages/secondhand.js";
import { renderGenericPostPage } from "./pages/post.js";
import { pageShell } from "./ui/shell.js";
import { fetchSecondhandMetadata } from "./data/secondhand.js";
import { fetchForumMetadata } from "./data/forum.js";
import { renderPreviewImage } from "./ui/preview.js";
import { CHEESE_SHARE_FALLBACK_PNG_BASE64 } from "./ui/staticAssets.js";
import { processPushQueue } from "./push/queue.js";
import { processMediaCleanup, safeErrorCode } from "./media/cleanup.js";
import { processSecondhandLifecycle } from "./secondhand/lifecycle.js";
  
export default {
  async fetch(request, env) {
    const config = await readConfig(env);
    const url = new URL(request.url);

    if (isBrandAssetPath(url.pathname) && env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    if (isWWWHost(url, config)) {
      return redirectToCanonicalHost(url, config);
    }

    if (isAASAPath(url.pathname)) {
      return json(buildAASA(config.appID), {
        "Cache-Control": "public, max-age=3600"
      });
    }

    if (url.pathname === "/" || url.pathname === "") {
      return html(renderHomePage(config), {
        "Cache-Control": "public, max-age=300"
      });
    }

    if (isDownloadPath(url.pathname)) {
      return html(renderDownloadPage({ config, url }), {
        "Cache-Control": "public, max-age=300"
      });
    }

    const openPageMatch = matchOpenPath(url.pathname);
    if (openPageMatch) {
      const metadata = await fetchPostMetadata({
        kind: openPageMatch.kind,
        postID: openPageMatch.postID,
        config
      });
      const previewImageURL = buildPreviewImageURL(
        config,
        openPageMatch.kind,
        openPageMatch.postID,
        metadata.imageURL || ""
      );
      return html(
        renderPostPage({
          config,
          kind: openPageMatch.kind,
          postID: openPageMatch.postID,
          metadata,
          previewImageURL,
          detailImageURL: metadata.imageURL || "",
          showOpenGuidance: true
        }),
        {
          "Cache-Control": "public, max-age=300"
        }
      );
    }

    if (isFallbackPreviewImagePath(url.pathname)) {
      return png(CHEESE_SHARE_FALLBACK_PNG_BASE64, {
        "Cache-Control": "public, max-age=86400, immutable"
      });
    }

    const exactPostMatch = matchCanonicalPostPath(url.pathname);
    if (exactPostMatch) {
      const gatedTarget = normalizeGateTarget(url.searchParams.get("target"));
      if (gatedTarget) {
        return html(
          renderDownloadPageFromData({
            config,
            kind: exactPostMatch.kind,
            postID: exactPostMatch.postID,
            target: gatedTarget
          }),
          {
            "Cache-Control": "public, max-age=300"
          }
        );
      }

      const metadata = await fetchPostMetadata({
        kind: exactPostMatch.kind,
        postID: exactPostMatch.postID,
        config
      });
      const previewImageURL = buildPreviewImageURL(
        config,
        exactPostMatch.kind,
        exactPostMatch.postID,
        metadata.imageURL || ""
      );
      const status = metadata.status === "unavailable" ? 404 : 200;
      return html(
        renderPostPage({
          ...exactPostMatch,
          config,
          metadata,
          previewImageURL,
          detailImageURL: metadata.imageURL || ""
        }),
        {
        status,
        "Cache-Control": "public, max-age=300"
        }
      );
    }

    const previewImageMatch = matchPreviewImagePath(url.pathname);
    if (previewImageMatch) {
      const metadata = await fetchPostMetadata({
        kind: previewImageMatch.kind,
        postID: previewImageMatch.postID,
        config
      });
      return svg(renderPreviewImage({ ...previewImageMatch, metadata }), {
        "Cache-Control": "public, max-age=300"
      });
    }

    if (url.pathname.startsWith("/posts/")) {
      return html(renderInvalidPostPage(config), {
        status: 404,
        "Cache-Control": "public, max-age=300"
      });
    }

    return html(renderNotFoundPage(config), {
      status: 404,
      "Cache-Control": "public, max-age=300"
    });
  },

  async scheduled(_controller, env, ctx) {
    const config = await readConfig(env);
    ctx.waitUntil(
      processPushQueue({ config }).catch((error) => {
        console.error("Push queue worker failed", safeErrorCode(error));
      })
    );
    ctx.waitUntil(
      processMediaCleanup({ config }).then((result) => {
        if (result.skipped) {
          console.warn("Media cleanup worker skipped", result.skipped);
          return;
        }
        console.log("Media cleanup worker summary", {
          kinds: result.kinds,
          metrics: result.metrics
        });
      }).catch((error) => {
        console.error("Media cleanup worker failed", safeErrorCode(error));
      })
    );
    ctx.waitUntil(
      processSecondhandLifecycle({ config }).then((result) => {
        if (result.skipped) {
          console.warn("Secondhand lifecycle worker skipped", result.skipped);
          return;
        }
        console.log("Secondhand lifecycle worker summary", {
          remindersCreated: result.remindersCreated,
          listingsHidden: result.listingsHidden
        });
      }).catch((error) => {
        console.error(
          "Secondhand lifecycle worker failed",
          safeErrorCode(error)
        );
      })
    );
  }
};

async function readConfig(env) {
  const serviceRoleKey = await resolveEnvSecret(env.SUPABASE_SERVICE_ROLE_KEY);
  const apnsPrivateKey = await resolveEnvSecret(env.APNS_AUTH_KEY);
  const publishableKey = normalizeText(env.SUPABASE_PUBLISHABLE_KEY);
  const canonicalHost = env.CANONICAL_HOST || "cheeseapp.org";
  const appID = env.APP_ID || "59RCF5754W.com.timonayf.cheeseapp";
  const bundleID =
    normalizeText(env.APP_BUNDLE_ID) ||
    stripTeamPrefix(appID) ||
    "com.timonayf.cheeseapp";

  return {
    appID,
    canonicalHost,
    appScheme: env.APP_SCHEME || "cheeseapp://post",
    siteName: "Cheese",
    appDownloadURL:
      normalizeText(env.APP_DOWNLOAD_URL) || `https://${canonicalHost}/`,
    supabaseURL: normalizeText(env.SUPABASE_URL),
    supabasePublishableKey: publishableKey,
    supabaseServiceRoleKey: serviceRoleKey,
    supabaseAuthKey: serviceRoleKey || publishableKey,
    apnsPrivateKey,
    apnsKeyID: normalizeText(env.APNS_KEY_ID),
    appleTeamID: normalizeText(env.APPLE_TEAM_ID),
    apnsTopic: bundleID,
    wechatOpenAppID: normalizeText(env.WECHAT_OPEN_APP_ID),
    wechatJSSDKConfigURL: normalizeText(env.WECHAT_JS_SDK_CONFIG_URL)
  };
}

async function resolveEnvSecret(binding) {
  if (!binding) {
    return "";
  }

  if (typeof binding === "string") {
    return normalizeText(binding);
  }

  if (typeof binding.get === "function") {
    try {
      return normalizeText(await binding.get());
    } catch (error) {
      console.error("Failed to resolve secrets store binding", error);
      return "";
    }
  }

  return "";
}

function stripTeamPrefix(appID) {
  const normalized = normalizeText(appID);
  if (!normalized) {
    return "";
  }

  const segments = normalized.split(".");
  if (segments.length <= 1) {
    return normalized;
  }

  return segments.slice(1).join(".");
}

function buildAASA(appID) {
  return {
    applinks: {
      details: [
        {
          appIDs: [appID],
          components: [
            {
              "/": "/posts/*",
              comment: "Open Cheese shared post links in app"
            },
            {
              "/": "/open/*",
              comment: "Open Cheese open-app handoff links in app"
            }
          ]
        }
      ]
    }
  };
}

function isBrandAssetPath(pathname) {
  return new Set([
    "/apple-touch-icon.png",
    "/favicon.ico",
    "/favicon-32x32.png",
    "/favicon-192x192.png",
    "/favicon-512x512.png",
    "/manifest.webmanifest",
    "/og/default.png"
  ]).has(pathname);
}

function renderHomePage(config) {
  return pageShell({
    title: "Cheese 分享页",
    description:
      "Cheese 的帖子分享入口，提供外部链接、通用链接验证与网页回退页。",
    canonicalURL: `https://${config.canonicalHost}/`,
    body: `
      <div class="card">
        <div class="eyebrow">Cheese 分享入口</div>
        <h1>Cheese 公开分享页已上线。</h1>
        <p>这个域名用于 Cheese 的帖子分享、通用链接验证，以及未安装 App 时的网页内容页。</p>
      </div>
    `
  });
}


function renderPostPage({
  kind,
  postID,
  config,
  metadata,
  previewImageURL,
  detailImageURL = "",
  showOpenGuidance = false
}) {
  if (kind === "secondhand" && metadata.status === "ok") {
    return renderSecondhandDetailPage({
      kind,
      postID,
      config,
      metadata,
      previewImageURL,
      detailImageURL,
      showOpenGuidance
    });
  }

  if (kind === "forum" && metadata.status === "ok") {
    return renderForumDetailPage({
      postID,
      config,
      metadata,
      previewImageURL,
      showOpenGuidance
    });
  }

  return renderGenericPostPage({
    kind,
    postID,
    config,
    metadata,
    previewImageURL,
    detailImageURL,
    showOpenGuidance
  });
}


function renderInvalidPostPage(config) {
  return pageShell({
    title: "Cheese 链接无效",
    description: "这个 Cheese 分享链接缺少有效的帖子标识。",
    canonicalURL: `https://${config.canonicalHost}/`,
    body: `
      <div class="card">
        <div class="eyebrow">Cheese</div>
        <h1>帖子链接无效</h1>
        <p>这个链接没有包含有效的帖子标识，请让发送者重新从 Cheese 分享一次。</p>
      </div>
    `
  });
}

function renderNotFoundPage(config) {
  return pageShell({
    title: "Cheese",
    description: "找不到这个 Cheese 网页。",
    canonicalURL: `https://${config.canonicalHost}/`,
    body: `
      <div class="card">
        <div class="eyebrow">Cheese</div>
        <h1>页面不存在</h1>
        <p>你要打开的 Cheese 页面目前不存在，可能链接已失效或路径有误。</p>
      </div>
    `
  });
}

async function fetchPostMetadata({ kind, postID, config }) {
  try {
    switch (kind) {
      case "secondhand":
        return await fetchSecondhandMetadata({
          postID,
          config,
          fetchSingleRow,
          firstImageURL,
          fallbackDescription,
          fallbackTitle,
          unavailableMetadata
        });
      case "forum":
        return await fetchForumMetadata({
          postID,
          config,
          fetchSingleRow,
          firstImageURL,
          unavailableMetadata
        });
      default:
        return unavailableMetadata(kind);
    }
  } catch (error) {
    console.error("share metadata fetch failed", kind, postID, error);
    return {
      status: "fallback",
      title: fallbackTitle(kind),
      description: fallbackDescription(kind),
      imageURL: ""
    };
  }
}

async function fetchSingleRow({ config, table, select, postID, idParameter = "id" }) {
  const rows = await fetchRows({
    config,
    table,
    select,
    filters: {
      [idParameter]: idParameter === "id" ? `eq.${postID}` : postID,
      limit: "1"
    }
  });

  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function fetchRows({ config, table, select, filters = {} }) {
  const endpoint = new URL(`${config.supabaseURL}/rest/v1/${table}`);
  endpoint.searchParams.set("select", select);

  for (const [key, value] of Object.entries(filters)) {
    endpoint.searchParams.set(key, value);
  }

  const response = await fetch(endpoint.toString(), {
    headers: buildSupabaseHeaders(config.supabaseAuthKey)
  });

  if (!response.ok) {
    throw new Error(`Supabase ${table} request failed: ${response.status}`);
  }

  return response.json();
}

function buildSupabaseHeaders(apiKey) {
  const key = normalizeText(apiKey);
  if (!key) {
    return {};
  }

  const headers = {
    apikey: key
  };

  // Legacy JWT keys (`service_role` / `anon`) still work as Bearer tokens.
  // New platform keys (`sb_secret_...` / `sb_publishable_...`) should be sent as `apikey` only.
  if (!key.startsWith("sb_")) {
    headers.Authorization = `Bearer ${key}`;
  }

  return headers;
}

function unavailableMetadata(kind) {
  return {
    status: "unavailable",
    title:
      kind === "secondhand"
        ? "这篇二手帖子暂时不可用"
        : `这篇${kindDisplayLabel(kind)}帖子暂时不可用`,
    description:
      kind === "secondhand"
        ? "这篇分享的 Cheese 二手帖子目前已下架或不可见。"
        : "这篇分享的 Cheese 帖子目前已下架或不可见。",
    imageURL: ""
  };
}

function firstImageURL(images) {
  if (!Array.isArray(images) || images.length === 0) {
    return "";
  }

  const sorted = [...images].sort((lhs, rhs) => {
    const left = Number.isFinite(lhs?.order_index) ? lhs.order_index : Number.MAX_SAFE_INTEGER;
    const right = Number.isFinite(rhs?.order_index) ? rhs.order_index : Number.MAX_SAFE_INTEGER;
    return left - right;
  });

  return sorted.find((image) => typeof image?.url === "string" && image.url.trim())?.url?.trim() || "";
}

function html(markup, options = {}) {
  const { status = 200, ...headers } = options;
  return new Response(markup, {
    status,
    headers: {
      "Content-Type": "text/html; charset=UTF-8",
      ...headers
    }
  });
}

function json(data, headers = {}) {
  return new Response(JSON.stringify(data), {
    headers: {
      "Content-Type": "application/json",
      ...headers
    }
  });
}

function svg(markup, headers = {}) {
  return new Response(markup, {
    headers: {
      "Content-Type": "image/svg+xml; charset=UTF-8",
      ...headers
    }
  });
}

function png(base64, headers = {}) {
  const binary = atob(base64);
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return new Response(bytes, {
    headers: {
      "Content-Type": "image/png",
      ...headers
    }
  });
}
