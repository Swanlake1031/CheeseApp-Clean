import type {
  AuthUser,
  PostImageRecord,
  SecondhandDescriptionProvider,
  SecondhandDescriptionRequest,
  SecondhandImageReference,
} from "../types";
import type { CheeseAIImageLoader } from "./postImageLoader";
import { SECONDHAND_DESCRIPTION_SYSTEM_PROMPT } from "./secondhandDescriptionPrompt";

const UUID =
  "[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const STAGED_OBJECT_PATH = new RegExp(
  `^${UUID}/posts/${UUID}/${UUID}/00[0-5]\\.jpg$`,
  "i",
);
const ALLOWED_KEYS = new Set([
  "images",
  "title",
  "category",
  "condition",
  "price",
  "is_negotiable",
  "locale",
]);

export class SecondhandDescriptionError extends Error {
  override readonly name = "SecondhandDescriptionError";

  constructor(
    readonly category: string,
    readonly status: number,
  ) {
    super(category);
  }
}

export interface SecondhandDescriptionRepository {
  authenticate(accessToken: string): Promise<AuthUser>;
  getOwnedSecondhandImages(
    ownerId: string,
    references: readonly SecondhandImageReference[],
  ): Promise<readonly PostImageRecord[]>;
}

export interface FeatureRateLimiter {
  limit(options: {
    readonly key: string;
  }): Promise<{ readonly success: boolean }>;
}

export interface SecondhandDescriptionResult {
  readonly description: string;
  readonly imageCount: number;
  readonly latencyMs: number;
  readonly inputTokenCount: number;
  readonly outputTokenCount: number;
  readonly finishReason: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalText(
  record: Record<string, unknown>,
  key: "title" | "category" | "condition",
  maximum: number,
): string | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string") {
    throw new SecondhandDescriptionError("invalid_request", 400);
  }
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > maximum || /[\u0000-\u001f\u007f]/u.test(trimmed)) {
    throw new SecondhandDescriptionError("invalid_request", 400);
  }
  return trimmed;
}

function parseImage(value: unknown): SecondhandImageReference {
  if (
    !isRecord(value) ||
    Object.keys(value).some(
      (key) => !["bucket", "object_path"].includes(key),
    )
  ) {
    throw new SecondhandDescriptionError("invalid_images", 400);
  }
  if (
    value.bucket !== "post-images" ||
    typeof value.object_path !== "string" ||
    !STAGED_OBJECT_PATH.test(value.object_path)
  ) {
    throw new SecondhandDescriptionError("invalid_images", 400);
  }
  return { bucket: "post-images", object_path: value.object_path };
}

export function parseSecondhandDescriptionRequest(
  value: unknown,
): SecondhandDescriptionRequest {
  if (
    !isRecord(value) ||
    Object.keys(value).some((key) => !ALLOWED_KEYS.has(key))
  ) {
    throw new SecondhandDescriptionError("invalid_request", 400);
  }
  if (
    !Array.isArray(value.images) ||
    value.images.length < 1 ||
    value.images.length > 3
  ) {
    throw new SecondhandDescriptionError("images_required", 400);
  }
  const images = value.images.map(parseImage);
  if (new Set(images.map((image) => image.object_path)).size !== images.length) {
    throw new SecondhandDescriptionError("invalid_images", 400);
  }
  if (value.locale !== "zh-Hans" && value.locale !== "en") {
    throw new SecondhandDescriptionError("invalid_locale", 400);
  }

  if (value.price === undefined) {
    throw new SecondhandDescriptionError("price_required", 400);
  }
  if (
    typeof value.price !== "number" ||
    !Number.isFinite(value.price) ||
    value.price < 0 ||
    value.price > 99_999_999.99
  ) {
    throw new SecondhandDescriptionError("invalid_price", 400);
  }

  const title = optionalText(value, "title", 120);
  if (!title) {
    throw new SecondhandDescriptionError("title_required", 400);
  }
  if (
    value.is_negotiable !== undefined &&
    typeof value.is_negotiable !== "boolean"
  ) {
    throw new SecondhandDescriptionError("invalid_request", 400);
  }
  const category = optionalText(value, "category", 60);
  const condition = optionalText(value, "condition", 60);
  return {
    images,
    title,
    price: value.price,
    is_negotiable: value.is_negotiable ?? false,
    locale: value.locale,
    ...(category ? { category } : {}),
    ...(condition ? { condition } : {}),
  };
}

function promptContext(request: SecondhandDescriptionRequest): string {
  const fields = [
    `输出语言：${request.locale}`,
    `用户填写的商品名称：${request.title}`,
    request.category ? `用户选择的分类：${request.category}` : null,
    request.condition ? `用户选择的成色：${request.condition}` : null,
    `用户填写的售价（CAD）：${request.price}`,
    `是否接受议价：${request.is_negotiable ? "是" : "否"}`,
    `有效图片数量：${request.images.length}`,
    "请严格只返回商品简介正文。",
  ].filter((line): line is string => line !== null);
  return fields.join("\n");
}

export class SecondhandDescriptionHandler {
  constructor(
    private readonly repository: SecondhandDescriptionRepository,
    private readonly rateLimiter: FeatureRateLimiter,
    private readonly imageLoader: CheeseAIImageLoader,
    private readonly provider: SecondhandDescriptionProvider,
  ) {}

  async generate(
    accessToken: string,
    request: SecondhandDescriptionRequest,
  ): Promise<SecondhandDescriptionResult> {
    if (request.images.length === 0) {
      throw new SecondhandDescriptionError("images_required", 400);
    }
    const user = await this.repository.authenticate(accessToken);
    const rate = await this.rateLimiter.limit({
      key: `secondhand-description:${user.id}`,
    });
    if (!rate.success) {
      throw new SecondhandDescriptionError("rate_limited", 429);
    }

    const records = await this.repository.getOwnedSecondhandImages(
      user.id,
      request.images,
    );
    const ownedPaths = new Set(records.map((record) => record.object_path));
    if (request.images.some((image) => !ownedPaths.has(image.object_path))) {
      throw new SecondhandDescriptionError("image_not_owned", 403);
    }

    const images = await this.imageLoader.load(records);
    if (images.length === 0) {
      throw new SecondhandDescriptionError("no_valid_images", 422);
    }
    const result = await this.provider.generateSecondhandDescription({
      systemPrompt: SECONDHAND_DESCRIPTION_SYSTEM_PROMPT,
      threadContext: promptContext({
        ...request,
        images: request.images.slice(0, images.length),
      }),
      images,
    });
    return {
      description: result.text,
      imageCount: images.length,
      latencyMs: result.latencyMs,
      inputTokenCount: result.inputTokenCount,
      outputTokenCount: result.outputTokenCount,
      finishReason: result.finishReason,
    };
  }
}
