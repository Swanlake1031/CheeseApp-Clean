import assert from "node:assert/strict";
import test from "node:test";

import { processSecondhandLifecycle } from "../src/secondhand/lifecycle.js";

test("skips safely without service-role credentials", async () => {
  const result = await processSecondhandLifecycle({
    config: { supabaseServiceRoleKey: "" },
    fetchImpl: async () => {
      throw new Error("network should not be called");
    }
  });

  assert.equal(result.skipped, "missing_service_role");
  assert.equal(result.remindersCreated, 0);
  assert.equal(result.listingsInactivated, 0);
});

test("calls the bounded lifecycle RPC with service-role auth", async () => {
  const requests = [];
  const result = await processSecondhandLifecycle({
    config: {
      supabaseURL: "https://example.supabase.co/",
      supabaseServiceRoleKey: "local-test-secret"
    },
    batchLimit: 1000,
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return new Response(
        JSON.stringify([{
          reminders_created: 4,
          listings_inactivated: 2
        }]),
        { status: 200 }
      );
    }
  });

  assert.equal(requests.length, 1);
  assert.equal(
    requests[0].url,
    "https://example.supabase.co/rest/v1/rpc/process_secondhand_availability_lifecycle"
  );
  assert.deepEqual(JSON.parse(requests[0].init.body), { p_limit: 100 });
  assert.equal(requests[0].init.headers.authorization, "Bearer local-test-secret");
  assert.deepEqual(result, {
    skipped: null,
    remindersCreated: 4,
    listingsInactivated: 2
  });
});

test("surfaces RPC failures with an observable safe code", async () => {
  await assert.rejects(
    processSecondhandLifecycle({
      config: {
        supabaseURL: "https://example.supabase.co",
        supabaseServiceRoleKey: "local-test-secret"
      },
      fetchImpl: async () => new Response("failure", { status: 503 })
    }),
    (error) => error.code === "secondhand_lifecycle_http_503"
  );
});
