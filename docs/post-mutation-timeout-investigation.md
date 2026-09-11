# Post mutation timeout investigation — 2026-09-06

The report showed PostgreSQL `canceling statement due to statement timeout`.
Production authenticated requests have an eight-second statement budget.
No persistent blocking transaction was present during inspection. A synthetic
private Secondhand post with one synthetic image completed deletion in 69 ms
in a rolled-back production transaction; no real post or stored image was deleted.
Recorded successful Secondhand RPC calls averaged 73 ms with a 352 ms maximum.
Failed statements are not represented by those successful-call timings, so the
original timeout's precise cause remains unconfirmed.

The screenshot's Home `Action failed` alert is wired to likes/favorites in the
current source. Deletion is a separate route. Both were inspected and the
recovery changes cover deletion and favorite mutations.

Changes:

- Keep every owner deletion on the media-aware RPC. Remove the direct table
  deletion fallback that previously swallowed preflight errors.
- Use a known post type from Profile/Forum screens to avoid a redundant read.
- Retry at most three times, and only for PostgREST SQL states proving rollback:
  statement timeout, lock timeout, deadlock, or serialization failure.
- Never automatically retry an ambiguous transport timeout, permission denial,
  or explicit cancellation. Delays honor task cancellation.
- Present a localized busy message when retries are exhausted and show errors
  in the Secondhand detail deletion handler, which previously swallowed them.
- Add four missing foreign-key lookup indexes for deletion cascades. Their
  absence is a scaling risk, not evidence that it caused this particular timeout.

Migration `20260907031338_index_post_deletion_dependencies.sql` was applied locally
and in production. Eight database checks passed: indexes, ownership rejection,
preservation after rejection, owner deletion, metadata cascade, cleanup queue,
and idempotent repeat. Production verification confirmed all four indexes,
both reported posts still present, and no diagnostic posts retained.

Swift regression tests exercise transient failure recovery, retry exhaustion,
and non-retry of ambiguous network outcomes/permission errors/cancellation.
App and test bundles compile, and the share-worker syntax check passed.
Client retry and message changes require installing the new app build.
