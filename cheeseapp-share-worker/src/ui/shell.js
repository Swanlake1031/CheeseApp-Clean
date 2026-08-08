import { escapeHTML } from "../utils/format.js";
import { pageStyles } from "./styles.js";

export function pageShell({
  title,
  description,
  canonicalURL,
  previewImageURL = "",
  deepLinkURL = "",
  appName = "Cheese",
  body
}) {
  const brandedAppName = /app/i.test(appName) ? appName : `${appName} App`;
  const module = inferModuleFromCanonicalURL(canonicalURL);
  const metaTitle = buildMetaTitle({ title, module, brandedAppName });
  const metaDescription = buildMetaDescription({
    description,
    brandedAppName
  });
  const ogType = module ? "article" : "website";
  const hasPreviewImage = Boolean(previewImageURL);
  const twitterCardType = hasPreviewImage ? "summary_large_image" : "summary";
  const previewImageType = inferImageType(previewImageURL);
  const assetOrigin = inferAssetOrigin(canonicalURL);
  const iconVersion = "20260802";
  const imageTags = previewImageURL
    ? `
        <meta property="og:image" content="${escapeHTML(previewImageURL)}" />
        <meta property="og:image:secure_url" content="${escapeHTML(previewImageURL)}" />
        <meta property="og:image:type" content="${escapeHTML(previewImageType)}" />
        <meta property="og:image:width" content="1200" />
        <meta property="og:image:height" content="630" />
        <meta property="og:image:alt" content="${escapeHTML(metaTitle)}" />
        <meta name="twitter:image" content="${escapeHTML(previewImageURL)}" />
      `
    : "";
  const appLinkTags = deepLinkURL
    ? `
        <meta property="al:ios:url" content="${escapeHTML(deepLinkURL)}" />
        <meta property="al:ios:app_name" content="${escapeHTML(brandedAppName)}" />
      `
    : "";

  return `<!doctype html>
<html lang="zh-Hans">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHTML(metaTitle)}</title>
    <meta name="description" content="${escapeHTML(metaDescription)}" />
    <meta name="robots" content="noindex, nofollow" />
    <meta name="theme-color" content="#f7efd8" />
    <link rel="canonical" href="${escapeHTML(canonicalURL)}" />
    <link rel="manifest" href="${assetOrigin}/manifest.webmanifest?v=${iconVersion}" />
    <link rel="apple-touch-icon" sizes="180x180" href="${assetOrigin}/apple-touch-icon.png?v=${iconVersion}" />
    <link rel="icon" type="image/x-icon" sizes="any" href="${assetOrigin}/favicon.ico?v=${iconVersion}" />
    <link rel="icon" type="image/png" sizes="32x32" href="${assetOrigin}/favicon-32x32.png?v=${iconVersion}" />
    <link rel="icon" type="image/png" sizes="192x192" href="${assetOrigin}/favicon-192x192.png?v=${iconVersion}" />
    <link rel="icon" type="image/png" sizes="512x512" href="${assetOrigin}/favicon-512x512.png?v=${iconVersion}" />
    <link rel="shortcut icon" href="${assetOrigin}/favicon.ico?v=${iconVersion}" />
    <meta property="og:type" content="${ogType}" />
    <meta property="og:site_name" content="${escapeHTML(brandedAppName)}" />
    <meta property="og:locale" content="zh_CN" />
    <meta property="og:title" content="${escapeHTML(metaTitle)}" />
    <meta property="og:description" content="${escapeHTML(metaDescription)}" />
    <meta property="og:url" content="${escapeHTML(canonicalURL)}" />
    ${imageTags}
    <meta name="twitter:card" content="${twitterCardType}" />
    <meta name="twitter:title" content="${escapeHTML(metaTitle)}" />
    <meta name="twitter:description" content="${escapeHTML(metaDescription)}" />
    ${appLinkTags}
    <style>
${pageStyles}
    </style>
  </head>
  <body>
    <div class="page">${body}</div>
  </body>
</html>`;
}

function inferModuleFromCanonicalURL(canonicalURL) {
  try {
    const url = new URL(canonicalURL);
    const match = url.pathname.match(/^\/posts\/([^/]+)\//);
    return match?.[1]?.toLowerCase() || "";
  } catch {
    return "";
  }
}

function buildMetaTitle({ title, module, brandedAppName }) {
  const cleanTitle = String(title || "").trim();
  const prefix = {
    secondhand: "Cheese二手",
    forum: "Cheese论坛"
  }[module] || brandedAppName;

  if (!cleanTitle) {
    return prefix;
  }

  return cleanTitle.startsWith(prefix) ? cleanTitle : `${prefix} | ${cleanTitle}`;
}

function buildMetaDescription({ description, brandedAppName }) {
  const cleanDescription = String(description || "").trim();
  if (!cleanDescription) {
    return `来自 ${brandedAppName} 的内容分享`;
  }

  return cleanDescription.includes(brandedAppName)
    ? cleanDescription
    : `${cleanDescription} · 来自 ${brandedAppName}`;
}

function inferImageType(previewImageURL) {
  const rawURL = String(previewImageURL || "").trim();
  let path = rawURL.toLowerCase();
  try {
    path = new URL(rawURL).pathname.toLowerCase();
  } catch {}

  if (path.endsWith(".png")) return "image/png";
  if (path.endsWith(".jpg") || path.endsWith(".jpeg")) return "image/jpeg";
  if (path.endsWith(".webp")) return "image/webp";
  if (path.endsWith(".svg")) return "image/svg+xml";
  return "image/jpeg";
}

function inferAssetOrigin(canonicalURL) {
  try {
    return new URL(canonicalURL).origin;
  } catch {
    return "https://cheeseapp.org";
  }
}
