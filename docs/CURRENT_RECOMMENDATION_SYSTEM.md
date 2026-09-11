# Current recommendation system — source of truth

Last verified: **2026-09-11, America/Toronto**. Repository: **Swanlake1031/CheeseApp-Clean**.

**Deployed TTL-only change (2026-09-11):** migration `20260911164610` is applied
to production. The verified server default is now 15 minutes for new sessions.
Existing stored expiry values were not rewritten. No client release is needed
for this TTL change.

**Deployed backend policy change (2026-09-10):** migration `20260910190417` is
applied to production. New recommendation sessions use the softer ignore penalty;
existing stored sessions retain their old score/position until expiry or a permitted
rebuild. No client release is required for this SQL-only change. See section 8.

**Deployed backend / pending client lifecycle change (2026-09-10):** migration `20260910215652` and
the Home client now reuse valid sessions and rotate presentation only on explicit
pull. Sections 3/5 describe this local contract; section 9 records verification.
The backend is deployed and verified; the iOS client has not been distributed.
The older Home client still forces session creation on refresh. A missing new RPC
would fail closed rather than using an unsafe fallback; that deployment prerequisite
is now satisfied.

Read this document first when discussing or changing recommendations. It describes
the current implementation, not a proposed design. Older audits, training reports
and release notes are historical evidence, not competing current specifications.
If implementation or live configuration differs, investigate and update this
document; do not silently change production to match stale documentation.

## 1. Version identity and deployment boundary

**Current composition: V2 cross-school eligibility + preserved V1 ranking + forum browsing continuation.**
Continuation is not a new ranker and must not be called V3.

| Layer | Current identity | Meaning |
| --- | --- | --- |
| Product recommendation composition | V2 | Cross-school gate before the original semantic ranking |
| Database ranking algorithm | `cheese-rec-v1` | Intentionally unchanged; seeing this string does not mean V2 is off |
| SQL ranker | `rank_forum_recommendations_v1` | Original features and ordering, V2 eligibility inserted; deployed ignore-policy adjustment in section 8 |
| Embedding | `gemini-embedding-2` / `cheese-semantic-v1` | 768 dimensions, L2 normalized, input format 1 |
| Cross-school model | `v1-teacher-v01` | Logistic classifier; its version is separate from the product's V2 name |
| Gate threshold | `0.55` | Policy `v1-teacher-v01-validation-policy-1` |
| Client contract header | `x-cheese-recommendation-contract: 2` | Required for supported-client V2 gating |
| Continuation RPC | `get_forum_continuation_page` | Chronological browsing after the ranked batch |

Production configuration was re-read for this document: ranking rollout 100%,
gate rollout 100%, scoring on, gate on, cross-school shadow off. This says nothing
about independent legacy V1/worker shadow switches.

Deployed migrations:

- `20260910024900_recommendation_v2_cross_school.sql`: V2 gate and session validation.
- `20260910052718_require_school_selection_and_mcmaster_backfill.sql`: validated school selection.
- `20260910061558_forum_continuation_pagination.sql`: browsing continuation.
- `20260910190417_soften_recommendation_ignore_penalty.sql`: softer ignore penalty.
- `20260910215652_home_forum_session_lifecycle.sql`: reusable Home Forum session RPCs.
- `20260911164610_recommendation_session_ttl_15_minutes.sql`: 15-minute TTL for new sessions.

**The updated iOS code is in this workspace; these changes have not been released
to TestFlight/App Store by this task.** Do not claim an existing installed binary
has the new behavior without checking its build. Older binaries without header 2
do not receive full V2 filtering. Backend activation is not client distribution.

## 2. Where it applies

Pending local tag-free authoring change: see section 11. Production still uses
the older board-name embedding input until that migration is deployed.

- Home **Forum**: the ranked batch uses V2, then chronological continuation.
- Home system-featured forum cards: checked by the same cross-school gate, but
  their configured placement is not determined by the organic ranking score.
- Following, Secondhand and Search: separate data/order paths, not this V2 ranker.
- Do not infer that every standalone forum list uses V2 merely because it lists
  forum posts. The entry point documented here is Home's Forum tab.

## 3. End-to-end flow

```text
Forum post create/edit → embedding job → stored normalized embedding
                                      → cached cross-school probability q
User interactions → per-post signal state → normalized user-interest vector
                  → post engagement/quality/exposure metrics

Home load / explicit refresh
  → get_recommendation_feed_mode (header 2)
  → resolve_home_forum_session (serialized per account)
      → reuse valid, account-owned, non-shadow session
      → only if none reusable: normal visibility + V2 cross-school eligibility
          → preserved V1 scoring → Top 80 → diversity shaping → at most 60
          → persist fixed candidate positions for 15 minutes
  → receive session metadata + all fixed references atomically; hydrate posts
  → new session: reset presentation history; show session order
  → same session + normal load: keep current presentation
  → same session + explicit pull: stable three-tier presentation rotation
  → combine eligible featured cards, deduplicate, apply selected-board filter
  → render without the old 12-card truncation
  → near footer: get_forum_continuation_page (20 chronological rows per request)
      → same eligibility protections → append unseen posts → repeat until exhausted
```

