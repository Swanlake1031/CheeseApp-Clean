export function buildDescription(parts, fallback) {
  const text = parts
    .map((value) => normalizeText(value))
    .filter(Boolean)
    .join(" · ");

  if (!text) {
    return fallback;
  }

  return text.length > 180 ? `${text.slice(0, 177)}...` : text;
}

export function normalizeText(value) {
  if (value === null || value === undefined) return "";
  const text = String(value).trim();
  return text.length === 0 ? "" : text;
}

export function formatPriceCAD(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "";
  return `CAD ${Math.round(value) === value ? value.toFixed(0) : value.toFixed(2)}`;
}

export function localizeSecondhandCondition(condition) {
  switch (String(condition || "").toLowerCase()) {
    case "new":
      return "全新";
    case "like_new":
      return "99新";
    case "good":
      return "良好";
    case "fair":
      return "一般";
    case "poor":
      return "明显使用";
    default:
      return "";
  }
}

export function localizeNegotiable(value) {
  return value ? "可议价" : "不议价";
}

export function localizeSecondhandCategory(category) {
  switch (String(category || "").toLowerCase()) {
    case "electronics":
      return "电子产品";
    case "furniture":
      return "家具";
    case "clothing":
      return "服装";
    case "books":
      return "教材书籍";
    case "appliances":
      return "家电";
    case "sports":
      return "运动用品";
    case "beauty":
      return "美妆个护";
    case "other":
      return "其他";
    default:
      return "";
  }
}

export function kindDisplayLabel(kind) {
  switch (kind) {
    case "secondhand":
      return "二手";
    case "forum":
      return "论坛";
    default:
      return "帖子";
  }
}

export function kindEmoji(kind) {
  switch (kind) {
    case "secondhand":
      return "🛍️";
    case "forum":
      return "💬";
    default:
      return "🧀";
  }
}

export function kindPalette(kind) {
  switch (kind) {
    case "secondhand":
      return {
        start: "#FBF1E4",
        end: "#F0D8C1",
        glow: "#F4A261",
        glowFade: "rgba(244,162,97,0)",
        badge: "#F8DDBA",
        panel: "rgba(244, 162, 97, 0.22)"
      };
    case "forum":
      return {
        start: "#F1ECF7",
        end: "#DDD2EA",
        glow: "#CDB4DB",
        glowFade: "rgba(205,180,219,0)",
        badge: "#E8DCF1",
        panel: "rgba(205, 180, 219, 0.22)"
      };
    default:
      return {
        start: "#F7F1E7",
        end: "#E6DCCB",
        glow: "#F5C56B",
        glowFade: "rgba(245,197,107,0)",
        badge: "#F4E5C1",
        panel: "rgba(245, 197, 107, 0.22)"
      };
  }
}

export function formatISODateText(value) {
  const text = normalizeText(value);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return text;
  return text;
}

export function formatRelativeTimeText(value) {
  const text = normalizeText(value);
  if (!text) return "";

  const date = new Date(text);
  if (Number.isNaN(date.getTime())) {
    return text;
  }

  const diffMs = Date.now() - date.getTime();
  if (diffMs < 0) {
    return formatAbsoluteDateText(date);
  }

  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  const week = 7 * day;

  if (diffMs < hour) {
    const minutes = Math.max(1, Math.floor(diffMs / minute));
    return `${minutes} 分钟前`;
  }

  if (diffMs < day) {
    const hours = Math.floor(diffMs / hour);
    return `${hours} 小时前`;
  }

  if (diffMs < week) {
    const days = Math.floor(diffMs / day);
    return `${days} 天前`;
  }

  return formatAbsoluteDateText(date);
}

export function formatAbsoluteDateText(date) {
  try {
    return new Intl.DateTimeFormat("zh-Hans-CA", {
      year: "numeric",
      month: "numeric",
      day: "numeric"
    }).format(date);
  } catch {
    return date.toISOString().slice(0, 10);
  }
}

export function wrapPreviewText(text, maxCharsPerLine, maxLines) {
  const source = normalizeText(text);
  if (!source) {
    return [];
  }

  const lines = [];
  let cursor = 0;

  while (cursor < source.length && lines.length < maxLines) {
    const slice = source.slice(cursor, cursor + maxCharsPerLine);
    lines.push(slice);
    cursor += slice.length;
  }

  if (cursor < source.length && lines.length > 0) {
    const lastIndex = lines.length - 1;
    const trimmed = lines[lastIndex].slice(0, Math.max(maxCharsPerLine - 1, 0));
    lines[lastIndex] = `${trimmed}…`;
  }

  return lines;
}

export function truncateForPreview(text, maxLength) {
  const value = normalizeText(text);
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, Math.max(maxLength - 1, 0))}…`;
}

export function formatClockText(value) {
  const text = normalizeText(value);
  const match = text.match(/^(\d{2}:\d{2})(:\d{2})?$/);
  return match ? match[1] : text;
}

export function capitalize(value) {
  const text = normalizeText(value);
  return text ? `${text[0].toUpperCase()}${text.slice(1)}` : "";
}

export function fallbackTitle(kind) {
  switch (kind) {
    case "secondhand":
      return "Cheese 二手帖子";
    case "forum":
      return "Cheese 论坛帖子";
    default:
      return "Cheese 帖子";
  }
}

export function fallbackDescription(kind) {
  switch (kind) {
    case "secondhand":
      return "在 Cheese 中打开这篇二手帖子。";
    case "forum":
      return "在 Cheese 中打开这篇论坛帖子。";
    default:
      return "在 Cheese 中打开这篇帖子。";
  }
}

export function formatDateTimeText(value) {
  const text = normalizeText(value);
  if (!text) return "";

  const date = new Date(text);
  if (Number.isNaN(date.getTime())) {
    return text;
  }

  try {
    return new Intl.DateTimeFormat("zh-Hans-CA", {
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      hour12: true
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

export function formatForumStat(value, suffix) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "";
  return `${value} ${suffix}`;
}

export function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
