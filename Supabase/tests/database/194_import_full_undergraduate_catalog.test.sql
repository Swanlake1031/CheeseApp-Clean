BEGIN;

SELECT plan(15);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_catalog_offerings
   WHERE academic_year = 2026
     AND term = 'fall'
     AND academic_career = 'UGRD'),
  1604::BIGINT,
  'all 1,604 Fall 2026 undergraduate courses are published'
);

SELECT is(
  (SELECT COUNT(DISTINCT course.subject)
   FROM public.course_catalog_offerings AS offering
   JOIN public.courses AS course ON course.id = offering.course_id
   WHERE offering.academic_year = 2026
     AND offering.term = 'fall'
     AND offering.academic_career = 'UGRD'),
  127::BIGINT,
  'the full catalog exposes all 127 undergraduate subjects'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_catalog_offerings
   WHERE source_name <> 'McMaster MyTimetable'
      OR last_verified_at IS NULL),
  0::BIGINT,
  'every offering retains official source provenance and verification time'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_catalog_offerings AS offering
   JOIN public.courses AS course ON course.id = offering.course_id
   WHERE btrim(course.code) = '' OR btrim(course.title) = ''),
  0::BIGINT,
  'every offered course has a nonblank code and title'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_catalog_offerings AS offering
   JOIN public.courses AS course ON course.id = offering.course_id
   WHERE course.year_level NOT BETWEEN 1 AND 5),
  0::BIGINT,
  'every offered course has a supported undergraduate year level'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.academic_terms
    WHERE academic_year = 2026 AND term = 'fall'
  ),
  'Fall 2026 is available when submitting a course review'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.professors
    WHERE id = '00000000-0000-4000-8000-00000000c0de'::UUID
      AND name = 'Instructor not listed'
  ),
  'the neutral fallback professor exists'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.courses AS course
   WHERE NOT EXISTS (
     SELECT 1 FROM public.course_professors AS course_professor
     WHERE course_professor.course_id = course.id
   )),
  0::BIGINT,
  'every catalog course has a professor option and can enter the review flow'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_professors AS course_professor
   JOIN public.courses AS course ON course.id = course_professor.course_id
   WHERE course.code = 'ECON 1B03'
     AND course_professor.professor_id =
       '00000000-0000-4000-8000-00000000c0de'::UUID),
  0::BIGINT,
  'verified course-professor assignments are not mixed with the fallback'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.course_catalog_offerings AS offering
    WHERE NOT EXISTS (
      SELECT 1 FROM public.course_outlines AS outline
      WHERE outline.course_id = offering.course_id
    )
      AND NOT EXISTS (
        SELECT 1 FROM public.course_external_outlines AS outline
        WHERE outline.course_id = offering.course_id
      )
  ),
  'courses are published even when no PDF or external outline exists'
);

SELECT ok(
  has_table_privilege(
    'authenticated', 'public.course_catalog_offerings', 'SELECT'
  ),
  'authenticated clients can read offering metadata'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.course_catalog_offerings', 'SELECT'),
  'anonymous clients cannot read offering metadata'
);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT COUNT(*)
   FROM public.get_course_catalog_v2() AS catalog
   WHERE EXISTS (
     SELECT 1
     FROM public.course_catalog_offerings AS offering
     WHERE offering.course_id = catalog.id
       AND offering.academic_year = 2026
       AND offering.term = 'fall'
       AND offering.academic_career = 'UGRD'
   )),
  1604::BIGINT,
  'the V2 app catalog returns all current undergraduate offerings'
);

SELECT ok(
  jsonb_array_length(
    public.get_course_review_snapshot(
      (SELECT id FROM public.courses WHERE code = 'ABLD 3CD3')
    )->'professors'
  ) > 0,
  'a newly imported course has a professor option in its review snapshot'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      public.get_course_review_snapshot(
        (SELECT id FROM public.courses WHERE code = 'ABLD 3CD3')
      )->'academic_terms'
    ) AS term
    WHERE term->>'academic_year' = '2026'
      AND term->>'term' = 'fall'
  ),
  'a newly imported course can be reviewed for Fall 2026'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
