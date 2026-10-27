-- Preserve the existing optional-school contract for working profiles.
-- No rows are deleted or backfilled: existing Other values may be intentional.
-- Apply after university/profile-status migration 20260912041913; no client
-- rollout dependency. Use normal pre-deployment database backup procedures.
-- Rollback: a new migration can restore the previous trigger function; this
-- does not restore historical display choices or rewrite existing profiles.
BEGIN;

CREATE OR REPLACE FUNCTION public.sync_profile_school_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_school_name TEXT;
  v_default_campus_id UUID;
BEGIN
  IF NEW.school_id IS NOT NULL THEN
    SELECT s.name INTO v_school_name
    FROM public.schools s
    WHERE s.id = NEW.school_id;

    -- complete_profile deliberately keeps the public field empty when a
    -- working user omits school, while retaining the internal Other school ID.
    IF v_school_name IS NOT NULL
       AND NOT (NEW.profile_status = 'working' AND NEW.university IS NULL) THEN
      NEW.university := v_school_name;
    END IF;

    IF NEW.campus_id IS NULL THEN
      SELECT c.id INTO v_default_campus_id
      FROM public.school_campuses c
      WHERE c.school_id = NEW.school_id
        AND c.is_default = TRUE
      LIMIT 1;
      NEW.campus_id := COALESCE(NEW.campus_id, v_default_campus_id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;