### Embeddings and feedback

The AI worker processes queued embeddings; feed requests do not call a generative
model to rank posts. The classifier reuses the stored embedding. Invalid/stale
vectors cannot supply a valid foreign-school score; scoring cache validity tracks
the model, input and vector revision. Updates can invalidate existing sessions.

Per user/post, the effective interest weight is the strongest current signal,
not the sum: reply 8, comment 6, bookmark 5, like 3, read/open 1, otherwise 0.
The interest vector is the normalized weighted sum of compatible ready post
embeddings. Personal semantic scoring requires total weight at least 5;
otherwise semantic score is neutral (0.5). Engagement metrics are stored and
refreshed asynchronously, so not every interaction immediately changes the feed.

### Eligibility and schools

The ranked batch requires active, public forum posts on non-archived boards,
normal visibility, no block in either direction and no viewer-hidden post.
It excludes the viewer's own posts from organic ranking.

V2 compares the post's immutable `forum_posts.origin_school_id` with the viewer's
`profiles.school_id`:

- Known same school: pass the classifier gate, but not bypass normal protections.
- Different schools: approved current model and valid cached `q >= 0.55` required.
- Unknown school or missing/invalid/stale foreign score: fail closed.

`q = sigmoid(w · post_embedding + b)`. It is an eligibility decision, **not an
extra ranking-score term**. Display text alone does not define a user's school.
All 38 profiles were already McMaster at the school migration audit; this is a
dated observation, not a permanent constraint on future users. New client
onboarding requires explicit selection; the backend validates and synchronizes
school name, ID and default campus. Old clients can still submit a valid default.

## 4. Exact ranking and shaping

Let `clamp` constrain a value to [0,1]. The ranker with the pending local migration
computes the following (production deployment status is explicitly tracked above):

| Feature | Weight | Calculation |
| --- | --- | --- |
| Semantic `S` | 0.40 | `clamp((cosine(user, post) + 1) / 2)`; neutral 0.5 without a usable interest/post vector |
| Engagement `E` | 0.20 | Stored normalized engagement, clamped; missing = 0 |
| Freshness `F` | 0.15 | `2 ^ (-max(age_hours, 0) / 48)`; 48-hour half-life |
| Discussion quality `Q` | 0.10 | `clamp(0.6 * min(unique_commenters/5, 1) + 0.4 * min(reply_count/10, 1))` |
| Author affinity `A` | 0.05 | 1 if viewer follows author; otherwise 0 |
| Exploration `X` | 0.10 | `clamp(exp(-total_qualified_impressions / 30))` |

```text
base = 0.40*S + 0.20*E + 0.15*F + 0.10*Q + 0.05*A + 0.10*X
penalty = min(0.15, 0.05 * max(ignored_count - 1, 0))
ranking_score = base - penalty
```

`ignored_count` counts the viewer's qualified impressions in the last seven days
when the user/post effective positive signal is zero. It is not a permanent
"already seen" exclusion.

Ignoring is a weak negative ranking signal, never a hard exclusion. Counts
0/1/2/3/4/10 yield penalties 0/0/0.05/0.10/0.15/0.15. The seven-day window,
qualified-impression event type and zero-positive-signal semantics are unchanged.

Raw engagement uses the last 24 hours:
`(likes + 3*comments + 4*bookmarks + 2*shares) / sqrt(qualified_impressions + 25)`.
Stored normalization uses `percent_rank` across the metrics table ordered by
`(e_raw, post_id)`; if all raw scores are equal, normalized engagement is zero.

Initial candidates sort by score descending, then creation time descending, then
ID descending. Keep Top 80 and shape up to 60:

1. Defer same-author or cosine > 0.93 candidates relative to the last 3 selections.
2. Retry deferred candidates, relaxing to last 2 selections and cosine > 0.96.
3. Fill remaining slots from unselected candidates without those diversity checks.

Passes 2/3 order by ranking score then post ID descending. Persist the resulting
positions; presentation rotation does not change those stored positions or scores.
There is no production session-ranking jitter in this branch, and none is added.
The older Swift preview ranker's seed is not server session jitter. System-featured cards are
placed first and deduplicated; selecting a board preserves relative order.
The user's newly published post may also be locally promoted outside organic ranking.

**There is no hard age cutoff.** A high-quality 23-day-old post may rank first.
The user explicitly accepted this; no freshness-weight change was made during
the pagination fix. Small inventories and unchanged signals can produce similar
results after refresh.

## 5. Refresh, caching, pagination and failures

