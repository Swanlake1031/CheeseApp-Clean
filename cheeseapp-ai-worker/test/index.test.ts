import assert from "node:assert/strict";
import test from "node:test";
import { handleWorkerRequest } from "../src/index";
import type { Env } from "../src/types";

const context = {
  waitUntil() {},
  passThroughOnException() {},
} as unknown as ExecutionContext;

test("secondhand description endpoint rejects missing Authorization before configuration", async () => {
  const response = await handleWorkerRequest(
    new Request("https://ai.cheeseapp.org/v1/secondhand/generate-description", {
      method: "POST",
      body: JSON.stringify({ images: [] }),
    }),
    {} as Env,
    context,
  );
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: "unauthorized" });
});
