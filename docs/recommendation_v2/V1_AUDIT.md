# Recommendation V1 audit — 2026-09-09

## Scope and implementation hold

This is the initial audit of the **current workspace**, not a declaration that
Recommendation V2 has been implemented or deployed.

The supplied request names `Swanlake1031/CheeseApp`. This workspace's origin is
`https://github.com/Swanlake1031/CheeseApp-Clean.git`, at baseline commit
`dc6f50aef74817e118c76f6618cd2d9c512ce2d6`, with substantial pre-existing changes.
The user confirmed on 2026-09-09 that **CheeseApp-Clean is the intended repository**.
An unauthenticated
GitHub lookup of the requested repository returned 404; this does not establish
that a private repository does not exist. No existing code, production flags,
database schemas, model weights, or user data were changed during this audit.

## Evidence and live state

Read-only queries of the linked Supabase project confirmed:

- Migrations 188, 189 and 190 are recorded as applied.
- `recommendation_configuration.rollout_percentage = 0`.
- `shadow_enabled = true`; algorithm is `cheese-rec-v1`.
- Embedding model is `gemini-embedding-2`, representation version
  `cheese-semantic-v1`, input format version 1, dimension 768.
- All 21 current forum embeddings are ready; measured vector dimensions are
  768–768. All 21 forum posts have a non-null `posts.school_id`.
- 112,784 stored feed sessions are shadow sessions. No non-shadow sessions were
  returned by the aggregate query. This is a snapshot, not a retention audit.
- Configured S/E/F/Q/A/X weights are 0.40/0.20/0.15/0.10/0.05/0.10.

The function descriptions below are traced from repository migrations and code.
Read-only `md5(pg_proc.prosrc)` comparison against extracted migration bodies
matched for all seven critical functions: `can_view_post`,
`recommendation_embedding_input`, `rebuild_user_interest_profile`,
`refresh_post_recommendation_metrics`, `rank_forum_recommendations_v1`,
`create_recommendation_feed_session`, and `get_recommendation_feed_page`.

## 1. End-to-end paths

### Server Recommendation V1 (currently shadow-only)

1. `public.posts` holds forum title/body, author, school, visibility and status;
   `public.forum_posts` links the post to `public.forum_boards`.
2. Migration `188_recommendation_embeddings_v1.sql` builds input, queues work,
   stores vectors, and rejects stale job completions.
3. `cheeseapp-ai-worker/src/index.ts` invokes `RecommendationProcessor` from its
   scheduled handler. `src/recommendation/processor.ts` backfills jobs/signals,
   refreshes metrics, claims up to eight jobs and processes two concurrently.
4. `src/recommendation/embeddingProvider.ts::GeminiEmbeddingProvider.embed`
   calls Gemini, checks dimension/finiteness and L2-normalizes the vector.
5. The repository's `complete_post_embedding_job` RPC commits a compatible,
   current-input vector. Signal/profile machinery is in migration 189.
6. Migration `190_recommendation_ranking_sessions_v1.sql` implements
   `rank_forum_recommendations_v1` → `create_recommendation_feed_session` →
   `get_recommendation_feed_page`.
7. `HomeFeedService.fetchRecommendationForumPreview` requests feed mode, creates
   a session, pages IDs, hydrates `forum_posts_view`, and restores ID order.
8. `HomeViewModel.fetchForumSnapshot` preserves server order for a valid session;
   `recommendedCards` prepends featured forum cards, deduplicates and takes 12.

The Worker also creates shadow sessions for up to eight users per scheduled
batch. The checked-in Worker configuration enables recommendation jobs and V1
shadow work on a once-per-minute schedule. Supabase is the ranking runtime;
the Worker is not an independent ranker. Unrelated community AI generation is
not part of recommendation inference.

### Current user-visible legacy path

At rollout 0, `get_recommendation_feed_mode` sends every account to legacy.
`HomeFeedService.fetchForumPreview` reads public `forum_posts_view`, sorted by
view count, creation time and ID, taking 36. `HomeRecommendationRanker` in
`Features/Home/Models/HomeCardItem.swift` combines forum and featured marketplace
cards with deterministic seeded random scoring, retaining pinned cards first.
Forum legacy weights are views .12, saves .14, likes .10, comments .14, random
.50; marketplace uses views .25, saves .25, random .50. Metric scaling is
`log1p(value) / log1p(maxValue)` with a zero-scale guard. This is **not** the
semantic server V1 formula.

The separate forum listing uses `ForumService.fetchPostPage` →
`get_forum_posts_page` with pinned/hot/created-at/ID keyset cursors. Search,
detail and ID hydration also use the view. The supplied observation about
client `highlight_rank` ordering is not the complete current serving path.

## 2. Exact embedding contract

Migration 188's `recommendation_embedding_input(post_id)` produces:

```text
task: sentence similarity | query: Title: <BTRIM(title) or empty>
Body: <BTRIM(description) or empty>
Hashtags: #<board.name>
```

The hash is SHA-256 of UTF-8 input. Title/body/status, board membership and board
name changes enqueue refreshed input. Input format includes the existing board
name; retaining this is preprocessing compatibility, not a new hashtag gate.

`post_embeddings` stores `extensions.vector(768)`, keyed by
`(post_id, embedding_version)`, with model, input format, hash, state and times.
Worker constants and DB configuration agree on `gemini-embedding-2` and 768.
Gemini is requested with `output_dimensionality: 768`, no additional `taskType`
parameter, and the result is normalized. No immutable upstream model revision
is recorded beyond the model alias; `cheese-semantic-v1` is Cheese's version,
not a provider checkpoint hash. V2 must reuse this representation, not invent
an upstream revision or silently select another model.

## 3. User interest and signals

