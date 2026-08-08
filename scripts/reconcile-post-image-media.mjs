#!/usr/bin/env node

/**
 * Reconcile legacy URL-only post_images rows with real objects from the fixed
 * public post-images bucket.
 *
 * Safety properties:
 * - Storage is read-only; this tool never deletes or moves an object.
 * - Stored URLs are never split or parsed to derive an object name.
 * - Canonical public URLs are generated from real bucket/object identities.
 * - Only one unique exact canonical URL match is eligible for backfill.
 * - Default mode is dry-run. --apply only updates database metadata/audit rows.
 * - URLs are written to the requested report file, never printed to stdout.
 *
 * Required environment:
 *   CHEESE_RECONCILE_SUPABASE_URL
 *   CHEESE_RECONCILE_SERVICE_ROLE_KEY
 *
 * Usage:
 *   node scripts/reconcile-post-image-media.mjs \
 *     --output /secure/path/post-image-reconciliation.json
 *
 *   node scripts/reconcile-post-image-media.mjs \
 *     --apply \
 *     --output /secure/path/post-image-reconciliation-applied.json
 */

import { writeFile } from "node:fs/promises";
import process from "node:process";

const FIXED_BUCKET = "post-images";
const DEFAULT_PAGE_SIZE = 500;

function parseArguments(argv) {
  const options = {
    apply: false,
    output: null,
    pageSize: DEFAULT_PAGE_SIZE,
    selfTest: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--apply") {
      options.apply = true;
    } else if (argument === "--self-test") {
      options.selfTest = true;
    } else if (argument === "--output") {
      options.output = argv[index + 1] ?? null;
      index += 1;
    } else if (argument === "--page-size") {
      const value = Number.parseInt(argv[index + 1] ?? "", 10);
      if (!Number.isInteger(value) || value < 1 || value > 1_000) {
        throw new Error("--page-size must be between 1 and 1000");
      }
      options.pageSize = value;
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }

  return options;
}

function normalizeBaseURL(rawURL) {
  const parsed = new URL(rawURL);
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  parsed.search = "";
  parsed.hash = "";
  return parsed;
}

export function canonicalPublicURL(baseURL, bucket, objectPath) {
  const canonical = new URL(baseURL);
  canonical.pathname = [
    canonical.pathname.replace(/\/+$/, ""),
    "storage/v1/object/public",
    bucket,
    objectPath,
  ].join("/");
  canonical.search = "";
  canonical.hash = "";
  return canonical.href;
}

export function classifyLegacyRows(rows, objects, baseURL) {
  const candidatesByURL = new Map();

  for (const objectPath of objects) {
    const url = canonicalPublicURL(baseURL, FIXED_BUCKET, objectPath);
    const existing = candidatesByURL.get(url) ?? [];
    existing.push(objectPath);
    candidatesByURL.set(url, existing);
  }

  return rows.map((row) => {
    const candidates = candidatesByURL.get(row.url) ?? [];
    if (candidates.length === 1) {
      return {
        post_image_id: row.id,
        post_id: row.post_id,
        stored_url: row.url,
        reconciliation_status: "matched",
        reason: "unique_exact_canonical_url_match",
        candidate_count: 1,
        bucket: FIXED_BUCKET,
        object_path: candidates[0],
      };
    }

    return {
      post_image_id: row.id,
      post_id: row.post_id,
      stored_url: row.url,
      reconciliation_status: "unresolved",
      reason:
        candidates.length === 0
          ? "no_exact_canonical_url_match"
          : "multiple_exact_canonical_url_matches",
      candidate_count: candidates.length,
      bucket: null,
      object_path: null,
    };
  });
}

