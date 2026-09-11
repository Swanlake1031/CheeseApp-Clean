# Forum continuation — 2026-09-10

> Dated change record. The current consolidated specification is
> [CURRENT_RECOMMENDATION_SYSTEM.md](CURRENT_RECOMMENDATION_SYSTEM.md).

## Scope and cause

The Home Forum tab used `composeForumTabCards(...).prefix(12)` and had no
continuation action. The initial recommendation loader also requested only 36
rows from a session with up to 60 rows. This was a client truncation, not evidence
that the database contained only 12 posts.

The user clarified that high-quality old posts may legitimately rank first.
This change does **not** modify time weighting, the V2 classifier or ranking.
System-featured placement and relative recommendation order remain unchanged.

## Behavior

- Display all deduplicated initial cards; fetch the complete recommendation
  session (up to its existing 60-row maximum).
- Near the Forum footer, append up to 20 additional visible posts per request,
  newest first, excluding the fixed set of initially displayed recommendations
  and featured posts. Continuation is browsing, not another ranked session.
- Use `(created_at, id)` keyset pagination, preserving the server's timestamp
  string including microseconds. Deletions do not shift an offset or skip rows.
- Apply V2 cross-school eligibility, visibility, private/status/board checks,
  hidden-post rules and both block directions on every continuation request.
- Advance the cursor from raw references even if a post disappears during
  hydration. Deduplicate appended cards. Refresh/account changes invalidate
  in-flight results; a horizontal tab change does not cancel an accepted request.
- Show loading, explicit retry on failure, and an actual exhausted state. There
  is no total browsing cap of 12, 36 or 60 posts. Newer posts inserted above an
  already-consumed cursor appear on refresh.
- Continuation does not invent V2 session positions or append to closed ranking
  sessions. Initial recommendation event contexts are retained.

## Deployment and verification

Production migration `20260910061558_forum_continuation_pagination.sql` applied.
Read-only live RPC smoke returned 20 rows on page one and 1 on page two, with
zero duplicates. Migration history verified; production
freshness weight remains 0.15. No rows were deleted or backfilled.

Local rollback-only pgTAP: 11 passing checks covering more than 60 posts, page
size, exact tie-break cursor, duplicate prevention, actual exhaustion, earlier-row
deletion, private/hidden/foreign exclusions, blocks and authentication.
The existing V2 suite was also rerun: all 71 checks passed, including exact
baseline score/order parity. Total database regression for this change: 82 checks.

App regression tests cover more than 120 composed cards, preservation of server
order/deduplication and exact microsecond cursor decoding. Debug build,
test-bundle compilation and share-worker syntax checks passed. Full single-device
simulator regression: 255 passed, 0 failed, 0 skipped, at
`/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.10_02-21-00--0400.xcresult`.
The final footer change from view-lifetime task cancellation to an independent
prefetch task was separately Debug-built after that test run's build phase;
physical-device gesture/scroll testing and distribution remain outstanding.

New client distribution is required for the visible fix; no TestFlight/App Store
release is performed here. Rollback requires removing client RPC usage before
dropping the additive RPC via a new migration. Do not rewrite deployed history.

Retired-surface search: no retired functionality added. Existing Housing wording
in LegalDocumentViews is unrelated pre-existing legal copy, not a new module.
