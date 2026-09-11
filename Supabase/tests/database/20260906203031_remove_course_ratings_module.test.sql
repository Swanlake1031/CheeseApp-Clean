BEGIN;
SELECT plan(4);
SELECT is((SELECT count(*) FROM pg_tables WHERE schemaname = 'public'
  AND tablename IN ('courses', 'professors', 'course_reviews', 'course_outlines',
    'course_external_outlines', 'course_catalog_offerings', 'course_professors', 'academic_terms')),
  0::BIGINT, 'all course tables and their data are removed');
SELECT is((SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('get_course_catalog', 'get_course_catalog_v2', 'get_course_review_snapshot',
    'delete_course_review', 'upsert_course_review')), 0::BIGINT, 'course RPCs are removed');
SELECT is((SELECT count(*) FROM storage.buckets WHERE id = 'course-outlines'),
  0::BIGINT, 'course PDF bucket is removed');
SELECT ok(to_regclass('public.posts') IS NOT NULL AND to_regclass('public.profiles') IS NOT NULL
  AND to_regclass('public.forum_posts') IS NOT NULL AND to_regclass('public.secondhand_posts') IS NOT NULL,
  'shared accounts, forum and marketplace remain available');
SELECT * FROM finish();
ROLLBACK;
