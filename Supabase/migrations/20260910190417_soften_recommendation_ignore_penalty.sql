-- Atomic ranking policy adjustment; no eligibility, feature, shaping or session changes.
-- Audited live ranker on 2026-09-10: migration 190 plus the V2 eligibility patch.
-- No data is deleted or rewritten. Existing fixed sessions keep their stored scores,
-- including penalties > 0.15; the historical storage constraint must remain valid.
-- New sessions use the revised penalty. Do not invalidate sessions or rename V1/V2.
-- Rollback: a NEW migration may reverse this exact expression after auditing drift;
-- neither direction retroactively rewrites persisted session items.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $patch$
DECLARE
 definition text;
 old_expression constant text := 'LEAST(0.45, 0.15 * GREATEST(0, eligible.ignored_count - 1))';
 new_expression constant text := 'LEAST(0.15, 0.05 * GREATEST(0, eligible.ignored_count - 1))';
BEGIN
 IF (SELECT md5(prosrc) FROM pg_proc
     WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure)
     IS DISTINCT FROM '9c118d72c1953fa9b05480d5833bfb85' THEN
  RAISE EXCEPTION 'Ranker drifted from audited V2 baseline; review before changing ignore penalty';
 END IF;
 SELECT pg_get_functiondef('public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure)
 INTO definition;
 IF (length(definition)-length(replace(definition,old_expression,''))) / length(old_expression) <> 1 THEN
  RAISE EXCEPTION 'Expected exactly one ignore penalty expression';
 END IF;
 -- pg_get_functiondef preserves signature, return columns, security and search_path.
 -- CREATE OR REPLACE also preserves ownership and existing grants.
 EXECUTE replace(definition,old_expression,new_expression);
 IF (SELECT md5(replace(prosrc,new_expression,old_expression)) FROM pg_proc
     WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure)
     IS DISTINCT FROM '9c118d72c1953fa9b05480d5833bfb85' THEN
  RAISE EXCEPTION 'Unexpected change outside the ignore penalty';
 END IF;
END;
$patch$;
COMMIT;
