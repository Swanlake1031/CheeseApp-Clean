-- Temporarily disable cross-school recommendation filtering while the external
-- embedding/scoring provider remains unavailable for the 13+ App Store release.
-- This is a configuration-only rollback switch: V1 ranking, recommendation
-- sessions, pagination, stored scores, model artifacts and forum content remain
-- unchanged. Updating the configuration increments its revision through the
-- existing guard trigger, so sessions created under the gated policy are not
-- reused. Re-enable only through a later reviewed forward migration.
BEGIN;

UPDATE public.cross_school_configuration
SET gate_enabled = FALSE
WHERE singleton
  AND gate_enabled;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.cross_school_configuration
    WHERE singleton
      AND NOT gate_enabled
  ) THEN
    RAISE EXCEPTION 'Cross-school recommendation gate was not disabled';
  END IF;
END;
$$;

COMMIT;
