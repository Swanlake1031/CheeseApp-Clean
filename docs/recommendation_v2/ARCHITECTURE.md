# V2 architecture and implementation sequence

Status: offline preparation. Serving integration is deliberately held until
actual V1 embeddings have been used for the requested linear-model experiment.
The existing V1 pipeline and its rollout percentage remain untouched.

```text
Forum post → existing V1 embedding ─┬→ logistic classifier → q → eligibility
                                   │                              │
                                   └→ V1 semantic feature ← allow ┘
                                            ↓
                              unchanged V1 ranking / Top 80
                                            ↓
                              unchanged shaping / session
```

Same-school content bypasses all classifier checks. Foreign content requires
known canonical institution IDs, a current compatible finite score and
`q >= threshold`. Probability is never a ranking input. Off and shadow modes
must preserve original eligibility, scores, featured placement and ordering.

## Offline boundary

`recommendation/cross_school` owns schema validation, grouped splits, training,
artifact validation, evaluation and reports. `embed_dataset.ts` runs under the
existing Worker development runtime and imports the **existing**
`GeminiEmbeddingProvider` plus version constants. Only post title/body/board
enter the exact SQL-equivalent formatter. Labels, confidence, teacher rationale,
origin school and scenario metadata are not sent to Gemini or used as student
features. Embeddings are cached by model/version/input-format/input hash.

No Python is added to a serving path. No network or LLM calls are needed for
the eventual student classifier; it is a dot product and sigmoid.

## Proposed minimal server integration (not yet applied)

- Preserve `posts.school_id`; add immutable server-owned forum origin ID only
  if immutability cannot safely be guaranteed on the existing field. Backfill
  from stored post school, not current author membership. No destructive SQL.
- Service-only model registry with immutable version, hash, finite weights,
  model/dimension/input-format metadata; threshold lives in versioned policy
  configuration separately from weights.
- Service-only score cache keyed by post, classifier version and input hash.
  Reuse ready V1 vectors; invalidate edited, pending or incompatible vectors.
  Scoring errors must not roll back a V1 embedding completion.
- Gate in `rank_forum_recommendations_v1`'s eligible CTE, before features/Top-K.
  Copy no ranking formula into a competing implementation. Verify the existing
  function's baseline before applying the surgical change.
- Observe shadow decisions separately, never by filtering an already-produced
  V1 session. Bound sampled per-post diagnostics and retention; aggregate
  counts/distributions by model/policy version and failure reason.
- Add `cross_school_gate_enabled=false`, independent scoring/shadow switches,
  and an explicit controlled rollout cohort. Preserve V1's own rollout flag.
- Version session eligibility policy. On policy changes, reject reuse of old
  sessions; rollback must also invalidate filtered snapshots. Do not insert
  new items or change offsets within a still-valid snapshot.

## End-to-end enforcement prerequisite

The server gate alone is insufficient: iOS currently catches recommendation
errors and falls back to legacy, and prepends featured cards outside ranking.
Gate-enabled clients must not use that unfiltered fallback. Featured candidates
must pass the same gate before their existing placement rules run. Explicit
latest/search/profile views are not recommendation feeds and should not become
globally inaccessible through an RLS rewrite. Old clients cannot provide the
new guarantee; controlled rollout must be restricted to a verified client
contract. This must be resolved before Phase 3, not silently shipped.

## Invariants and acceptance

Off/shadow tests compare real V1 candidate IDs, component scores, shaped order
and page boundaries against the unmodified baseline. Enabled tests cover
same-school score/model failures, foreign missing/invalid/stale score and origin,
equality at threshold, edits, school changes, unauthorized score/config writes,
featured content, fallback failure and toggle rollback. Synthetic quality alone
cannot authorize production filtering.