| Action | Current behavior |
| --- | --- |
| Home load entry | Load if unresolved, cached snapshot is at least 5 minutes old, or known session has expired. No timer. Resolve/reuse server session. |
| Pull to refresh | Refresh other Home surfaces concurrently; reuse valid Forum session and rotate its presentation once. Retain old content while loading. |
| Forum normal refresh | Reuse valid session, preserve presentation; create only when no reusable session exists. |
| Repeated refresh while in flight | Coalesce into one operation/commit. A pull during normal loading upgrades that operation's intent; only one rotation. |
| Switch Home tabs | Returning to Forum checks the normal cache/expiry rule; no gesture-forced session creation or rotation. |
| Reselect bottom Home tab | Select Forum, scroll to top and check normal cache/expiry; no explicit rotation. |
| Foreground | Normal cache/expiry check; backgrounding itself does nothing. |
| Process restart | Resolve the same valid server session; in-memory presentation history is forgotten, so show fixed session order. |
| Edit/delete notification | Normal refresh, no rotation; newly created posts retain existing local promotion behavior. |
| Reach Forum footer | Append a continuation page; do not reorder the existing cards. |
| Successful same-session refresh | Revalidate cached continuation visibility, preserve its order/cursor/exclusions/exhaustion state. |
| Genuinely new session | Reset presentation history and continuation cursor/exclusions/exhaustion state. |
| Refresh/account transition | Invalidate stale append responses; account changes clear account-scoped state. |

New recommendation sessions expire after 15 minutes and have fixed item positions;
existing sessions retain their stored expiry.
Expiry is lazy: no timer recomputes recommendations. The next request discovers
expiry and resolves a new session. Missing/expired sessions or security/policy
invalidation permit creation; a pull gesture alone does not. The server validates
algorithm/config revision, school/gate policy and stored candidate visibility,
including hide/block/private/board status. Ordinary interest/engagement changes
do not rerank a valid session. Logout clears client state; signing back into the
same account may still reuse that account's valid server session. Another account
can never reuse its identity or presentation state.

### Presentation ownership and rotation

The server owns session ID, creation/expiry timestamps and fixed candidate
positions. The client owns only an account+session-scoped in-memory presentation,
generation counter and two most recent top-20 organic windows. Initial display
seeds the first window so the first pull can move away from its top; thereafter
only successful explicit pulls advance history. A new session resets generation
to zero, even when discovered by a pull. Ordinary loads preserve presentation.

Stable-partition the original shaped session order into:

1. Not in either recent window.
2. In the older window, but not the immediately previous window.
3. In the immediately previous window.

Concatenate tiers in that order, preserving original session order inside each.
No score/weight/ignore count is changed and no item is excluded for being recent.
Small or empty inventories are valid; remaining tiers fill naturally. Featured
IDs never occupy organic history slots and retain configured placement. Continuation
is not rotation inventory. Selected-board filtering remains a display filter.
Recommendation events still reference original persisted session positions.

Continuation excludes the fixed initial displayed recommendation/featured IDs,
orders by `(created_at DESC, id DESC)`, and carries both fields as a keyset cursor.
The timestamp string preserves microseconds. Cursor advancement uses raw RPC
rows even if a row disappears before hydration; client deduplication prevents
duplicate cards. Fewer than 20 raw rows marks exhaustion; a full last page needs
one more request to discover the end. There is **no 60-post total browsing cap**.
Same-session pulls do not rewind the cursor to retrieve newer insertions above it;
a genuinely new session resets browsing state. Continuation
can include the viewer's own visible posts and does not fabricate ranked-session
event positions. Board filtering is client-side over loaded cards; continuation
can therefore pass through pages that add no matches for the selected board.

On protected-RPC or cached-continuation validation failure, do not fall back to
an unfiltered query. Keep the prior Forum content/session/presentation and show a
retry message; do not record a successful rotation. Only an explicit
server-off result selects the legacy preview path. That path uses the older
client ranker and is not evidence of V2 operation.

Continuation errors preserve displayed cards/cursor and offer manual retry.
Automatic footer loading stops after either a pagination or Forum refresh error,
preventing an expired-session failure from triggering a refresh loop. Explicit
pull/load-more remains available. Deduplication covers existing organic/featured
IDs and repeated IDs inside a single page; cursor advancement still uses raw rows.
Requests initiated
near the visible Forum footer may finish after scrolling away; they are not
cancelled merely by switching tabs. All continuation calls retain visibility,
private/status/board, hide, block and cross-school checks.

## 6. Source map and historical evidence