function makeHTTPClient(baseURL, serviceRoleKey) {
  return async function request(path, init = {}) {
    const response = await fetch(new URL(path, baseURL), {
      ...init,
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        accept: "application/json",
        "content-type": "application/json",
        ...(init.headers ?? {}),
      },
    });

    if (!response.ok) {
      const requestID = response.headers.get("x-request-id");
      const suffix = requestID ? ` request_id=${requestID}` : "";
      const error = new Error(
        `Supabase request failed with HTTP ${response.status}.${suffix}`,
      );
      error.status = response.status;
      throw error;
    }

    if (response.status === 204) {
      return { body: null, headers: response.headers };
    }

    return {
      body: await response.json(),
      headers: response.headers,
    };
  };
}

async function listBucketObjects(request, pageSize) {
  const objectPaths = [];
  const pendingPrefixes = [""];
  const visitedPrefixes = new Set();

  while (pendingPrefixes.length > 0) {
    const prefix = pendingPrefixes.shift();
    if (visitedPrefixes.has(prefix)) continue;
    visitedPrefixes.add(prefix);

    let offset = 0;
    while (true) {
      const { body: entries } = await request(
        `/storage/v1/object/list/${encodeURIComponent(FIXED_BUCKET)}`,
        {
          method: "POST",
          body: JSON.stringify({
            prefix,
            limit: pageSize,
            offset,
            sortBy: { column: "name", order: "asc" },
          }),
        },
      );

      for (const entry of entries) {
        const joinedPath = prefix ? `${prefix}/${entry.name}` : entry.name;
        const isDirectory =
          entry.id == null &&
          entry.metadata == null &&
          entry.updated_at == null &&
          entry.created_at == null;

        if (isDirectory) {
          pendingPrefixes.push(joinedPath);
        } else {
          objectPaths.push(joinedPath);
        }
      }

      if (entries.length < pageSize) break;
      offset += entries.length;
    }
  }

  return [...new Set(objectPaths)].sort();
}

async function fetchLegacyRows(request, pageSize) {
  const rows = [];
  let offset = 0;
  let identityColumnsAvailable = true;

  while (true) {
    const makeQuery = (includeIdentityColumns) =>
      new URLSearchParams({
        select: includeIdentityColumns
          ? "id,post_id,url,bucket,object_path"
          : "id,post_id,url",
        ...(includeIdentityColumns
          ? { or: "(bucket.is.null,object_path.is.null)" }
          : {}),
        order: "id.asc",
      });

    let page;
    try {
      ({ body: page } = await request(
        `/rest/v1/post_images?${makeQuery(identityColumnsAvailable)}`,
        {
          headers: {
            range: `${offset}-${offset + pageSize - 1}`,
          },
        },
      ));
    } catch (error) {
      if (offset === 0 && identityColumnsAvailable && error.status === 400) {
        // Migration 104 is intentionally database-first. A pre-migration
        // dry-run can still classify every current row as legacy.
        identityColumnsAvailable = false;
        continue;
      }
      throw error;
    }

    rows.push(...page);
    if (page.length < pageSize) break;
    offset += page.length;
  }

  return rows;
}

async function applyUniqueMatch(request, entry) {
  const query = new URLSearchParams({
    id: `eq.${entry.post_image_id}`,
    bucket: "is.null",
    object_path: "is.null",
    select: "id",
  });

  const { body } = await request(`/rest/v1/post_images?${query}`, {
    method: "PATCH",
    headers: {
      prefer: "return=representation",
    },
    body: JSON.stringify({
      bucket: entry.bucket,
      object_path: entry.object_path,
    }),
  });

  return body.length === 1;
}

async function persistAuditOutput(request, entries) {
  if (entries.length === 0) return;

  const query = new URLSearchParams({
    on_conflict: "post_image_id",
  });

  const now = new Date().toISOString();
  const payload = entries.map((entry) => ({
    ...entry,
    reconciled_at: entry.reconciliation_status === "matched" ? now : null,
    updated_at: now,
  }));

  await request(`/rest/v1/post_image_reconciliation_backlog?${query}`, {
    method: "POST",
    headers: {
      prefer: "resolution=merge-duplicates,return=minimal",
    },
    body: JSON.stringify(payload),
  });
}

