-- 141_release_school_binding_on_deactivation.sql
--
-- Account deactivation must release the private McMaster email identity so the
-- same school address can be verified by a future account.
--
-- Deleted data: pending McMaster email challenges and verified McMaster email
-- bindings belonging to already-deactivated or newly-deactivated accounts.
-- Rollback limit: deleted verification secrets and bindings cannot be restored
-- by rolling this migration back.
-- Backup requirement: export the two private verification tables first only if
-- an external audit policy requires retention; the product must not restore
-- these bindings to deactivated accounts.
-- Production order: apply before shipping account-deactivation builds that
-- promise immediate release of the school email binding.

BEGIN;

CREATE OR REPLACE FUNCTION public.protect_mcmaster_verification_flag()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.role() IS DISTINCT FROM 'service_role'
     AND NEW.is_mcmaster_verified IS DISTINCT FROM OLD.is_mcmaster_verified
     AND NOT (
       NEW.deactivated_at IS NOT NULL
       AND NEW.is_mcmaster_verified = FALSE
     ) THEN
    RAISE EXCEPTION 'McMaster verification is server managed'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_mcmaster_binding_on_deactivation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  DELETE FROM public.mcmaster_email_challenges
  WHERE user_id = NEW.id;

  DELETE FROM public.mcmaster_student_verifications
  WHERE user_id = NEW.id;

  UPDATE public.profiles
  SET is_mcmaster_verified = FALSE
  WHERE id = NEW.id
    AND is_mcmaster_verified = TRUE;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.release_mcmaster_binding_on_deactivation()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS release_mcmaster_binding_on_deactivation
  ON public.profiles;
CREATE TRIGGER release_mcmaster_binding_on_deactivation
AFTER UPDATE OF deactivated_at ON public.profiles
FOR EACH ROW
WHEN (
  NEW.deactivated_at IS NOT NULL
  AND OLD.deactivated_at IS DISTINCT FROM NEW.deactivated_at
)
EXECUTE FUNCTION public.release_mcmaster_binding_on_deactivation();

DELETE FROM public.mcmaster_email_challenges challenge
USING public.profiles profile
WHERE challenge.user_id = profile.id
  AND profile.deactivated_at IS NOT NULL;

DELETE FROM public.mcmaster_student_verifications verification
USING public.profiles profile
WHERE verification.user_id = profile.id
  AND profile.deactivated_at IS NOT NULL;

UPDATE public.profiles
SET is_mcmaster_verified = FALSE
WHERE deactivated_at IS NOT NULL
  AND is_mcmaster_verified = TRUE;

COMMIT;