- Client orchestration: [HomeViewModel.swift](../CheeseApp/CheeseApp/Features/Home/ViewModels/HomeViewModel.swift).
- RPC contract: [HomeFeedService.swift](../CheeseApp/CheeseApp/Features/Home/Services/HomeFeedService.swift).
- Tab display/footer: [HomeView.swift](../CheeseApp/CheeseApp/Features/Home/Views/HomeView.swift).
- Embedding execution: [processor.ts](../cheeseapp-ai-worker/src/recommendation/processor.ts).
- Embedding storage/jobs: [migration 188](../Supabase/migrations/188_recommendation_embeddings_v1.sql).
- Signals/metrics: [migration 189](../Supabase/migrations/189_recommendation_signals_metrics_v1.sql).
- Ranking/shaping: [migration 190](../Supabase/migrations/190_recommendation_ranking_sessions_v1.sql), patched by [V2 migration](../Supabase/migrations/20260910024900_recommendation_v2_cross_school.sql); pending [ignore-policy migration](../Supabase/migrations/20260910190417_soften_recommendation_ignore_penalty.sql).
- Continuation: [RPC migration](../Supabase/migrations/20260910061558_forum_continuation_pagination.sql).
- Home lifecycle: [pending additive RPC migration](../Supabase/migrations/20260910215652_home_forum_session_lifecycle.sql).
- Model: [immutable artifact](../recommendation/cross_school/artifacts/cross-school-logistic-v1-teacher-v01.json).
- Historical deployment/training: [V2 release snapshot](recommendation_v2/IMPLEMENTATION_STATUS.md).
- Pagination change/test record: [continuation handoff](forum-continuation-pagination.md).
- School boundary: [school-selection handoff](required-school-selection.md).
- Operational rollback: [ROLLBACK.md](recommendation_v2/ROLLBACK.md).

Historical pre-lifecycle verification: 71 V2 + 11 continuation database checks passed;
255 simulator tests passed, zero failures/skips. The final footer task-lifetime
adjustment was separately Debug-built after that suite's build phase. Physical
device scrolling verification and client distribution remain outstanding. These
are dated results, not automatic guarantees about later changes. See section 9
for the lifecycle change's separate verification record.

## 7. Maintenance rule

Every change to ranking, eligibility, signals, model/threshold, refresh, paging or
deployment must update this file in the same change. Record separately:

1. What changed, date, and exact migration/model/client identifiers.
2. What is implemented locally versus verified deployed versus released to users.
3. Verification performed and outstanding limits.

Do not rename V1 identifiers just to make them look like the product's V2 label.
Do not treat old rollout plans as active instructions. Preserve old notes as
dated snapshots and point them here. Never edit deployed migration history to
make version names agree; use new migrations for actual backend changes.

## 8. Atomic ignore-policy change — 2026-09-10

Migration: `20260910190417_soften_recommendation_ignore_penalty.sql`.
Status: **deployed to production backend on 2026-09-10** after local regression.
No client code or version identifiers changed, and no client release is required.

```text
Before: penalty = min(0.45, 0.15 * max(ignored_count - 1, 0))
After:  penalty = min(0.15, 0.05 * max(ignored_count - 1, 0))
Both:               ranking_score = base - penalty
```

The pre-deployment production definition was inspected directly: body MD5
`9c118d72c1953fa9b05480d5833bfb85`. The migration requires that exact pre-change
body and one occurrence of the old expression. It replaces only that expression
using `pg_get_functiondef`, preserving signature, security, search path, ownership
and grants. A reverse-normalized fingerprint verifies the rest of the body is
identical. Drift aborts the transaction for review rather than overwriting it.
The verified post-migration local **and production** body MD5 is
`956bf92f2fbab03a50d7d8ed96c7b61f`; rollback-only test helper functions were
confirmed absent after local verification.

All six weights/features, seven-day counting semantics, eligibility and q policy,
Top 80, diversity shaping, fixed sessions, refresh, paging, featured placement and
continuation were unchanged by this isolated ignore-policy migration (the separate
lifecycle change is recorded in section 9). A base of 0.65 with three ignores produces 0.55
instead of 0.35. Ranking order may change because the intended penalty is weaker;
the sorting/shaping algorithms themselves do not change.

Once deployed, **new sessions** use the softer penalty without requiring a client
binary update. Existing sessions retain stored scores/positions until normal
refresh/expiry; this migration neither invalidates nor rewrites them. The old
session-table storage constraint allowing up to 0.45 remains intentionally valid
for those rows. Operational rollback likewise requires a new, audited forward
migration and does not rewrite already-created sessions.

Verification for this change:

- New actual-ranker/session regression: **29 passed**, covering counts 0, 1, 2,
  3, 4, 10; cap/subtraction; no hard exclusion; exact 0.65 example; full non-penalty
  feature parity; seven-day boundary, old/other-user/non-qualified events;
  positive-signal suppression; preserved session reuse/scores; Top 80; 60-row
  shaping and 20-row pages. Comparisons freeze time in rollback-only test functions.
