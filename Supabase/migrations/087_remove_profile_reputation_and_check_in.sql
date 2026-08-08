-- 087_remove_profile_reputation_and_check_in.sql
-- Retire the unused profile reputation, cheese energy, and daily check-in system.
--
-- Deleted data:
-- - All reputation summaries, balances, streaks, scores, and counters.
-- - All reputation ledger history.
--
-- Rollback:
-- - The deleted rows cannot be reconstructed by a down migration.
-- - Restore the two tables from a pre-migration export if this history must be retained.
--
-- Production order:
-- 1. Ship an app build with no reputation or check-in callers.
-- 2. Apply migrations 085 and 086.
-- 3. Apply this migration.

BEGIN;

DROP TRIGGER IF EXISTS profile_reputation_sync ON public.profiles;

DROP FUNCTION IF EXISTS public.claim_daily_cheese_check_in();
DROP FUNCTION IF EXISTS public.get_my_reputation_ledger(INTEGER);
DROP FUNCTION IF EXISTS public.get_my_reputation_summary();
DROP FUNCTION IF EXISTS public.handle_profile_reputation_sync();
DROP FUNCTION IF EXISTS public.ensure_user_reputation_summary(UUID);
DROP FUNCTION IF EXISTS public.apply_reputation_entry(
  UUID,
  TEXT,
  INTEGER,
  INTEGER,
  INTEGER,
  TEXT,
  JSONB,
  BOOLEAN
);
DROP FUNCTION IF EXISTS public.reputation_level_info(INTEGER);

DROP VIEW IF EXISTS public.public_user_credit_summary_view;
DROP FUNCTION IF EXISTS public.public_user_credit_summary_rows();

DROP TABLE IF EXISTS public.user_reputation_ledger;
DROP TABLE IF EXISTS public.user_reputation_summary;

NOTIFY pgrst, 'reload schema';

COMMIT;
