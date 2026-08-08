-- 146_remove_profile_graduation_feature.sql
--
-- Removes the graduated-profile product interaction while retaining the
-- historical column as a false-only compatibility tombstone for schema caches.
--
-- Deleted data: any TRUE graduation preferences previously saved on profiles.
-- Rollback limit: previous graduation selections cannot be reconstructed.
-- Backup requirement: no backup is required because the product no longer uses
-- this preference; export the affected profile ids first only for audit needs.
-- Production order: apply before shipping clients that remove the graduated
-- option and return to the six-argument complete_profile RPC.

BEGIN;

UPDATE public.profiles
SET is_graduated = FALSE
WHERE is_graduated = TRUE;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_graduation_feature_removed_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_graduation_feature_removed_check
  CHECK (is_graduated = FALSE);

DROP FUNCTION IF EXISTS public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
);

COMMIT;
