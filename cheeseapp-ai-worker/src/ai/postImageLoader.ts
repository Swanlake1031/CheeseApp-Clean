import { runtimeFetch } from "../runtimeFetch";
import type { CheeseAIImage, PostImageRecord } from "../types";

const IMAGE_BUCKET = "post-images";
const MAX_IMAGES = 3;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES = 8 * 1024 * 1024;
const ALLOWED_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
]);

export interface CheeseAIImageLoader {
  load(images: readonly PostImageRecord[]): Promise<readonly CheeseAIImage[]>;
}

function encodePath(path: string): string {
  const segments = path.split("/").filter(Boolean);
  if (segments.some((segment) => segment === "." || segment === "..")) {
    return "";
  }
  return segments.map(encodeURIComponent).join("/");
}

function imageUrl(baseUrl: URL, image: PostImageRecord): URL | null {
  if (image.bucket !== null || image.object_path !== null) {
    if (image.bucket !== IMAGE_BUCKET || !image.object_path?.trim()) {
      return null;
    }
    const encodedPath = encodePath(image.object_path);
    if (!encodedPath) return null;
    return new URL(
      `/storage/v1/object/public/${IMAGE_BUCKET}/${encodedPath}`,
      baseUrl,
    );
  }

  try {
    const candidate = new URL(image.url);
    const publicPrefix = `/storage/v1/object/public/${IMAGE_BUCKET}/`;
    return candidate.protocol === "https:" &&
      candidate.origin === baseUrl.origin &&
      candidate.pathname.startsWith(publicPrefix)
      ? candidate
      : null;
  } catch {
    return null;
  }
}

async function readBounded(
  response: Response,
  remainingBytes: number,
): Promise<Uint8Array | null> {
  const limit = Math.min(MAX_IMAGE_BYTES, remainingBytes);
  const declared = Number(response.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > limit) return null;
  if (!response.body) return null;

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

export class SupabasePostImageLoader implements CheeseAIImageLoader {
  private readonly baseUrl: URL;

  constructor(
    supabaseUrl: string,
    private readonly fetcher: typeof fetch = runtimeFetch,
  ) {
    this.baseUrl = new URL(supabaseUrl);
  }

  async load(
    images: readonly PostImageRecord[],
  ): Promise<readonly CheeseAIImage[]> {
    const loaded: CheeseAIImage[] = [];
    let totalBytes = 0;

    for (const image of images.slice(0, MAX_IMAGES)) {
      const url = imageUrl(this.baseUrl, image);
      if (!url || totalBytes >= MAX_TOTAL_BYTES) continue;

      try {
        const response = await this.fetcher(url, {
          headers: { Accept: "image/jpeg,image/png,image/webp" },
          signal: AbortSignal.timeout(5_000),
        });
        const mimeType = response.headers
          .get("Content-Type")
          ?.split(";", 1)[0]
          ?.trim()
          .toLowerCase();
        if (!response.ok || !mimeType || !ALLOWED_MIME_TYPES.has(mimeType)) {
          continue;
        }
        const bytes = await readBounded(response, MAX_TOTAL_BYTES - totalBytes);
        if (!bytes || bytes.byteLength === 0) continue;
        totalBytes += bytes.byteLength;
        loaded.push({ mimeType, data: base64(bytes) });
      } catch {
        // Optional visual context must never suppress a text reply or leak a
        // storage URL into logs.
      }
    }

    return loaded;
  }
}
