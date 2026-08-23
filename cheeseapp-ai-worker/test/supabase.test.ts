import assert from "node:assert/strict";
import test from "node:test";
import { SupabaseRepository } from "../src/supabase";

function recordingFetcher(
  requests: Request[],
): typeof fetch {
  return async (input, init) => {
    requests.push(new Request(input, init));
    return Response.json([]);
  };
}

test("new Supabase secret keys are sent only as apikey", async () => {
  const requests: Request[] = [];
  const repository = new SupabaseRepository(
    "https://example.supabase.co",
    "sb_secret_example",
    recordingFetcher(requests),
  );

  await repository.pendingInteractionIds();

  assert.equal(requests.length, 1);
  assert.equal(requests[0]?.headers.get("apikey"), "sb_secret_example");
  assert.equal(requests[0]?.headers.get("Authorization"), null);
});

test("legacy service-role JWT remains the bearer credential", async () => {
  const requests: Request[] = [];
  const legacyKey = "eyJheader.payload.signature";
  const repository = new SupabaseRepository(
    "https://example.supabase.co",
    legacyKey,
    recordingFetcher(requests),
  );

  await repository.pendingInteractionIds();

  assert.equal(requests.length, 1);
  assert.equal(requests[0]?.headers.get("apikey"), legacyKey);
  assert.equal(
    requests[0]?.headers.get("Authorization"),
    `Bearer ${legacyKey}`,
  );
});
