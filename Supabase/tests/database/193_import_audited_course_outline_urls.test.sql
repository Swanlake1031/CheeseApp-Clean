BEGIN;

SELECT plan(12);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines),
  393::BIGINT,
  '393 reviewed official outline URLs are published'
);

SELECT is(
  (SELECT COUNT(DISTINCT course_id) FROM public.course_external_outlines),
  381::BIGINT,
  'published URLs cover 381 distinct catalog courses'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_kind = 'external_web'),
  115::BIGINT,
  '115 Simple Syllabus documents remain available'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_kind = 'external_pdf'),
  278::BIGINT,
  '278 reviewed direct PDF links are available'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_name = 'engineering_technology'),
  100::BIGINT,
  '100 reviewed Engineering Technology PDFs are published'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_name = 'engineering_chemical'),
  12::BIGINT,
  '12 reviewed Chemical Engineering PDFs are published'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_external_outlines outline
   JOIN public.courses course ON course.id = outline.course_id
   WHERE course.code IN (
     'COMMERCE 4EL3', 'COMMERCE 4SY3', 'COMPSCI 4Z03', 'IBEHS 4E09A',
     'MECHTRON 4RP3', 'NUCENG 4P03', 'SFWRENG 4RP3'
   )),
  0::BIGINT,
  'proposal forms, an assessment form, and a dead URL stay unpublished'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_external_outlines outline
   JOIN public.courses course ON course.id = outline.course_id
   WHERE course.code IN (
     'CHEMENG 4A03', 'CHEMENG 4Y04A', 'ENGPHYS 4H04A',
     'IBEHS 3H03', 'IBEHS 4H03'
   )),
  0::BIGINT,
  'five unresolved academic-term candidates stay unpublished'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.courses
   WHERE subject IN (
     'CHEMENG', 'CIVTECH', 'ENGTECH', 'ENRTECH', 'GENTECH',
     'MANTECH', 'PROCTECH', 'SFWRTECH', 'SMRTTECH'
   )),
  (SELECT COUNT(*)
   FROM public.courses
   WHERE subject IN (
     'CHEMENG', 'CIVTECH', 'ENGTECH', 'ENRTECH', 'GENTECH',
     'MANTECH', 'PROCTECH', 'SFWRTECH', 'SMRTTECH'
   ) AND year_level BETWEEN 1 AND 5),
  'new Engineering Technology subjects satisfy the catalog constraints'
);

SELECT is(
  (SELECT COUNT(*)
   FROM (
     SELECT course_id, source_url
     FROM public.course_external_outlines
     GROUP BY course_id, source_url
     HAVING COUNT(*) > 1
   ) duplicate),
  0::BIGINT,
  'the audited import creates no duplicate course URLs'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE last_verified_at IS NULL),
  0::BIGINT,
  'every audited URL has a verification timestamp'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_outlines WHERE storage_path IS NULL),
  0::BIGINT,
  'the private Storage outline contract remains unchanged'
);

SELECT * FROM finish();

ROLLBACK;
