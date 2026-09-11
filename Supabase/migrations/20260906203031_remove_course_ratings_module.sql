-- Permanently retire course ratings at the user's explicit request.
-- Deletes courses, offerings, professor identities/assignments, academic terms,
-- private/external outlines, and all historical course reviews and ratings.
-- Production order: verify the course-free app build, remove every object in
-- the dedicated course-outlines bucket AND the bucket through the Storage API, then apply
-- this migration and ship the app. Released older apps lose course endpoints.
-- Backup requirement: any desired recovery copy must exist BEFORE Storage
-- deletion. No new copy of the requested-to-be-deleted reviews/PDFs is created.
-- Rollback: SQL rollback only works before COMMIT. Afterwards database recovery
-- requires a pre-removal backup/PITR; PDF recovery requires a separate object
-- backup. Historical migrations preserve schema history, not user reviews/PDFs.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'course-outlines') THEN
    RAISE EXCEPTION 'Empty course-outlines through the Storage API before retiring courses';
  END IF;
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'course-outlines') THEN
    RAISE EXCEPTION 'Delete the empty course-outlines bucket through the Storage API first';
  END IF;
END;
$$;

DROP POLICY IF EXISTS "Authenticated can view registered course outlines" ON storage.objects;

DROP FUNCTION IF EXISTS public.get_course_catalog();
DROP FUNCTION IF EXISTS public.get_course_catalog_v2();
DROP FUNCTION IF EXISTS public.get_course_review_snapshot(UUID);
DROP FUNCTION IF EXISTS public.delete_course_review(UUID);
DROP FUNCTION IF EXISTS public.upsert_course_review(UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID);

-- Deliberately use RESTRICT (the default): unexpected shared dependencies must
-- abort the transaction instead of being silently removed with CASCADE.
DROP TABLE IF EXISTS public.course_reviews;
DROP TABLE IF EXISTS public.course_external_outlines;
DROP TABLE IF EXISTS public.course_outlines;
DROP TABLE IF EXISTS public.course_catalog_offerings;
DROP TABLE IF EXISTS public.course_professors;
DROP TABLE IF EXISTS public.courses;
DROP TABLE IF EXISTS public.professors;
DROP TABLE IF EXISTS public.academic_terms;

NOTIFY pgrst, 'reload schema';

COMMIT;
