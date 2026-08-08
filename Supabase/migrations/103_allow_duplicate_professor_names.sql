-- Treat a professor's UUID, not their display name, as the identity.
--
-- This migration is non-destructive: it removes only the global uniqueness
-- requirement from professors.name and does not rewrite professor, course, or
-- review rows.
--
-- Rollback limit:
-- - Re-adding professors_name_key is possible only while no duplicate names
--   exist. Once two distinct professors share a name, a rollback must first
--   choose whether to merge, rename, or otherwise disambiguate those records.

BEGIN;

ALTER TABLE public.professors
  DROP CONSTRAINT professors_name_key;

-- Preserve an index suitable for catalog ordering and operational name lookup
-- without treating a mutable display label as a unique identity.
CREATE INDEX professors_name_id_idx
  ON public.professors (name, id);

COMMENT ON COLUMN public.professors.name IS
  'Professor display name. Names are not identities and may be shared by multiple professor UUIDs.';

NOTIFY pgrst, 'reload schema';

COMMIT;
