import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

import { pageShell } from "../src/ui/shell.js";
import { renderForumDetailPage } from "../src/pages/forum.js";
import { renderGenericPostPage } from "../src/pages/post.js";
import { renderSecondhandDetailPage } from "../src/pages/secondhand.js";
import { fetchSecondhandMetadata } from "../src/data/secondhand.js";
import { buildPreviewImageURL } from "../src/utils/routes.js";

const publicRoot = new URL("../public/", import.meta.url);

function pngDimensions(buffer) {
  assert.equal(buffer.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20)
  };
}

test("share pages expose the complete versioned Cheese metadata set", () => {
  const html = pageShell({
    title: "Forum post",
    description: "Shared from Cheese",
    canonicalURL:
      "https://cheeseapp.org/posts/forum/c0ffee00-0000-0000-0000-000000000101",
    previewImageURL: "https://cheeseapp.org/og/default.png?v=20260802",
    body: "<main>Cheese</main>"
  });

  assert.match(html, /manifest\.webmanifest\?v=20260802/);
  assert.match(html, /apple-touch-icon\.png\?v=20260802/);
  assert.match(html, /favicon\.ico\?v=20260802/);
  assert.match(html, /favicon-32x32\.png\?v=20260802/);
  assert.match(html, /favicon-192x192\.png\?v=20260802/);
  assert.match(html, /favicon-512x512\.png\?v=20260802/);
  assert.match(html, /property="og:image" content="https:\/\/cheeseapp\.org\/og\/default\.png\?v=20260802"/);
  assert.match(html, /name="twitter:image" content="https:\/\/cheeseapp\.org\/og\/default\.png\?v=20260802"/);
  assert.doesNotMatch(html, /data:image\/svg\+xml/);
});

test("fallback previews and every icon use the current Cheese assets", async () => {
  const expectedPNGs = [
    ["apple-touch-icon.png", 180, 180],
    ["favicon-32x32.png", 32, 32],
    ["favicon-192x192.png", 192, 192],
    ["favicon-512x512.png", 512, 512],
    ["og/default.png", 1200, 630]
  ];

  for (const [filename, width, height] of expectedPNGs) {
    const image = await readFile(new URL(filename, publicRoot));
    assert.deepEqual(pngDimensions(image), { width, height });
  }

  const ico = await readFile(new URL("favicon.ico", publicRoot));
  assert.equal(ico.subarray(0, 4).toString("hex"), "00000100");

  const manifest = JSON.parse(
    await readFile(new URL("manifest.webmanifest", publicRoot), "utf8")
  );
  assert.deepEqual(
    manifest.icons.map(({ src, sizes, type }) => ({ src, sizes, type })),
    [
      {
        src: "/favicon-192x192.png?v=20260802",
        sizes: "192x192",
        type: "image/png"
      },
      {
        src: "/favicon-512x512.png?v=20260802",
        sizes: "512x512",
        type: "image/png"
      }
    ]
  );

  await access(new URL("apple-touch-icon.png", publicRoot));
  assert.equal(
    buildPreviewImageURL(
      { canonicalHost: "cheeseapp.org" },
      "forum",
      "c0ffee00-0000-0000-0000-000000000101"
    ),
    "https://cheeseapp.org/og/default.png?v=20260802"
  );
});

test("open routes retain full forum and secondhand web pages with WeChat guidance", () => {
  const config = {
    canonicalHost: "cheeseapp.org",
    appScheme: "cheeseapp://post",
    appDownloadURL: "https://cheeseapp.org/",
    siteName: "Cheese"
  };
  const postID = "c0ffee00-0000-0000-0000-000000000101";
  const previewImageURL = "https://cdn.example.com/weather.jpg";
  const pages = [
    renderForumDetailPage({
      config,
      postID,
      previewImageURL,
      showOpenGuidance: true,
      metadata: {
        status: "ok",
        title: "天气不错",
        description: "闲聊 · 嘿嘿 · 来自 Cheese App",
        bodyText: "嘿嘿",
        boardLabel: "闲聊",
        imageURLs: [previewImageURL]
      }
    }),
    renderSecondhandDetailPage({
      config,
      postID,
      previewImageURL,
      detailImageURL: previewImageURL,
      showOpenGuidance: true,
      metadata: {
        status: "ok",
        title: "空气炸锅",
        description: "CAD 40 · 良好 · 来自 Cheese App",
        bodyText: "正常使用",
        priceText: "CAD 40",
        conditionLabel: "良好",
        categoryLabel: "家居家电"
      }
    })
  ];

  for (const html of pages) {
    assert.match(html, /class="wechat-intercept-alert"/);
    assert.match(html, /如果你正在使用微信/);
    assert.match(html, /请点击右上角「···」/);
    assert.match(html, /选择「在浏览器中打开」/);
    assert.doesNotMatch(html, /MicroMessenger|正在尝试|等待微信|正在请求微信/);
    assert.match(html, /class="market-detail-page"/);
    assert.match(html, /cheeseapp:\/\/post\//);
    assert.match(
      html,
      /<meta property="og:image" content="https:\/\/cdn\.example\.com\/weather\.jpg" \/>/
    );
  }
});

test("public fallback pages never display the internal post identifier", () => {
  const html = renderGenericPostPage({
    config: {
      canonicalHost: "cheeseapp.org",
      appScheme: "cheeseapp://post",
      siteName: "Cheese"
    },
    kind: "forum",
    postID: "c0ffee00-0000-0000-0000-000000000101",
    metadata: {
      status: "unavailable",
      title: "Cheese 论坛帖子",
      description: "帖子暂时不可用"
    },
    previewImageURL: ""
  });

  assert.doesNotMatch(html, /帖子 ID|Post ID/i);
  assert.doesNotMatch(
    html,
    /<code>c0ffee00-0000-0000-0000-000000000101<\/code>/
  );
});

test("secondhand shares use the narrow public RPC instead of the protected view", async () => {
  let request;

  await fetchSecondhandMetadata({
    postID: "77700000-0000-4000-8000-000000000001",
    config: {},
    fetchSingleRow: async (value) => {
      request = value;
      return null;
    },
    firstImageURL: () => "",
    fallbackDescription: () => "",
    fallbackTitle: () => "",
    unavailableMetadata: () => ({ status: "unavailable" })
  });

  assert.equal(request.table, "rpc/get_public_secondhand_share_post");
  assert.equal(request.idParameter, "p_post_id");
  assert.doesNotMatch(request.table, /secondhand_posts_view/);
});
