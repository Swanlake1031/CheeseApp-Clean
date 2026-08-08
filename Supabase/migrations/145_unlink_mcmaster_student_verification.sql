-- 145_unlink_mcmaster_student_verification.sql
--
-- Lets the authenticated Edge Function release a user's McMaster student
-- verification after the user confirms the unlink action in the app.
--
-- Deleted data: the selected user's verified McMaster email binding and any
-- pending McMaster email challenge rows.
-- Rollback limit: deleted verification bindings and challenge secrets cannot be
-- reconstructed by rolling this migration back; the user must verify again.
-- Backup requirement: no product backup is required because unlink is an
-- explicit user action. Export private verification tables first only when an
-- external audit or retention policy requires it.
-- Production order: apply this migration before deploying the Edge Function
-- version that accepts the `unlink` action.

BEGIN;

CREATE OR REPLACE FUNCTION public.unlink_mcmaster_student_verification(
  p_user_id UUID
)
RETURNS TABLE(unlinked BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_had_binding BOOLEAN;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User id is required' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.mcmaster_student_verifications verification
    WHERE verification.user_id = p_user_id
  ) OR EXISTS (
    SELECT 1
    FROM public.profiles profile
    WHERE profile.id = p_user_id
      AND profile.is_mcmaster_verified = TRUE
  )
  INTO v_had_binding;

  DELETE FROM public.mcmaster_email_challenges
  WHERE user_id = p_user_id;

  DELETE FROM public.mcmaster_student_verifications
  WHERE user_id = p_user_id;

  UPDATE public.profiles
  SET is_mcmaster_verified = FALSE,
      updated_at = clock_timestamp()
  WHERE id = p_user_id
    AND is_mcmaster_verified = TRUE;

  RETURN QUERY SELECT v_had_binding;
END;
$$;

REVOKE ALL ON FUNCTION public.unlink_mcmaster_student_verification(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unlink_mcmaster_student_verification(UUID)
  TO service_role;

COMMIT;