- Existing V2: **71 passed**; V1: **28 passed**; continuation: **11 passed**.
  Total for this policy change: **139 database checks passed**, all rollback-only.
- App Debug build, test-bundle compilation, Share Worker syntax check and
  `git diff --check` passed. The current full simulator run passed **255 tests,
  zero failures/skips**:
  `/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.10_15-10-09--0400.xcresult`.
- Before deployment, a production dry-run listed only the new ignore-policy
  migration. The later deployment and post-deployment production verification are
  recorded in section 9.

Old constants retained intentionally: deployed migration 190 (original formula
and historical storage constraint), the dated V1 audit, migration guards/reverse
checks, before-policy regression controls, and this before/after record. The V2
test fingerprint normalizes the reviewed penalty change only for comparison with
the historical body; both sides of its eligibility parity test keep the current
penalty. The Swift legacy preview ranker has no ignore-impression penalty to
change. Unrelated 0.15 freshness weights, UI constants and model coefficients are
not modified. No historical/deployed migration was edited.

## 9. Home session lifecycle change — 2026-09-10

Migration: `20260910215652_home_forum_session_lifecycle.sql`.
Status: **deployed to production backend on 2026-09-10** after local regression.
No Git push, TestFlight or App Store release was performed. The deployed ignore
migration `20260910190417` supplies the 0.15 cap / 0.05 step. Neither V1/V2 names
nor ranking jitter changed.

### Database and client contract

This additive migration introduces `resolve_home_forum_session()`,
`validate_home_forum_posts(uuid[])` and private `home_post_visible(uuid,uuid)`.
Public RPCs require authentication; the private helper is not client-executable.
Resolution serializes concurrent requests with an account-specific transaction
advisory lock. No new table, data deletion or historical migration edit is involved.
Existing ranker, creator/shaper, old page RPC and continuation RPC are unchanged.

Before this change, Home requested a forced new session and replaced continuation
on every successful Forum refresh. Now the server resolves/reuses; the client
only rotates on explicit pull. The one new low-level force-create call executes
only after the resolver finds no reusable valid session. Remaining forced calls:
AI worker shadow-session generation (separate `is_shadow=true` inventory), explicit
database regression/live-smoke fixtures, and historical creator definitions/audits.
There is no Home Swift force-create caller. The original V1 test label was corrected
to describe low-level creation rather than imply current Home pull semantics.

Diagnostics expose session ID, created/expiry timestamps, reused flag and creation
reason on `forumSessionDiagnostics`. The `ForumLifecycle` log records session ID,
reuse/reason, rotation applied, generation and tier counts, without post/user content.
Server reasons are `missing_session`, `expired_session`, `server_policy_invalidated`
or `valid_session` for reuse; account switches resolve under the new authenticated
identity rather than accepting a client-provided owner ID.

### Lifecycle matrix

“If needed” means no valid reusable account-owned session exists (including expiry
or safety/policy invalidation), not that the UI gesture forces recomputation.

| Event | New session? | Ranking recomputed? | Presentation rotation? |
| --- | --- | --- | --- |
| First load | If needed | Only if new | No; seed initial top window |
| Normal Home load | If needed after cache check | Only if new | No |
| Home tab switch back to Forum | If needed after cache check | Only if new | No |
| Home reselect / scroll to top | If needed after cache check | Only if new | No |
| Explicit pull, valid session | No | No | Yes, once per coalesced successful refresh |
| Explicit pull, expired session | Yes | Yes | No; reset history for new session |
| Background / foreground | None on background; if needed on foreground | Only if new | No |
| Process restart | Reuse valid server session, otherwise create | Only if new | No; memory-only history resets |
| Session expires while idle | Not until next request | Not until next request | No |
| Logout / login same account | Reuse that account's valid session if available | Only if new | No; local state cleared |
| Switch to another account | Resolve that account's own session | Only if new | No; no state crosses accounts |
| Continuation footer | No while session valid; resolve if known expired | Only if new | No; append chronologically |

### Changed files and verification

Lifecycle scope (existing unrelated worktree edits are not part of this change):

- `Supabase/migrations/20260910215652_home_forum_session_lifecycle.sql`
- `Supabase/tests/database/20260910215652_home_forum_lifecycle.test.sql`
- `Supabase/tests/database/190_recommendation_v1.test.sql` (test description only)
- `CheeseApp/CheeseApp/Features/Home/Services/HomeFeedService.swift`
- `CheeseApp/CheeseApp/Features/Home/ViewModels/HomeViewModel.swift`
- `CheeseApp/CheeseApp/Features/Home/Views/HomeView.swift`
- `CheeseApp/CheeseAppTests/HomeFeedServiceTests.swift`
- `docs/CURRENT_RECOMMENDATION_SYSTEM.md`

Database suites run sequentially using `psql -X -qAt -v ON_ERROR_STOP=1` in the
isolated local Supabase container, with each test transaction rolled back:

