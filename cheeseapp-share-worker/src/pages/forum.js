import {
  escapeHTML,
  fallbackDescription,
  fallbackTitle,
  normalizeText
} from "../utils/format.js";
import { buildDownloadPageURL, buildOpenPageURL } from "../utils/routes.js";
import { renderOpenGuidance } from "./open.js";
import { pageShell } from "../ui/shell.js";

export function renderForumDetailPage({
  postID,
  config,
  metadata,
  previewImageURL,
  showOpenGuidance = false
}) {
  const title = metadata.title || fallbackTitle("forum");
  const description = metadata.description || fallbackDescription("forum");
  const canonicalURL = `https://${config.canonicalHost}/posts/forum/${postID}`;
  const deepLinkURL = `${config.appScheme}/forum/${postID}`;
  const openPageURL = buildOpenPageURL({ config, kind: "forum", postID });
  const openActionURL = showOpenGuidance ? deepLinkURL : openPageURL;
  const boardLabel = normalizeText(metadata.boardLabel) || "论坛";
  const postedAtText = normalizeText(metadata.postedAtText);
  const authorName = normalizeText(metadata.authorName) || "Cheese 用户";
  const authorAvatarURL = normalizeText(metadata.authorAvatarURL);
  const bodyText = normalizeText(metadata.bodyText) || "这篇帖子暂时没有正文。";
  const likeText = normalizeText(metadata.likeText);
  const commentText = normalizeText(metadata.commentText);
  const viewText = normalizeText(metadata.viewText);
  const imageURLs = Array.isArray(metadata.imageURLs) ? metadata.imageURLs.filter(Boolean) : [];
  const isAnonymous = metadata.isAnonymous === true;
  const authorURL = buildDownloadPageURL({
    config,
    kind: "forum",
    postID,
    target: "profile"
  });
  const authorInitial = escapeHTML(authorName.slice(0, 1).toUpperCase() || "C");
  const authorAvatar = authorAvatarURL
    ? `<img src="${escapeHTML(authorAvatarURL)}" alt="${escapeHTML(authorName)}" />`
    : `<div class="seller-avatar-fallback">${authorInitial}</div>`;

  return pageShell({
    title,
    description,
    canonicalURL,
    previewImageURL,
    deepLinkURL,
    appName: config.siteName,
    body: `
      <div class="app-banner app-banner-compact">
        <div class="app-banner-brand">
          <div class="app-icon">🧀</div>
          <div>
            <div class="app-name">${escapeHTML(config.siteName)}</div>
            <div class="app-subtitle">在「Cheese」App 中打开</div>
          </div>
        </div>
        <a class="app-open-button" href="${escapeHTML(openActionURL)}">打开</a>
      </div>
      ${showOpenGuidance ? renderOpenGuidance({ deepLinkURL }) : ""}
      <div class="market-detail-page">
        <section class="card section-surface forum-header-card">
          <div class="top-pill-row">
            <span class="category-pill">${escapeHTML(boardLabel)}</span>
            ${isAnonymous ? `<span class="status-pill subtle-pill">匿名</span>` : ""}
            ${postedAtText ? `<span class="meta-inline">${escapeHTML(postedAtText)}</span>` : ""}
          </div>
          ${
            isAnonymous
              ? `
                <div class="seller-row seller-row-compact">
                  <div class="seller-avatar"><div class="seller-avatar-fallback">匿</div></div>
                  <div class="seller-copy">
                    <div class="seller-name">匿名</div>
                    <div class="seller-caption">此帖子以匿名方式发布</div>
                  </div>
                </div>
              `
              : `
                <a class="seller-link" href="${escapeHTML(authorURL)}">
                  <div class="seller-row seller-row-compact">
                    <div class="seller-avatar">${authorAvatar}</div>
                    <div class="seller-copy">
                      <div class="seller-name">${escapeHTML(authorName)}</div>
                      <div class="seller-caption">点击在 Cheese 中查看个人主页</div>
                    </div>
                    <div class="seller-chevron" aria-hidden="true">›</div>
                  </div>
                </a>
              `
          }
        </section>
        <section class="card section-surface forum-post-card">
          <h1>${escapeHTML(title)}</h1>
          <div class="description-block forum-content-block">${escapeHTML(bodyText)}</div>
          ${
            imageURLs.length
              ? `
                <div class="forum-image-grid ${imageURLs.length === 1 ? "forum-image-grid-single" : ""}">
                  ${imageURLs
                    .map(
                      (url) => `
                        <div class="forum-image-card">
                          <img src="${escapeHTML(url)}" alt="${escapeHTML(title)}" loading="lazy" />
                        </div>
                      `
                    )
                    .join("")}
                </div>
              `
              : ""
          }
          <div class="forum-stat-row">
            ${likeText ? `<div class="forum-stat">❤️ ${escapeHTML(likeText)}</div>` : ""}
            ${commentText ? `<div class="forum-stat">💬 ${escapeHTML(commentText)}</div>` : ""}
            ${viewText ? `<div class="forum-stat">👀 ${escapeHTML(viewText)}</div>` : ""}
          </div>
        </section>
        <section class="sticky-open-bar">
          <a class="button sticky-open-button" href="${escapeHTML(openActionURL)}">在 Cheese 中打开</a>
        </section>
      </div>
    `
  });
}
