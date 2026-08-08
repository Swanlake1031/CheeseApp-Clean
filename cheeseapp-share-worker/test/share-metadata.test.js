import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

import { pageShell } from "../src/ui/shell.js";
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