- `20260910215652_home_forum_lifecycle.test.sql`: 31 checks; valid reuse without
  ranking calls (ranker deliberately traps during reuse), repeated pulls, lazy
  expiry, ownership, security invalidation, visibility and unchanged SQL fingerprints.
- `20260910190417_ignore_penalty.test.sql`: 29 checks; exact softer penalty and
  unchanged ranking/shaping/session/page contracts.
- `20260910024900_recommendation_v2_cross_school.test.sql`: 71 checks.
- `20260910061558_forum_continuation.test.sql`: 11 checks.
- `190_recommendation_v1.test.sql`: original 28 checks.

Client regression covers stable tiers, two-window history, small/empty inventories,
featured exclusions, same-session cursor retention/new-session reset, process
restart, account isolation, overlapping pulls, upgrading a normal request, cancelled
old operations and failure/retry intent cleanup. Final boundary fixes additionally
cover stopping automatic footer retry after either error and stable deduplication
against previous/featured rows and duplicates inside a page.

Verification commands:

```sh
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD build
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD-tests build-for-testing
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -destination 'platform=iOS Simulator,id=A309E0B7-2069-48B5-B3E5-7A0AAFB35080' -parallel-testing-enabled NO -derivedDataPath /tmp/CheeseAppDD-tests test
# Final account-guard build and targeted rerun:
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD build-for-testing
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -destination 'platform=iOS Simulator,id=A309E0B7-2069-48B5-B3E5-7A0AAFB35080' -parallel-testing-enabled NO -derivedDataPath /tmp/CheeseAppDD -only-testing:CheeseAppTests/HomeFeedServiceTests test-without-building
npm run check --prefix cheeseapp-share-worker
git diff --check
```

Verification results: all **170 database checks passed** (31 + 29 + 71 + 11 + 28).
The full simulator suite including the retry/dedup boundary tests passed **265
tests, zero failures/skips**, on iPhone 16 / iOS 26.3.1:
`/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.10_18-43-11--0400.xcresult`.
After that suite's build phase, review added an immediate cancellation/account
identity guard following the asynchronous auth preparation, before a stale
operation can change request generations. The final App Debug and test-bundle
builds passed. The targeted Home rerun against that final build passed **42 tests,
zero failures/skips**:
`/tmp/CheeseAppDD/Logs/Test/Test-CheeseApp-2026.09.10_18-51-36--0400.xcresult`.
Share Worker syntax check and `git diff --check` passed. Final review inspected
the affected Swift/test diffs, complete new SQL migration/test, current document,
remaining force-create callers and historical-migration status; no existing
migration was edited and unrelated pre-existing worktree changes were preserved.

Limits: physical-device gesture/scroll UX and multi-device concurrent HTTP requests
have not been exercised. Client coalescing is tested asynchronously; database
serialization is checked by inspecting the installed advisory-lock definition,
not by a two-connection race test. Cached content can remain visible after a
failed refresh under the existing failure policy; it is not represented as newly
validated. In-memory rotation history intentionally does not survive app kills.

Deployment record: both migrations were pushed to the linked production database
in order (`20260910190417`, then `20260910215652`). Read-only production verification
confirmed both schema-migration records, ranker MD5
`956bf92f2fbab03a50d7d8ed96c7b61f`, both public lifecycle RPCs and the resolver's
advisory lock. The remaining release step is distributing the verified iOS client
from Xcode. Rollback must revert client RPC usage before removing additive RPCs in
a new forward migration; it must not rewrite stored session scores/positions or
historical migrations.

## 10. Session TTL: 20 → 15 minutes — 2026-09-11

Migration: `20260911164610_recommendation_session_ttl_15_minutes.sql`.
Reason: improve ranking/personalization freshness while preserving session stability.
Status: deployed to production on 2026-09-11 after local verification.
No client release is required for this SQL default change.

The authoritative TTL lives in the `public.feed_sessions.expires_at` column
default, originally installed by migration 190. The session creator omits this
column and persists the default on insertion. The sole production behavior change is:

```sql
-- Before: clock_timestamp() + INTERVAL '20 minutes'
ALTER TABLE public.feed_sessions ALTER COLUMN expires_at
  SET DEFAULT clock_timestamp() + INTERVAL '15 minutes';
```

The migration locks the table briefly (5-second lock timeout), verifies the exact
previous default, and changes it transactionally. It does not update any existing
row, function, trigger, timer, ranking formula or configuration. Existing sessions
retain their stored 20-minute expiry. The shared default also governs new shadow
sessions, as before. Explicit expiry values supplied by administrative SQL remain
explicit values. `created_at` and `expires_at` retain separate `clock_timestamp()`
default evaluations, so their difference can exceed 900 seconds by microseconds;
the existing timestamp semantics are preserved rather than refactoring creation.

