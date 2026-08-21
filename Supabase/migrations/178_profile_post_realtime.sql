-- 178_profile_post_realtime.sql
--
-- Let an already-open public profile reconcile its post list when that user
-- publishes, edits, hides, restores, archives, or deletes a post on another
-- device. Existing post RLS remains the visibility boundary for subscribers.

BEGIN;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.posts;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END
$$;

COMMIT;
