import {
  escapeHTML,
  fallbackDescription,
  fallbackTitle,
  kindDisplayLabel,
  kindEmoji,
  kindPalette,
  truncateForPreview,
  wrapPreviewText
} from "../utils/format.js";

export function renderPreviewImage({ kind, postID, metadata }) {
  const title = truncateForPreview(metadata.title || fallbackTitle(kind), 72);
  const description = truncateForPreview(
    metadata.description || fallbackDescription(kind),
    118
  );
  const palette = kindPalette(kind);
  const titleLines = wrapPreviewText(title, 18, 3);
  const descriptionLines = wrapPreviewText(description, 28, 3);
  const titleMarkup = renderSVGTextLines({
    x: 92,
    y: 250,
    lines: titleLines,
    fontSize: 56,
    lineHeight: 66,
    weight: 800,
    fill: "#171717"
  });
  const descriptionMarkup = renderSVGTextLines({
    x: 92,
    y: 462,
    lines: descriptionLines,
    fontSize: 28,
    lineHeight: 40,
    weight: 500,
    fill: "#5b544a"
  });

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg width="1200" height="630" viewBox="0 0 1200 630" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="1200" height="630" rx="0" fill="#F5F0E0" />
  <rect x="48" y="42" width="1104" height="546" rx="34" fill="white" />
  <rect x="48" y="42" width="1104" height="108" rx="34" fill="${palette.badge}" />
  <rect x="92" y="72" width="54" height="54" rx="17" fill="#F2C94C" />
  <text x="119" y="110" text-anchor="middle" font-family="Apple Color Emoji, Segoe UI Emoji, sans-serif" font-size="30">🧀</text>
  <text x="168" y="96" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="30" font-weight="800" fill="#171717">Cheese App</text>
  <text x="168" y="126" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="19" font-weight="600" fill="#6B6358">加拿大留学生内容分享</text>
  <rect x="930" y="72" width="178" height="50" rx="25" fill="white" />
  <text x="1019" y="104" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="24" font-weight="800" fill="#6E5312">${escapeHTML(kindDisplayLabel(kind))}</text>
  <text x="1022" y="286" text-anchor="middle" font-family="Apple Color Emoji, Segoe UI Emoji, sans-serif" font-size="176">${escapeHTML(kindEmoji(kind))}</text>
  <circle cx="1022" cy="268" r="118" fill="${palette.panel}" />
  ${titleMarkup}
  ${descriptionMarkup}
  <line x1="92" y1="526" x2="1108" y2="526" stroke="#ECE5D4" stroke-width="2" />
  <text x="92" y="566" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="26" font-weight="800" fill="#866C1F">来自 Cheese App</text>
  <text x="1108" y="566" text-anchor="end" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="20" font-weight="700" fill="#857B6C">${escapeHTML(postID.slice(0, 8).toUpperCase())}</text>
</svg>`;
}

function renderSVGTextLines({
  x,
  y,
  lines,
  fontSize,
  lineHeight,
  weight,
  fill
}) {
  if (!Array.isArray(lines) || lines.length === 0) {
    return "";
  }

  const tspans = lines
    .map((line, index) => {
      const dy = index === 0 ? 0 : lineHeight;
      return `<tspan x="${x}" dy="${dy}">${escapeHTML(line)}</tspan>`;
    })
    .join("");

  return `<text x="${x}" y="${y}" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="${fontSize}" font-weight="${weight}" fill="${fill}">${tspans}</text>`;
}