Migration 189's `refresh_user_post_signal_state` chooses the **strongest current
signal per user/post**: nested reply 8, top-level comment 6, save 5, like 3,
meaningful read 1, otherwise 0. These are not summed for one post.
`record_recommendation_event` treats both `meaningful_read` and `open` as a read.
`rebuild_user_interest_profile` sums compatible ready vectors times these
weights and normalizes the sum into `user_interest_profiles`. Signal changes
and ready embedding changes trigger rebuilding. Ranker cold-start is total
weight <5, absent normalized user vector, or absent post vector; S then is .5.

## 4. Candidate generation and ranking

`rank_forum_recommendations_v1` joins posts, forum details and boards. It requires
active, public, non-archived forum content, excludes the viewer's own posts,
bidirectional blocks, hidden posts and optional prior-session IDs. Authenticated
requests also require `can_view_post`; the service-role shadow path bypasses
that predicate while retaining explicit filters. **There is no school gate.**

Features are:

- S: `(dot(normalized user, normalized post) + 1) / 2`, clamped to [0,1].
- E: `(likes24h + 3*comments24h + 4*saves24h + 2*shares24h) /
  sqrt(qualifiedImpressions24h + 25)`, then `percent_rank()` over
  `(e_raw, post_id)` across stored metric rows, or zero if every raw value is
  equal. This tie-break is part of the existing behavior. Metrics refresh no
  more often than every five minutes unless forced.
- F: `2^(-max(ageHours,0)/48)`.
- Q: `.6*min(uniqueCommenters/5,1) + .4*min(replyCount/10,1)`; discussion counts
  are all-time non-deleted comments/replies, not LLM judgments.
- A: one if viewer follows author, otherwise zero.
- X: `exp(-totalQualifiedImpressions/30)`.

Base score uses the six configured weights. Final score subtracts the existing
repeat-ignore penalty: `min(.45, .15*max(0, ignoredCount-1))`, counting qualified
impressions in the last seven days when effective interaction weight is zero.
Ordering is final score, creation time, ID descending. Limit is capped at 80.

## 5. Shaping and pagination

`create_recommendation_feed_session` takes Top 80 and stores at most 60 items.
Pass one defers same-author or cosine >.93 conflicts in the preceding three
items. Pass two relaxes to two items and >.96. Pass three fills from remaining
ranked candidates. The function calls the ranker again on relaxed passes;
freshness uses `clock_timestamp()`, so these are not frozen feature evaluations.

Sessions live 20 minutes; non-force requests reuse unexpired sessions with the
same user, algorithm and shadow state. Stored positions own pagination, with
page size capped at 20. The iOS client hydrates up to 36 IDs and shows 12 home
recommendation cards; a refresh explicitly asks for a new session. Visibility
may remove a card during view hydration. Featured cards are added client-side.

## 6. Campus identity

Canonical institution IDs already exist: `schools.id`, `profiles.school_id`,
`posts.school_id`. `school_campuses`/`profiles.campus_id` refer to physical
campuses and are not interchangeable with the cross-**school** boundary.
Migration 182's `create_forum_post` copies the author's school into the post on
creation. Therefore membership need not be inferred from text or joined only
to the author's current profile. The repository does not establish a dedicated
immutable forum-origin field. Candidate design: a nullable, server-owned
`forum_posts.origin_school_id`, backfilled only from the existing stored post
school and copied on insertion, then immutable. Unknown origins stay unknown
and cannot cross schools; do not guess them from text or today's author school.

## 7. Differences to preserve / decisions required

| Intended specification | Observed implementation |
| --- | --- |
| V1 serves the recommendation feed | Server V1 exists but production rollout is 0%; legacy serves users |
| Six-feature ranking | Same base weights, plus an existing repeat-ignore penalty |
| Interaction weights | Strongest signal per post; opening also qualifies as a read |
| Normalized engagement | 24-hour raw counts, percentile normalization with ID tie-break |
| Top 80 → shaped feed | Top 80 → up to 60 stored → 36 hydrated → 12 displayed |
| Stable ranking session | Stable stored positions; repeated rank calls during shaping |
| Gate before all ranked content | Featured cards are prepended outside server candidates |
| Foreign posts fail closed | Client currently catches recommendation errors and falls back to ungated legacy |
| Immutable origin | Stored post school exists; an explicit immutability contract is needed |
| Provider version pinned | Model alias + local version exist; provider checkpoint revision is not recorded |

No mismatch has been silently corrected. In particular, enabling V1 rollout,
changing the client error fallback or handling featured overrides is a serving
decision, not something to hide inside a classifier patch.

## 8. Safest V2 insertion and required regression checks

Insert eligibility in the ranker's `eligible` CTE, before feature calculation
and Top-K, without adding classifier probability to any ranking expression.
Score once per existing vector input hash and classifier version, retaining
embedding/model/input-format metadata to invalidate stale scores after edits.
Same-school checks must return before touching classifier metadata. Other posts
require known origin/viewer IDs and compatible finite scores with `q >= tau`.

Default flags must be off. Shadow evaluation must observe candidates without
filtering or reranking. Gate activation needs an explicit session-policy
version strategy, including existing session invalidation/rollback; filtering
stored pages after ranking would not meet the requirement. Client fallback and
featured-card bypass must be resolved and tested before claiming end-to-end
fail-closed serving. Disabling the gate must restore the original eligibility
path, not a hand-reimplemented approximation of V1.

Next checks: design disabled/shadow integration; verify exact preprocessing parity and
classifier/SQL numerical behavior; add grouped offline evaluation; verify V1
off/shadow equivalence and all candidate/fallback paths. No model has been
trained, no evaluation metrics have been fabricated, and no rollout decision
is justified by this initial audit.
