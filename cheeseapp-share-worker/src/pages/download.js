import { escapeHTML } from "../utils/format.js";
import {
  buildOpenPageURL,
  normalizeGateTarget,
  normalizeKind,
  normalizePostID
} from "../utils/routes.js";
import { pageShell } from "../ui/shell.js";

export function renderDownloadPage({ config, url }) {
  const kind = normalizeKind(url.searchParams.get("kind"));
  const postID = normalizePostID(url.searchParams.get("post"));
  const target = normalizeGateTarget(url.searchParams.get("target")) || "content";
  return renderDownloadPageFromData({ config, kind, postID, target });
}

export function renderDownloadPageFromData({
  config,
  kind = "",
  postID = "",
  target = "content"
}) {
  const canonicalPostURL =
    kind && postID
      ? `https://${config.canonicalHost}/posts/${kind}/${postID}`
      : `https://${config.canonicalHost}/`;
  const deepLinkURL =
    kind && postID
      ? `${config.appScheme}/${kind}/${postID}`
      : "cheeseapp://";
  const openPageURL =
    kind && postID ? buildOpenPageURL({ config, kind, postID }) : deepLinkURL;
  const title =
    target === "profile"
      ? "請在 Cheese App 中查看個人頁"
      : "請在 Cheese App 中繼續查看";
  const description =
    target === "profile"
      ? "賣家個人頁、互動與更多內容只在 Cheese App 內提供。"
      : "完整內容與互動功能只在 Cheese App 內提供。";
  const secondaryLabel =
    config.appDownloadURL === `https://${config.canonicalHost}/`
      ? "了解 Cheese"
      : "下載 Cheese";

  return pageShell({
    title,
    description,
    canonicalURL: canonicalPostURL,
    previewImageURL: "",
    deepLinkURL,
    appName: config.siteName,
    body: `
      <div class="app-banner">
        <div class="app-banner-brand">
          <div class="app-icon">🧀</div>
          <div>
            <div class="app-name">${escapeHTML(config.siteName)}</div>
            <div class="app-subtitle">在「Cheese」App 中打開</div>
          </div>
        </div>
        <a class="app-open-button" href="${escapeHTML(openPageURL)}">打開</a>
      </div>
      <div class="card download-card">
        <div class="eyebrow">Cheese App</div>
        <h1>${escapeHTML(title)}</h1>
        <p class="lead-copy">${escapeHTML(description)}</p>
        <div class="download-actions">
          <a class="button full-width-button" href="${escapeHTML(openPageURL)}">在 Cheese 中打開</a>
          <a class="secondary-button full-width-button" href="${escapeHTML(config.appDownloadURL)}">${escapeHTML(secondaryLabel)}</a>
        </div>
        <p class="subtle">如果沒有自動打開 App，請先安裝或回到分享來源重新打開這個連結。</p>
        <div class="meta compact-meta">
          <span>目標頁面</span>
          <code>${escapeHTML(target === "profile" ? "個人頁 / Profile" : "貼文詳情 / Post")}</code>
        </div>
      </div>
    `
  });
}
