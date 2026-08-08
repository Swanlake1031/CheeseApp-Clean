-- Restrict official identity bootstrap to trusted backend callers.
--
-- Supabase's function privilege hook grants new public-schema functions to
-- API roles directly. Revoking PUBLIC alone therefore does not remove the
-- explicit anon/authenticated grants created when migration 097 ran.

BEGIN;

REVOKE ALL ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  TO service_role;

-- This function is invoked by its trigger and is not a public API endpoint.
REVOKE ALL ON FUNCTION public.guard_profile_official_identity()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
