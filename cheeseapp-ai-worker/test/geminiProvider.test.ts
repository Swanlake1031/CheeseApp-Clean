import assert from "node:assert/strict";
import test from "node:test";
import {
  CHEESE_AI_MAX_OUTPUT_TOKENS,
  CHEESE_AI_MODEL,
} from "../src/config";
import {
  GeminiCheeseAIProvider,
  GeminiProviderError,
} from "../src/ai/geminiProvider";

function successResponse(
  text = "可以选，但先看课程大纲和评分方式。具体以学校官网为准。",
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
        finishReason: "STOP",
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