function summarize(entries, appliedCount = 0) {
  const matched = entries.filter(
    (entry) => entry.reconciliation_status === "matched",
  ).length;
  const zeroMatch = entries.filter(
    (entry) => entry.reason === "no_exact_canonical_url_match",
  ).length;
  const multipleMatch = entries.filter(
    (entry) => entry.reason === "multiple_exact_canonical_url_matches",
  ).length;

  return {
    historical_rows: entries.length,
    unique_exact_matches: matched,
    zero_match_unresolved: zeroMatch,
    multi_match_unresolved: multipleMatch,
    unresolved_total: zeroMatch + multipleMatch,
    backfilled_rows: appliedCount,
  };
}

async function runSelfTest() {
  const baseURL = normalizeBaseURL("https://example.supabase.co");
  const canonical = canonicalPublicURL(
    baseURL,
    FIXED_BUCKET,
    "user folder/object 1.jpg",
  );
  if (
    canonical !==
    "https://example.supabase.co/storage/v1/object/public/post-images/user%20folder/object%201.jpg"
  ) {
    throw new Error("canonical URL generation self-test failed");
  }

  const rows = [
    { id: "image-1", post_id: "post-1", url: canonical },
    {
      id: "image-2",
      post_id: "post-2",
      url: "https://example.supabase.co/storage/v1/object/public/post-images/missing.jpg",
    },
  ];
  const classified = classifyLegacyRows(
    rows,
    ["user folder/object 1.jpg"],
    baseURL,
  );
  if (
    classified[0].object_path !== "user folder/object 1.jpg" ||
    classified[1].reason !== "no_exact_canonical_url_match"
  ) {
    throw new Error("exact-match classification self-test failed");
  }

  process.stdout.write("post-image reconciliation self-test: PASS\n");
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    await runSelfTest();
    return;
  }
  if (!options.output) {
    throw new Error("--output is required so URL-bearing backlog data is not logged");
  }

  const rawURL = process.env.CHEESE_RECONCILE_SUPABASE_URL;
  const serviceRoleKey = process.env.CHEESE_RECONCILE_SERVICE_ROLE_KEY;
  if (!rawURL || !serviceRoleKey) {
    throw new Error(
      "CHEESE_RECONCILE_SUPABASE_URL and CHEESE_RECONCILE_SERVICE_ROLE_KEY are required",
    );
  }

  const baseURL = normalizeBaseURL(rawURL);
  const request = makeHTTPClient(baseURL, serviceRoleKey);
  const [objects, rows] = await Promise.all([
    listBucketObjects(request, options.pageSize),
    fetchLegacyRows(request, options.pageSize),
  ]);

  const entries = classifyLegacyRows(rows, objects, baseURL);
  let appliedCount = 0;

  if (options.apply) {
    for (const entry of entries) {
      if (entry.reconciliation_status !== "matched") continue;
      if (await applyUniqueMatch(request, entry)) {
        appliedCount += 1;
      }
    }
    await persistAuditOutput(request, entries);
  }

  const report = {
    generated_at: new Date().toISOString(),
    mode: options.apply ? "apply" : "dry-run",
    bucket: FIXED_BUCKET,
    storage_object_count: objects.length,
    summary: summarize(entries, appliedCount),
    backlog: entries,
  };

  await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });

  process.stdout.write(
    [
      `post-image reconciliation ${report.mode}: complete`,
      `historical_rows=${report.summary.historical_rows}`,
      `unique_exact_matches=${report.summary.unique_exact_matches}`,
      `unresolved_total=${report.summary.unresolved_total}`,
      `backfilled_rows=${report.summary.backfilled_rows}`,
      `report=${options.output}`,
    ].join(" ") + "\n",
  );
}

main().catch((error) => {
  process.stderr.write(`post-image reconciliation failed: ${error.message}\n`);
  process.exitCode = 1;
});
