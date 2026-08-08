import {
  escapeHTML,
  fallbackDescription,
  fallbackTitle,
  normalizeText
} from "../utils/format.js";
import { buildDownloadPageURL, buildOpenPageURL } from "../utils/routes.js";
import { pageShell } from "../ui/shell.js";

export function renderSecondhandDetailPage({
  postID,
  config,
  metadata,
  previewImageURL,
  detailImageURL = ""
}) {
  const title = metadata.title || fallbackTitle("secondhand");
  const description = metadata.description || fallbackDescription("secondhand");
  const canonicalURL = `https://${config.canonicalHost}/posts/secondhand/${postID}`;
  const deepLinkURL = `${config.appScheme}/secondhand/${postID}`;
  const openPageURL = buildOpenPageURL({ config, kind: "secondhand", postID });
  const heroImageURL = detailImageURL;
  const sellerName = normalizeText(metadata.sellerName) || "Cheese 用户";
  const sellerAvatarURL = normalizeText(metadata.sellerAvatarURL);
  const sellerInitial = escapeHTML(sellerName.slice(0, 1).toUpperCase() || "C");
  const sellerAvatar = sellerAvatarURL
    ? `<img src="${escapeHTML(sellerAvatarURL)}" alt="${escapeHTML(sellerName)}" />`
    : `<div class="seller-avatar-fallback">${sellerInitial}</div>`;
  const condition = normalizeText(metadata.conditionLabel);
  const negotiable = normalizeText(metadata.negotiableLabel);
  const category = normalizeText(metadata.categoryLabel);
  const postedAt = normalizeText(metadata.postedAtText);
  const descriptionText =
    normalizeText(metadata.bodyText) || "No description provided yet.";
  const priceText = normalizeText(metadata.priceText);
  const chips = [condition, negotiable].filter(Boolean);
  const chipsMarkup = chips.length
    ? `
        <div class="chip-row">
          ${chips.map((chip) => `<span class="chip">${escapeHTML(chip)}</span>`).join("")}
        </div>
      `
    : "";
  const sellerCaption = "點擊在 Cheese 中查看個人頁";
  const postedMetaLine = [postedAt].filter(Boolean).join(" · ");
  const profileDownloadURL = buildDownloadPageURL({
    config,
    kind: "secondhand",
    postID,
    target: "profile"
  });

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
            <div class="app-subtitle">在「Cheese」App 中打開</div>
          </div>
        </div>
        <a class="app-open-button" href="${escapeHTML(openPageURL)}">打開</a>
      </div>
      <div class="market-detail-page">
      <section class="market-media-card">
        ${
          heroImageURL
            ? `
              <div class="market-media market-media-rect market-media-shell">
                <img
                  src="${escapeHTML(heroImageURL)}"
                  alt="${escapeHTML(title)}"
                  loading="eager"
                  onerror="this.closest('.market-media-shell')?.classList.add('market-media-failed'); this.remove();"
                />
                <div class="market-media-fallback">暫無圖片</div>
                <div class="category-pill category-pill-overlay">${escapeHTML(category || "二手")}</div>
              </div>
            `
            : `
              <div class="market-media market-media-rect market-media-shell market-media-failed">
                <div class="market-media-fallback">暫無圖片</div>
                <div class="category-pill category-pill-overlay">${escapeHTML(category || "二手")}</div>
              </div>
            `
        }
      </section>
      <section class="card market-header-card">
        <h1>${escapeHTML(title)}</h1>
        ${priceText ? `<div class="price-line">${escapeHTML(priceText)}</div>` : ""}
        ${chipsMarkup}
        ${postedMetaLine ? `<div class="meta-inline">${escapeHTML(postedMetaLine)}</div>` : ""}
      </section>
      <section class="card section-surface">
        <div class="section-title">描述</div>
        <div class="description-block">${escapeHTML(descriptionText)}</div>
      </section>
      <section class="card section-surface">
        <div class="section-title">賣家</div>
        <a class="seller-link" href="${escapeHTML(profileDownloadURL)}">
          <div class="seller-row">
            <div class="seller-avatar">${sellerAvatar}</div>
            <div class="seller-copy">
              <div class="seller-name">${escapeHTML(sellerName)}</div>
              <div class="seller-caption">${escapeHTML(sellerCaption)}</div>
            </div>
            <div class="seller-chevron" aria-hidden="true">›</div>
          </div>
        </a>
      </section>
      <section class="sticky-open-bar">
        <a class="button sticky-open-button" href="${escapeHTML(openPageURL)}">在 Cheese 中打開</a>
      </section>
      </div>
    `
  });
}
