import assert from "node:assert/strict";
import test from "node:test";
import {
  CHEESE_AI_MAX_OUTPUT_TOKENS,
  CHEESE_AI_MODEL,
  SECONDHAND_DESCRIPTION_MAX_OUTPUT_TOKENS,
} from "../src/config";
import {
  GeminiCheeseAIProvider,
  GeminiProviderError,
} from "../src/ai/geminiProvider";

function successResponse(
  text = "可以选，但先看课程大纲和评分方式。具体以学校官网为准。",
  finishReason = "STOP",
): Response {
  return Response.json({
    candidates: [
      {
        content: {
          parts: [
            { thought: true, text: "private thought" },
            { text },
          ],
        },
        finishReason,
      },
    ],
    usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 8 },
  });
}

test("Gemini request uses the exact centralized model and minimal thinking", async () => {
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const fetcher: typeof fetch = async (input, init) => {
    capturedUrl = String(input);
    capturedInit = init;
    return successResponse();
  };
  const provider = new GeminiCheeseAIProvider("secret", fetcher);
  const result = await provider.generateCommunityReply({
    systemPrompt: "system",
    threadContext: "context",
    images: [{ mimeType: "image/jpeg", data: "aGVsbG8=" }],
  });

  assert.match(capturedUrl, new RegExp(`${CHEESE_AI_MODEL}:generateContent$`));
  const body = JSON.parse(String(capturedInit?.body)) as {
    generationConfig: Record<string, unknown>;
    contents: Array<{ parts: Array<Record<string, unknown>> }>;
  };
  assert.deepEqual(body.generationConfig, {
    thinkingConfig: { thinkingLevel: "minimal" },
    maxOutputTokens: CHEESE_AI_MAX_OUTPUT_TOKENS,
  });
  assert.equal("temperature" in body.generationConfig, false);
  assert.deepEqual(body.contents[0]?.parts[1], {
    inlineData: { mimeType: "image/jpeg", data: "aGVsbG8=" },
  });
  assert.doesNotMatch(result.text, /private thought/);
  assert.equal(result.inputTokenCount, 12);
});

test("secondhand generation uses its own output contract and normalizes one paragraph", async () => {
  let capturedInit: RequestInit | undefined;
  const provider = new GeminiCheeseAIProvider(
    "secret",
    (async (_input, init) => {
      capturedInit = init;
      return successResponse("“外观简洁，适合日常使用。\n照片所示物品为准。”");
    }) as typeof fetch,
  );
  const result = await provider.generateSecondhandDescription({
    systemPrompt: "secondhand-system",
    threadContext: "locale: zh-Hans",
    images: [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
  });
  const body = JSON.parse(String(capturedInit?.body)) as {
    generationConfig: {
      maxOutputTokens: number;
      thinkingConfig: { thinkingLevel: string };
    };
    system_instruction: { parts: Array<{ text: string }> };
    contents: Array<{ parts: Array<Record<string, unknown>> }>;
  };
  assert.equal(
    body.generationConfig.maxOutputTokens,
    SECONDHAND_DESCRIPTION_MAX_OUTPUT_TOKENS,
  );
  assert.equal(body.system_instruction.parts[0]?.text, "secondhand-system");
  assert.deepEqual(body.contents[0]?.parts[0], {
    inlineData: { mimeType: "image/jpeg", data: "/9j/2Q==" },
  });
  assert.deepEqual(body.contents[0]?.parts[1], { text: "locale: zh-Hans" });
  assert.equal(body.generationConfig.thinkingConfig.thinkingLevel, "medium");
  assert.equal(result.text, "外观简洁，适合日常使用。 照片所示物品为准。");
});

test("secondhand generation rejects empty and list-shaped output", async () => {
  for (const output of ["", "- 第一项\n- 第二项"]) {
    const provider = new GeminiCheeseAIProvider(
      "secret",
      (async () => successResponse(output)) as typeof fetch,
    );
    await assert.rejects(
      provider.generateSecondhandDescription({
        systemPrompt: "s",
        threadContext: "c",
        images: [],
      }),
      (error: unknown) =>
        error instanceof GeminiProviderError &&
        (error.category === "empty_output" || error.category === "invalid_output"),
    );
  }
});

test("MAX_TOKENS partial output is retried once and never returned", async () => {
  let calls = 0;
  const provider = new GeminiCheeseAIProvider(
    "secret",
    (async () => {
      calls += 1;
      return successResponse("平时爱惜得比较", "MAX_TOKENS");
    }) as typeof fetch,
  );

  await assert.rejects(
    provider.generateSecondhandDescription({
      systemPrompt: "s",
      threadContext: "c",
      images: [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
    }),
    (error: unknown) =>
      error instanceof GeminiProviderError &&
      error.category === "incomplete_output" &&
      error.retryable,
  );
  assert.equal(calls, 2);
});

test("natural seller copy without terminal punctuation is accepted on STOP", async () => {
  const provider = new GeminiCheeseAIProvider(
    "secret",
    (async () => successResponse("诚心要可以小刀", "STOP")) as typeof fetch,
  );

  const result = await provider.generateSecondhandDescription({
    systemPrompt: "s",
    threadContext: "c",
    images: [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
  });
  assert.equal(result.text, "诚心要可以小刀");
});

test("429 and 5xx are retried exactly once and then fail cleanly", async () => {
  for (const status of [429, 503]) {
    let calls = 0;
    const fetcher: typeof fetch = async () => {
      calls += 1;
      return new Response("upstream", { status });
    };
    const provider = new GeminiCheeseAIProvider("secret", fetcher);
    await assert.rejects(
      provider.generateCommunityReply({
        systemPrompt: "system",
        threadContext: "context",
        images: [],
      }),
      (error: unknown) => error instanceof GeminiProviderError,
    );
    assert.equal(calls, 2);
  }
});

test("provider timeout is retried exactly once and remains a timeout", async () => {
  let calls = 0;
  const provider = new GeminiCheeseAIProvider(
    "secret",
    (async () => {
      calls += 1;
      throw new DOMException("timed out", "TimeoutError");
    }) as typeof fetch,
  );
  await assert.rejects(
    provider.generateSecondhandDescription({
      systemPrompt: "s",
      threadContext: "c",
      images: [{ mimeType: "image/jpeg", data: "/9j/2Q==" }],
    }),
    (error: unknown) =>
      error instanceof GeminiProviderError &&
      error.category === "provider_timeout" &&
      error.retryable,
  );
  assert.equal(calls, 2);
});

test("missing key, safety block, and empty output fail without a fabricated reply", async () => {
  const missing = new GeminiCheeseAIProvider("");
  await assert.rejects(
    missing.generateCommunityReply({ systemPrompt: "s", threadContext: "c", images: [] }),
    (error: unknown) =>
      error instanceof GeminiProviderError &&
      error.category === "missing_api_key",
  );

  const blocked = new GeminiCheeseAIProvider(
    "secret",
    (async () =>
      Response.json({ promptFeedback: { blockReason: "SAFETY" } })) as typeof fetch,
  );
  await assert.rejects(
    blocked.generateCommunityReply({ systemPrompt: "s", threadContext: "c", images: [] }),
    (error: unknown) =>
      error instanceof GeminiProviderError &&
      error.category === "safety_blocked",
  );

  const empty = new GeminiCheeseAIProvider(
    "secret",
    (async () => successResponse("")) as typeof fetch,
  );
  await assert.rejects(
    empty.generateCommunityReply({ systemPrompt: "s", threadContext: "c", images: [] }),
    (error: unknown) =>
      error instanceof GeminiProviderError && error.category === "empty_output",
  );
});
