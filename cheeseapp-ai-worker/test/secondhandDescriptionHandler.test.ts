import assert from "node:assert/strict";
import test from "node:test";
import { SupabaseRequestError } from "../src/supabase";
import {
  parseSecondhandDescriptionRequest,
  SecondhandDescriptionError,
  SecondhandDescriptionHandler,
  type SecondhandDescriptionRepository,
} from "../src/ai/secondhandDescriptionHandler";
import type {
  CheeseAIImage,
  CheeseAIInput,
  CheeseAIResult,
  PostImageRecord,
  SecondhandDescriptionProvider,
  SecondhandImageReference,
} from "../src/types";

const owner = "11111111-1111-4111-8111-111111111111";
const post = "22222222-2222-4222-8222-222222222222";
const operation = "33333333-3333-4333-8333-333333333333";
const objectPath = `${owner}/posts/${post}/${operation}/000.jpg`;

function request() {
  return parseSecondhandDescriptionRequest({
    images: [{ bucket: "post-images", object_path: objectPath }],
    title: "台灯",
    category: "家居",
    condition: "良好",
    price: 12,
    is_negotiable: true,
    locale: "zh-Hans",
  });
}

function record(reference: SecondhandImageReference): PostImageRecord {
  return {
    id: "44444444-4444-4444-8444-444444444444",
    post_id: post,
    url: `https://example.supabase.co/storage/v1/object/public/post-images/${reference.object_path}`,
    bucket: reference.bucket,
    object_path: reference.object_path,
    order_index: 0,
  };
}

class Repository implements SecondhandDescriptionRepository {
  consent = true;
  async hasAIConsent(): Promise<boolean> { return this.consent; }
  authenticateCalls = 0;
  failAuthentication = false;
  omitOwnedImage = false;

  async authenticate(): Promise<{ id: string }> {
    this.authenticateCalls += 1;
    if (this.failAuthentication) {
      throw new SupabaseRequestError(401, "auth_validation_failed");
    }
    return { id: owner };
  }

  async getOwnedSecondhandImages(
    _ownerId: string,
    references: readonly SecondhandImageReference[],
  ): Promise<readonly PostImageRecord[]> {
    return this.omitOwnedImage ? [] : references.map(record);
  }
}

class Provider implements SecondhandDescriptionProvider {
  calls = 0;
  input: CheeseAIInput | undefined;

  async generateSecondhandDescription(input: CheeseAIInput): Promise<CheeseAIResult> {
    this.calls += 1;
    this.input = input;
    return {
      text: "外观简洁，适合书桌日常使用，具体状态以图片所示为准。",
      inputTokenCount: 10,
      outputTokenCount: 8,
      finishReason: "STOP",
      latencyMs: 20,
    };
  }
}

function makeHandler(options: {
  repository?: Repository;
  rateAllowed?: boolean;
  images?: readonly CheeseAIImage[];
  provider?: Provider;
} = {}) {
  const repository = options.repository ?? new Repository();
  const provider = options.provider ?? new Provider();
  return {
    repository,
    provider,
    handler: new SecondhandDescriptionHandler(
      repository,
      { limit: async () => ({ success: options.rateAllowed ?? true }) },
      { load: async () => options.images ?? [{ mimeType: "image/jpeg", data: "/9j/2Q==" }] },
      provider,
    ),
  };
}

test("parser requires one to three exact staged post-images references", () => {
  for (const value of [
    { images: [], locale: "zh-Hans" },
    { images: [{ bucket: "avatars", object_path: objectPath }], locale: "zh-Hans" },
    { images: [{ bucket: "post-images", object_path: "https://attacker.example/x.jpg" }], locale: "zh-Hans" },
    { images: [{ bucket: "post-images", object_path: `${owner}/posts/../x.jpg` }], locale: "zh-Hans" },
  ]) {
    assert.throws(
      () => parseSecondhandDescriptionRequest(value),
      (error: unknown) => error instanceof SecondhandDescriptionError,
    );
  }
});

test("parser requires title, price, and images", () => {
  const image = { bucket: "post-images", object_path: objectPath };
  for (const [value, category] of [
    [{ images: [image], price: 12, locale: "zh-Hans" }, "title_required"],
    [{ images: [image], title: "台灯", locale: "zh-Hans" }, "price_required"],
    [{ images: [], title: "台灯", price: 12, locale: "zh-Hans" }, "images_required"],
  ] as const) {
    assert.throws(
      () => parseSecondhandDescriptionRequest(value),
      (error: unknown) =>
        error instanceof SecondhandDescriptionError &&
        error.category === category,
    );
  }
});

test("authenticated owner can generate with structured context and images", async () => {
  const { handler, provider } = makeHandler();
  const result = await handler.generate("valid-jwt", request());
  assert.match(result.description, /外观简洁/);
  assert.equal(result.imageCount, 1);
  assert.equal(result.finishReason, "STOP");
  assert.equal(provider.calls, 1);
  assert.match(provider.input?.threadContext ?? "", /用户填写的商品名称：台灯/);
  assert.match(provider.input?.threadContext ?? "", /用户填写的售价（CAD）：12/);
  assert.match(provider.input?.threadContext ?? "", /是否接受议价：是/);
  assert.doesNotMatch(provider.input?.systemPrompt ?? "", /社区用户/);
  assert.match(provider.input?.systemPrompt ?? "", /高转化、接地气/);
  assert.match(provider.input?.systemPrompt ?? "", /至少一项来自照片中清楚可见的细节/);
});

test("invalid JWT, rate limiting, and ownership mismatch stop before Gemini", async () => {
  const invalidAuth = new Repository();
  invalidAuth.failAuthentication = true;
  const invalid = makeHandler({ repository: invalidAuth });
  await assert.rejects(
    invalid.handler.generate("bad-jwt", request()),
    (error: unknown) => error instanceof SupabaseRequestError && error.status === 401,
  );
  assert.equal(invalid.provider.calls, 0);

  const limited = makeHandler({ rateAllowed: false });
  await assert.rejects(
    limited.handler.generate("jwt", request()),
    (error: unknown) => error instanceof SecondhandDescriptionError && error.status === 429,
  );
  assert.equal(limited.provider.calls, 0);

  const missing = new Repository();
  missing.omitOwnedImage = true;
  const unowned = makeHandler({ repository: missing });
  await assert.rejects(
    unowned.handler.generate("jwt", request()),
    (error: unknown) => error instanceof SecondhandDescriptionError && error.category === "image_not_owned",
  );
  assert.equal(unowned.provider.calls, 0);
});

test("partial image fetch succeeds, but zero valid images never calls Gemini", async () => {
  const partial = makeHandler({
    images: [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
  });
  assert.equal((await partial.handler.generate("jwt", request())).imageCount, 1);

  const empty = makeHandler({ images: [] });
  await assert.rejects(
    empty.handler.generate("jwt", request()),
    (error: unknown) => error instanceof SecondhandDescriptionError && error.category === "no_valid_images",
  );
  assert.equal(empty.provider.calls, 0);
});

test('description generation requires explicit account AI consent', async () => {
  const repository = new Repository(); repository.consent = false;
  const f = makeHandler({ repository });
  await assert.rejects(f.handler.generate('token', request()), /ai_consent_required/);
  assert.equal(f.provider.calls, 0);
});
