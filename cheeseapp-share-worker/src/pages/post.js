import {
  escapeHTML,
  fallbackDescription,
  fallbackTitle,
  kindDisplayLabel,
  kindEmoji,
  normalizeText
} from "../utils/format.js";
import { buildOpenPageURL } from "../utils/routes.js";
import { renderOpenGuidance } from "./open.js";
import { pageShell } from "../ui/shell.js";

export function renderGenericPostPage({
  kind,
  postID,
  config,
  metadata,
  previewImageURL,
  detailImageURL = "",
  showOpenGuidance = false
}) {
  const title = metadata.title || fallbackTitle(kind);
  const description = metadata.description || fallbackDescription(kind);
  const canonicalURL = `https://${config.canonicalHost}/posts/${kind}/${postID}`;
  const deepLinkURL = `${config.appScheme}/${kind}/${postID}`;
  const openPageURL = buildOpenPageURL({ config, kind, postID });
  const openActionURL = showOpenGuidance ? deepLinkURL : openPageURL;
  const kindLabel = kindDisplayLabel(kind);
  const chips = Array.isArray(metadata.chips) ? metadata.chips.filter(Boolean) : [];
  const detailRows = Array.isArray(metadata.detailRows)
    ? metadata.detailRows.filter((row) => normalizeText(row?.label) && normalizeText(row?.value))
    : [];
  const bodyText = normalizeText(metadata.bodyText);
  const heroImageURL = detailImageURL || previewImageURL;
  const eyebrow =
    metadata.status === "unavailable"
      ? `${config.siteName} 内容不可用`
      : `${config.siteName} ${kindLabel}`;
  const actionLabel =
    metadata.status === "unavailable" ? "打开 Cheese" : "在 Cheese 中打开";
  const subtext =
    metadata.status === "unavailable"
      ? "这篇分享的帖子目前不可用，你仍然可以打开 Cheese 查看相关内容。"
      : "如果没有自动打开 App，请留在这个页面，或回到消息与备忘录重新打开链接。";
  const media = heroImageURL
    ? `
        <div class="hero-media">
          <img src="${escapeHTML(heroImageURL)}" alt="${escapeHTML(title)}" loading="eager" />
        </div>
      `
    : `
        <div class="hero-placeholder">
          <div class="hero-icon">${escapeHTML(kindEmoji(kind))}</div>
          <div class="hero-label">${escapeHTML(kindLabel)}</div>
        </div>
      `;
  const chipsMarkup = chips.length
    ? `
        <div class="chip-row">
          ${chips.map((chip) => `<span class="chip">${escapeHTML(chip)}</span>`).join("")}
        </div>
      `
    : "";
  const detailRowsMarkup = detailRows.length
    ? `
        <section class="section-card">
          <div class="section-title">信息</div>
          <div class="detail-grid">
            ${detailRows
              .map(
                (row) => `
                  <div class="detail-item">
                    <div class="detail-label">${escapeHTML(row.label)}</div>
                    <div class="detail-value">${escapeHTML(row.value)}</div>
                  </div>
                `
              )
              .join("")}
          </div>
        </section>
      `
    : "";
  const bodyMarkup = bodyText
    ? `
        <section class="section-card">
          <div class="section-title">${escapeHTML(metadata.bodyTitle || "描述")}</div>
          <p class="body-copy">${escapeHTML(bodyText)}</p>
        </section>
      `
    : "";

  return pageShell({
    title,
    description,
    canonicalURL,
    previewImageURL,
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
        <a class="app-open-button" href="${escapeHTML(openActionURL)}">打开</a>
      </div>
      ${showOpenGuidance ? renderOpenGuidance({ deepLinkURL }) : ""}
      <div class="card">
        ${media}
        <div class="eyebrow">${escapeHTML(eyebrow)}</div>
        <h1>${escapeHTML(title)}</h1>
        <p class="lead-copy">${escapeHTML(description)}</p>
        ${chipsMarkup}
        <div class="cta-row">
          <a class="button" href="${escapeHTML(openActionURL)}">${escapeHTML(actionLabel)}</a>
        </div>
        <p class="subtle">${escapeHTML(subtext)}</p>
        ${detailRowsMarkup}
        ${bodyMarkup}
      </div>
    `
  });
}
