# Rollback

To restore V1 eligibility while keeping the original semantic ranker active:

```sql
UPDATE public.cross_school_configuration SET gate_enabled=false WHERE singleton;
```

The trigger automatically increments the policy revision. Filtered sessions
become stale; the new App retries once with a fresh session. Scores, embeddings,
models, posts and audit data remain intact. This behavior is regression-tested.

To restore the exact pre-release user-visible legacy path (its rollout was 0%):

```sql
BEGIN;
UPDATE public.cross_school_configuration
SET gate_enabled=false, scoring_enabled=false, shadow_enabled=false WHERE singleton;
UPDATE public.recommendation_configuration SET rollout_percentage=0 WHERE singleton;
COMMIT;
```

Use an authorized backend connection, not an App client. Read back both
configuration rows afterward. Do not drop schema or revert unrelated worktree
changes as operational rollback. Existing App binaries lack V2 contract opt-in;
the newly integrated build is required for the complete V2 recommendation path.
