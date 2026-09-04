BEGIN;

SELECT plan(15);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE id IN (
     '1f2ae6af-2020-578e-8103-ad7db3bcb364',
     '31088d7f-0a56-5b7a-936d-fa1b42f2953d',
     'd74acb74-8046-55ca-97f6-1790f9a10e52'
   ) AND source_kind = 'external_pdf'),
  3::BIGINT,
  'three current DeGroote outlines use direct official PDF URLs'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE id IN (
     '50b6fb81-6e29-5f79-ac34-d0562a072488',
     'ae1d9b1a-2873-5ed5-944f-de99ca397c3c',
     '693c7c37-f820-5121-bddb-b205d2e52472',
     'f4702e02-4d78-5cf5-86f4-21c09a976511',
     'b91a8389-e3de-561e-8e12-a84f28ca470d',
     '4348a8f4-5c05-54d7-8cf5-53b37a406bb2',
     '7c8352e6-c912-5afa-ac2e-fff887907d8e'
   ) AND source_kind = 'external_web'),
  7::BIGINT,
  'seven Simple Syllabus outlines use official web URLs'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_outlines WHERE storage_path IS NULL),
  0::BIGINT,
  'the backward-compatible private outline contract remains unchanged'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_url !~ '^https://([a-z0-9-]+\.)*(mcmaster\.ca|simplesyllabusca\.com)(/|$)'),
  0::BIGINT,
  'every external outline uses an allowed official HTTPS host'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE id IN (
     '1f2ae6af-2020-578e-8103-ad7db3bcb364',
     '31088d7f-0a56-5b7a-936d-fa1b42f2953d',
     '50b6fb81-6e29-5f79-ac34-d0562a072488',
     'd74acb74-8046-55ca-97f6-1790f9a10e52',
     'ae1d9b1a-2873-5ed5-944f-de99ca397c3c',
     '693c7c37-f820-5121-bddb-b205d2e52472',
     'f4702e02-4d78-5cf5-86f4-21c09a976511',
     'b91a8389-e3de-561e-8e12-a84f28ca470d',
     '4348a8f4-5c05-54d7-8cf5-53b37a406bb2',
     '7c8352e6-c912-5afa-ac2e-fff887907d8e'
   )),
  10::BIGINT,
  'all ten reviewed current URLs are imported'
);

SELECT is(
  (SELECT COUNT(*) FROM public.courses
   WHERE code IN ('COMMERCE 1E03', 'COMMERCE 2CO0', 'ECON 1ME3', 'ECON 3B03')),
  4::BIGINT,
  'four newly catalogued Commerce and ECON courses exist'
);

SELECT is(
  (SELECT COUNT(*)
   FROM public.course_professors course_professor
   JOIN public.courses course ON course.id = course_professor.course_id
   WHERE (course.code, course_professor.professor_id) IN (
     ('COMMERCE 1E03', '99d1523f-abc3-5933-821b-cbe0e6eb18fb'::UUID),
     ('ECON 1ME3', 'fa000000-0000-4000-8000-000000000008'::UUID),
     ('ECON 2A03', 'fa000000-0000-4000-8000-000000000009'::UUID),
     ('ECON 2Z03', 'fa000000-0000-4000-8000-000000000011'::UUID),
     ('ECON 3B03', 'fa000000-0000-4000-8000-000000000011'::UUID),
     ('ECON 3H03', 'ecd32005-1d84-5f96-9638-49b9db87c9fc'::UUID)
   )),
  6::BIGINT,
  'verified current instructors are connected to their courses'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines outline
   JOIN public.courses course ON course.id = outline.course_id
   WHERE course.code LIKE 'ECON %'
     AND outline.academic_year = 2026
     AND outline.term = 'fall'
     AND outline.source_kind = 'external_web'),
  6::BIGINT,
  'six Fall 2026 ECON Simple Syllabus pages are available'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines outline
   JOIN public.courses course ON course.id = outline.course_id
   WHERE course.code IN ('COMMERCE 1BA3', 'COMMERCE 4SD3')
     AND outline.academic_year = 2026
     AND outline.term = 'summer'
     AND outline.source_kind = 'external_pdf'),
  2::BIGINT,
  'newer Summer 2026 Commerce PDFs supplement existing Winter copies'
);

SELECT throws_ok(
  $$
    INSERT INTO public.course_external_outlines (
      course_id, academic_year, term, title, source_kind, source_url,
      source_name, mime_type
    )
    SELECT id, 2026, 'fall', 'Untrusted outline', 'external_web',
      'https://example.com/outline', 'test', 'text/html'
    FROM public.courses WHERE code = 'ECON 1B03'
  $$,
  '23514', NULL,
  'non-official external hosts are rejected'
);

SELECT throws_ok(
  $$
    INSERT INTO public.course_external_outlines (
      course_id, academic_year, term, title, source_kind, source_url,
      source_name, mime_type
    )
    SELECT id, 2026, 'fall', 'Mismatched mime', 'external_web',
      'https://economics.mcmaster.ca/outline', 'test', 'application/pdf'
    FROM public.courses WHERE code = 'ECON 1B03'
  $$,
  '23514', NULL,
  'external web rows cannot claim the PDF mime type'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.course_external_outlines', 'SELECT'),
  'authenticated clients can read external outline metadata'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.course_external_outlines', 'SELECT'),
  'anonymous clients cannot enumerate external outlines'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE last_verified_at IS NULL),
  0::BIGINT,
  'imported external URLs have a verification timestamp'
);

SELECT is(
  (SELECT relrowsecurity FROM pg_class
   WHERE oid = 'public.course_external_outlines'::regclass),
  TRUE,
  'row-level security is enabled on external outlines'
);

SELECT * FROM finish();

ROLLBACK;
