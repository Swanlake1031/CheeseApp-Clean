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
      ? "请在 Cheese App 中查看个人主页"
      : "请在 Cheese App 中继续查看";
  const description =
    target === "profile"
      ? "卖家个人主页、互动与更多内容仅在 Cheese App 内提供。"
      : "完整内容与互动功能仅在 Cheese App 内提供。";
  const secondaryLabel =
    config.appDownloadURL === `https://${config.canonicalHost}/`
      ? "了解 Cheese"
      : "下载 Cheese";

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
            <div class="app-subtitle">在「Cheese」App 中打开</div>
          </div>
        </div>
        <a class="app-open-button" href="${escapeHTML(openPageURL)}">打开</a>
      </div>
      <div class="card download-card">
        <div class="eyebrow">Cheese App</div>
        <h1>${escapeHTML(title)}</h1>
        <p class="lead-copy">${escapeHTML(description)}</p>
        <div class="download-actions">
          <a class="button full-width-button" href="${escapeHTML(openPageURL)}">在 Cheese 中打开</a>
          <a class="secondary-button full-width-button" href="${escapeHTML(config.appDownloadURL)}">${escapeHTML(secondaryLabel)}</a>
        </div>
        <p class="subtle">如果没有自动打开 App，请先安装或回到分享来源重新打开这个链接。</p>
        <div class="meta compact-meta">
          <span>目标页面</span>
          <code>${escapeHTML(target === "profile" ? "个人主页 / Profile" : "帖子详情 / Post")}</code>
        </div>
      </div>
    `
  });
}
