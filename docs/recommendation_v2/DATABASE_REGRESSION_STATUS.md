# V2 database regression — PASS

2026-09-09 America/Toronto (2026-09-10 UTC).

## Verified result

- New V2 rollback-only suite: 71 passed.
- Existing V1 suite: 28 passed.
- Actual artifact parity across 300 teacher + 6 sanity embeddings: 306 passed;
  Python/SQL maximum absolute probability difference 7.22e-16, no threshold
  decision differences.
- Test fixtures rolled back and local V2 switches remained off.

Reproduce against the explicit isolated fixture database:

```sh
/tmp/cheese-rec-v2-venv/bin/python -m recommendation.cross_school.run_database_regression --container supabase_db_cheese-rec-v2-db.LOVWug
```

The runner rejects other container names/network URLs. Its optional
--refresh-draft-scoring updates only two scoring functions on that isolated
fixture database; it is not a production deployment command.

## What was fixed

Batch backfill repeatedly selected an already-recorded invalid embedding,
starving later unscored posts at a small batch size. A cache row now records a
completed attempt for the exact model/input/vector revision, whether successful
or invalid. Changed vectors increment the revision and can be rescored. New
tests reproduced the old bug (2 failures), then passed after the fix.

## Environment crash investigation

The original suite reached assertion 57, then the local server crashed while
rejecting authenticated EXECUTE on a protected function. A separate function
whose entire body was SELECT 1 reproduced it. The body never needed to run.
Disabling plpgsql_check did not help.

This matches the known supautils permission-hint defect:
[upstream issue 214](https://github.com/supabase/supautils/issues/214).
A single local administrator connection with session_preload_libraries empty
returned the correct permission-denied error. The full suites use that same
connection-only isolation and switch to real authenticated/anon/service_role
roles. No grants were relaxed and no persistent or production extension
configuration was changed. The local default image defect itself is not fixed.

## Coverage

Exact V1 rank body fingerprint; Top 80 ordering and every score component;
all 60 shaped items, positions, reasons and pages in off/shadow modes; model
validation and stable sigmoid; same-school bypass; foreign high/low/missing/
invalid/stale scores; inclusive threshold; immutable origins and models;
origin vs author-school change; cache revisions and trigger failure isolation;
session reuse, threshold/viewer-policy invalidation; legacy contract/V1 rollout;
actual role permissions; featured gate; another user's session; rollback;
public-table RLS; batch progression and idempotency.

This is not a concurrent load benchmark or an independent production-quality
evaluation of the teacher-trained classifier.

## Production verification

The exact V2 migration was deployed and the model activated under the user's
direct-release instruction. Independent read-back confirmed:

- gate/scoring enabled; supported-client rollout 100%; threshold 0.55;
- 21 active public forum posts, 21 scores, 0 scoring failures;
- 0 missing origins/embeddings and 0 dimension mismatches;
- migration history recorded;
- rollback-only live smoke: active mode, session created, 20 page items,
  0 ineligible session items, no client access to private scoring data.

The smoke transaction retained no session or temporary data.
Three current posts score >= .55 for foreign-campus eligibility; same-campus
posts are not limited to these three.

Two pre-existing security-advisor view findings remain unchanged. See
IMPLEMENTATION_STATUS.md for App testing, production settings, algorithm
explanation and the new-build installation boundary.
