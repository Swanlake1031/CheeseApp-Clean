import assert from "node:assert/strict";
import test from "node:test";
import { SupabasePostImageLoader } from "../src/ai/postImageLoader";
import type { PostImageRecord } from "../src/types";

function image(overrides: Partial<PostImageRecord> = {}): PostImageRecord {
  return {
    id: "00000000-0000-4000-8000-000000000010",
    post_id: "00000000-0000-4000-8000-000000000011",
    url: "https://example.supabase.co/storage/v1/object/public/post-images/posts/photo.jpg",
    bucket: null,
    object_path: null,
    order_index: 0,
    ...overrides,
  };
}

test("loads supported images only from the configured public post bucket", async () => {
  const requested: string[] = [];
  let redirect: RequestRedirect | undefined;
  const fetcher: typeof fetch = async (input, init) => {
    requested.push(String(input));
    redirect = init?.redirect;
    return new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), {
      headers: { "Content-Type": "image/jpeg", "Content-Length": "4" },
    });
  };
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    fetcher,
  );

  assert.deepEqual(await loader.load([image()]), [
    { mimeType: "image/jpeg", data: "/9j/2Q==" },
  ]);
  assert.equal(requested.length, 1);
  assert.equal(redirect, "manual");
});

test("redirects are rejected without following them", async () => {
  let redirect: RequestRedirect | undefined;
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    (async (_input, init) => {
      redirect = init?.redirect;
      return new Response(null, {
        status: 302,
        headers: { Location: "https://attacker.example/photo.jpg" },
      });
    }) as typeof fetch,
  );

  assert.deepEqual(await loader.load([image()]), []);
  assert.equal(redirect, "manual");
});

test("foreign URLs, wrong buckets, and path traversal are skipped", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => {
    calls += 1;
    return new Response("not an image", {
      headers: { "Content-Type": "text/plain" },
    });
  };
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    fetcher,
  );

  assert.deepEqual(
    await loader.load([
      image({ url: "https://attacker.example/photo.jpg" }),
      image({ bucket: "avatars", object_path: "photo.jpg" }),
      image({ bucket: "post-images", object_path: "../../avatars/photo.jpg" }),
    ]),
    [],
  );
  assert.equal(calls, 0);
});

test("unsupported content types are skipped", async () => {
  let calls = 0;
  const fetcher: typeof fetch = async () => {
    calls += 1;
    return new Response("not an image", {
      headers: { "Content-Type": "text/plain" },
    });
  };
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    fetcher,
  );

  assert.deepEqual(await loader.load([image()]), []);
  assert.equal(calls, 1);
});

test("content type must match the actual image signature", async () => {
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    (async () =>
      new Response(new TextEncoder().encode("not-a-jpeg"), {
        headers: { "Content-Type": "image/jpeg" },
      })) as typeof fetch,
  );

  assert.deepEqual(await loader.load([image()]), []);
});

test("a failed image fetch does not block another valid image", async () => {
  let calls = 0;
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    (async () => {
      calls += 1;
      if (calls === 1) throw new TypeError("network failure");
      return new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), {
        headers: { "Content-Type": "image/jpeg" },
      });
    }) as typeof fetch,
  );

  assert.deepEqual(
    await loader.load([
      image(),
      image({
        id: "00000000-0000-4000-8000-000000000020",
        url: "https://example.supabase.co/storage/v1/object/public/post-images/posts/second.jpg",
      }),
    ]),
    [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
  );
  assert.equal(calls, 2);
});

test("an oversized image is ignored without blocking the text reply", async () => {
  const fetcher: typeof fetch = async () =>
    new Response(new Uint8Array([1]), {
      headers: {
        "Content-Type": "image/png",
        "Content-Length": String(4 * 1024 * 1024 + 1),
      },
    });
  const loader = new SupabasePostImageLoader(
    "https://example.supabase.co",
    fetcher,
  );

  assert.deepEqual(await loader.load([image()]), []);
});
