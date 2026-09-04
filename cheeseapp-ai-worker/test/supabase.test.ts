import assert from "node:assert/strict";
import test from "node:test";
import { SupabaseRepository, SupabaseRequestError } from "../src/supabase";

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

test("invalid Supabase access token is rejected as authentication failure", async () => {
  const repository = new SupabaseRepository(
    "https://example.supabase.co",
    "sb_secret_example",
    (async () => new Response("invalid JWT", { status: 401 })) as typeof fetch,
  );

  await assert.rejects(
    repository.authenticate("invalid-token"),
    (error: unknown) =>
      error instanceof SupabaseRequestError &&
      error.status === 401 &&
      error.category === "auth_validation_failed",
  );
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

test("secondhand image lookup is owner and staged-media scoped", async () => {
  const requests: Request[] = [];
  const repository = new SupabaseRepository(
    "https://example.supabase.co",
    "sb_secret_example",
    recordingFetcher(requests),
  );
  const owner = "11111111-1111-4111-8111-111111111111";
  const path = `${owner}/posts/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/000.jpg`;

  await repository.getOwnedSecondhandImages(owner, [
    { bucket: "post-images", object_path: path },
  ]);

  const url = requests[0]?.url ?? "";
  assert.match(url, /post_media_staging/);
  assert.match(url, /owner_id=eq\./);
  assert.match(url, /post_type=eq\.secondhand/);
  assert.match(url, /bucket=eq\.post-images/);
  assert.match(url, /status=in\.\(uploaded,finalized\)/);
});
