import { normalizeText } from "./format.js";

export const SUPPORTED_KINDS = ["secondhand", "forum"];
export const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isWWWHost(url, config) {
  return url.hostname.toLowerCase() === `www.${config.canonicalHost}`;
}

export function redirectToCanonicalHost(url, config) {
  const target = new URL(url.toString());
  target.hostname = config.canonicalHost;
  return Response.redirect(target.toString(), 301);
}

export function isAASAPath(pathname) {
  return (
    pathname === "/apple-app-site-association" ||
    pathname === "/.well-known/apple-app-site-association"
  );
}

export function isDownloadPath(pathname) {
  return pathname === "/download";
}

export function matchOpenPath(pathname) {
  const match = pathname.match(/^\/open\/([^/]+)\/([^/]+)$/);
  if (!match) {
    return null;
  }

  const [, rawKind, rawPostID] = match;
  const kind = rawKind.toLowerCase();
  if (!SUPPORTED_KINDS.includes(kind)) {
    return null;
  }

  if (!UUID_PATTERN.test(rawPostID)) {
    return null;
  }

  return {
    kind,
    postID: rawPostID.toLowerCase()
  };
}

export function isFallbackPreviewImagePath(pathname) {
  return pathname === "/og/default.png";
}

export function matchCanonicalPostPath(pathname) {
  const match = pathname.match(/^\/posts\/([^/]+)\/([^/]+)$/);
  if (!match) {
    return null;
  }

  const [, rawKind, rawPostID] = match;
  const kind = rawKind.toLowerCase();
  if (!SUPPORTED_KINDS.includes(kind)) {
    return null;
  }

  if (!UUID_PATTERN.test(rawPostID)) {
    return null;
  }

  return {
    kind,
    postID: rawPostID.toLowerCase()
  };
}

export function matchPreviewImagePath(pathname) {
  const match = pathname.match(/^\/og\/([^/]+)\/([^/]+)\.svg$/);
  if (!match) {
    return null;
  }

  const [, rawKind, rawPostID] = match;
  const kind = rawKind.toLowerCase();
  if (!SUPPORTED_KINDS.includes(kind)) {
    return null;
  }

  if (!UUID_PATTERN.test(rawPostID)) {
    return null;
  }

  return {
    kind,
    postID: rawPostID.toLowerCase()
  };
}

export function buildPreviewImageURL(config, kind, postID, preferredImageURL = "") {
  const normalizedImageURL = normalizeText(preferredImageURL);
  if (/^https:\/\//i.test(normalizedImageURL)) {
    return normalizedImageURL;
  }

  return `https://${config.canonicalHost}/og/default.png?v=20260802`;
}

export function buildDownloadPageURL({ config, kind = "", postID = "", target = "" }) {
  const normalizedKind = normalizeKind(kind);
  const normalizedPostID = normalizePostID(postID);
  const normalizedTarget = normalizeGateTarget(target);

  if (normalizedKind && normalizedPostID) {
    const postURL = new URL(
      `https://${config.canonicalHost}/posts/${normalizedKind}/${normalizedPostID}`
    );
    if (normalizedTarget) {
      postURL.searchParams.set("target", normalizedTarget);
    }
    return postURL.toString();
  }

  const url = new URL(`https://${config.canonicalHost}/download`);
  if (normalizedTarget) {
    url.searchParams.set("target", normalizedTarget);
  }
  return url.toString();
}

export function buildOpenPageURL({ config, kind = "", postID = "" }) {
  const normalizedKind = normalizeKind(kind);
  const normalizedPostID = normalizePostID(postID);

  if (!normalizedKind || !normalizedPostID) {
    return `https://${config.canonicalHost}/`;
  }

  return `https://${config.canonicalHost}/open/${normalizedKind}/${normalizedPostID}`;
}

export function normalizeKind(value) {
  const kind = normalizeText(value).toLowerCase();
  return SUPPORTED_KINDS.includes(kind) ? kind : "";
}

export function normalizePostID(value) {
  const postID = normalizeText(value).toLowerCase();
  return UUID_PATTERN.test(postID) ? postID : "";
}

export function normalizeGateTarget(value) {
  const target = normalizeText(value).toLowerCase();
  return target === "profile" || target === "content" ? target : "";
}