The resolver and page checks still require `expires_at > clock_timestamp()`;
equality means expired. Expiry remains lazy, with no background timer. The next
relevant request resolves a new session after expiry. Valid pulls still only
rotate once; new-session pulls reset history without an extra rotation. Normal
loads do not rotate. V1/V2, q >= 0.55, ignore penalty, Top 80, shaping up to 60,
continuation, visibility and ownership remain unchanged. Swift reads server expiry
metadata; no hard-coded 20-minute assumption or client change was needed. The
five-minute client cache threshold and 20-item presentation/page sizes are unchanged.

Changed files: this document, the new TTL migration,
`Supabase/tests/database/20260911164610_session_ttl.test.sql`, and
`Supabase/tests/database/20260910215652_home_forum_lifecycle.test.sql`.
No deployed historical migration was edited. Old 20-minute references in migration
190 and the dated V1 audit remain historical evidence. Old-default migration guards
and before/after fixtures intentionally retain 20 minutes / 1200 seconds.

Verification: new TTL suite checks the default, unchanged resolver fingerprint,
old-row preservation and both old/new lifetimes. Lifecycle tests use a rollback-only
clone of the actual resolver with a controlled clock to test T+14:59, exact expiry
and post-expiry. A trapped ranker proves valid reuse never ranks and expired
resolution invokes ranking; restoring the actual ranker confirms replacement.
Existing regression suites and final build/test results are recorded below.

Database results (rollback-only, local `psql -X -qAt -v ON_ERROR_STOP=1`):
TTL 5/5, Home lifecycle 35/35, ignore penalty 29/29, V2 cross-school 71/71,
continuation 11/11, V1 ranking 28/28 — **179 checks passed**. Share Worker
`npm run check --prefix cheeseapp-share-worker` and `git diff --check` passed.
The pre-implementation production default was checked read-only as
`clock_timestamp() + '00:20:00'::interval` before implementation.

App Debug build and simulator test-bundle build passed using the section 9
`xcodebuild` commands with `/tmp/CheeseAppDD` and `/tmp/CheeseAppDD-tests`.
Home regression ran with `-only-testing:CheeseAppTests/HomeFeedServiceTests
test-without-building` on the same iPhone 16 simulator: **42 passed, zero failures
or skips**. Result:
`/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.11_12-49-34--0400.xcresult`.
Final review confirmed the new migration changes only the column default, and
the TTL patch touches only the four files listed above. Physical-device testing
was not repeated for this server-default-only change. No new client build is
needed for the TTL itself.

Production deployment: pushed `20260911164610` on 2026-09-11 from an isolated
migration staging directory because another pending migration (`20260911165358`)
was present in the workspace. The isolated dry-run listed only the TTL migration.
Post-deployment read-only verification confirmed its migration record, the default
`(clock_timestamp() + '00:15:00'::interval)`, unchanged ranker MD5
`956bf92f2fbab03a50d7d8ed96c7b61f` and unchanged resolver MD5
`57371e8ce9c0c0d556736ac4886da953`. The separate tags migration was not applied
by this deployment. No existing session rows were updated by the migration.

## 11. Remove manual authoring tags — 2026-09-11

Status: implemented locally; backend migration and client release remain pending.
Migration: `20260911165358_forum_recommendations_without_manual_tags.sql`.

Create and edit share `ForumPostEditorSurface`; its tag picker and board-dependent
form validation are removed. New posts require a valid title, not a tag. Existing
body/image/anonymous controls remain. The current schema has no `tags` array:
migration 099 historically replaced it with required `forum_posts.board_id`.
Consequently no new `tags` payload field is introduced. Internal routing preserves
an originating board or old draft board; otherwise new posts use active `casual-chat`.
Edits retain the original board ID; historical labels and associations are retained.
No user is asked to choose a label to fix a missing-routing/network error.

Audit found an indirect recommendation dependency: `recommendation_embedding_input`
included the selected board name on its `Hashtags:` line. The forward migration
verifies its previous function fingerprint and replaces both label expressions
(text and hash) with an empty string. The existing input envelope and format ID
remain compatible with the worker. Semantic input now contains title/body and
an empty `Hashtags:` line; no manually selected label value is used. Board status
continues to enforce visibility, independently of semantic labels. V1 ranking
weights, V2 classifier coefficients, q >= 0.55, and lifecycle functions are unchanged.

To avoid retaining tag information in cached vectors, the migration invalidates
incompatible derived post vectors, including inactive posts that could contribute
to user-interest profiles; existing triggers rebuild interest profiles and invalidate
cross-school score validity. Eligible posts are queued for content-only embedding.
Stored recommendation sessions expire once at migration time because their scores
may reflect old vectors. No posts, boards, labels or associations are deleted.
Normal expiry/rotation rules resume afterward. This one-time invalidation belongs
to the tag-input change, not the separate TTL migration in section 10.

Deployment order: back up the database, apply migration, let the existing embedding
worker regenerate vectors/scores, inspect readiness and cross-school score quality,
then distribute the client. During regeneration same-school semantic scores may be
neutral and foreign-school candidates without ready scores fail closed. Cached
client displays refresh on their normal lifecycle; they are not remotely erased.
The existing classifier was trained with historical board-name inputs, so score
calibration after removal needs production observation; no retraining or model
artifact change is bundled. Historical datasets/offline training input builders
remain reproduction tools for that model, not the new live input specification.
Any future retraining must use the current tag-free SQL input contract.

There is no new topic-label inference feature. If introduced later, labels must be
system-generated and must not restore manual selection as a publishing requirement.
Rollback uses a new migration and requeues embeddings; restoring previous derived
vectors requires the predeployment backup. Historical content remains unchanged
because this migration never edits it.

Local database verification: tag-independent input 7, Home lifecycle 35,
ignore penalty 29, V2 cross-school 71, continuation 11 and V1 ranking/embedding 28:
**181 checks passed**. Tests prove tag-name and active-board changes leave semantic
text/hash identical; title changes still requeue; title-only content is accepted;
ranker and resolver fingerprints are preserved. Client form validation includes a
new title-only/no-tag regression. Build and simulator results are recorded below.

Changed files: `CreateForumView.swift`, shared `ForumPostEditorSurface.swift`,
`EditPostSheet.swift`, `ForumService.swift` (routing-error copy),
`PostCorrectnessTests.swift`, the new migration, its matching
`20260911165358_no_manual_tags.test.sql`, and this document. No historical
migration, training data, model artifact or ranking function was edited.
App Debug and test-bundle builds passed with the section 9 commands; Share Worker
syntax check and `git diff --check` passed. The initially interrupted simulator
run left an incomplete result bundle and is not counted as a test pass.
The resumed full simulator suite passed **266 tests, zero failures/skips** on
iPhone 16 / iOS 26.3.1 using `test-without-building` after both successful builds:
`/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.11_13-02-33--0400.xcresult`.
Final diff review and searches confirmed no manual tag picker or choose-tag
validation remains in the create/edit surfaces. Historical board metadata and
reproduction fixtures remain intentionally. Physical-device composer UX and live
post-reembedding classifier calibration have not been verified in this local task.


## 12. App Store privacy boundary — pending rollout (2026-09-11)

The App Store audit adds `ai_processing_consents` and checks the post author's
explicit permission before the Worker sends text to Gemini for a new embedding.
The SQL claim function skips authors without permission, preventing them from
starving consented work. A Worker-side revocation race fails the job with `ai_consent_required`;
consenting requeues authored forum posts. Withdrawal deletes the author's stored
post vectors, invalidating dependent scores through existing triggers. Ranking
weights, model versions, pagination and the threshold remain unchanged. This can
reduce semantic/cross-school coverage until authors consent; missing eligible
scores continue to fail closed. Previously computed vectors remain until normal
invalidation or explicit withdrawal. No historical content is newly sent to Gemini
without permission. All participants in AI reply context must also consent.

Code is pending coordinated migration/Worker/client rollout. Do not claim this
privacy boundary is deployed solely because the client builds. Review the dated
App Store report for actual verification and remaining release blockers.

Gemini release gate: the checked-in Worker has both
`GEMINI_PROVIDER_RELEASED = false` in source and
`CHEESE_GEMINI_RELEASE_ENABLED = false` in configuration. A dashboard variable
cannot override the source latch. The public comment and secondhand-generation
routes are absent from the asset routing and return `404` before authentication,
parsing, repository creation, or provider construction. The public health
response exposes only generic release and maintenance state, never Gemini model
or key-configuration details. Reopening any provider path requires a separately
audited source change plus explicit operational flags. The existing Gemini API
provider's age restrictions conflict with the current App Store 13+ audience;
explicit AI consent does not resolve that restriction.

`CHEESE_RECOMMENDATION_JOBS_ENABLED` remains a separate database-maintenance
switch. While the Gemini release gate is false, the scheduled worker still
backfills embedding jobs, backfills recommendation signal state, refreshes
recommendation metrics and, if separately enabled, creates SQL-only shadow
sessions from already stored data. It does not claim embedding jobs and therefore
does not send post content to Gemini. The health endpoint separately reports
generic `recommendationMaintenanceEnabled`,
`recommendationProviderEnabled`, and `recommendationShadowEnabled` state.

Neither the new consent migrations nor the updated Worker were deployed by this
audit. Resolve the provider/audience contract and verify paid-service privacy
before enabling this coordinated release. Embedding completion locks and rechecks
the consent row so withdrawal cannot be followed by a late job re-creating a
deleted vector. Signup metadata cannot import unreviewed external avatars; new
profiles start with a placeholder.
