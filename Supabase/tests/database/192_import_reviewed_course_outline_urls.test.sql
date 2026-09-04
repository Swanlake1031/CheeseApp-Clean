BEGIN;

SELECT plan(17);

SELECT cmp_ok(
  (SELECT COUNT(*) FROM public.course_external_outlines),
  '>=',
  241::BIGINT,
  'at least the first 241 reviewed official outline URLs remain present'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_kind = 'external_web'),
  115::BIGINT,
  '115 reviewed Simple Syllabus pages are present'
);

SELECT cmp_ok(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_kind = 'external_pdf'),
  '>=',
  126::BIGINT,
  'at least the first 126 reviewed direct PDF links remain present'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_name = 'McMaster Simple Syllabus'),
  115::BIGINT,
  'Simple Syllabus provenance is retained'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_name = 'degroote_commerce'),
  53::BIGINT,
  '53 reviewed DeGroote document links are present'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_name = 'cas_macdrive'),
  38::BIGINT,
  '38 reviewed Computing and Software links are present'
);

SELECT cmp_ok(
  (SELECT COUNT(DISTINCT course_id) FROM public.course_external_outlines),
  '>=',
  229::BIGINT,
  'reviewed links still cover at least the first 229 catalog courses'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE academic_year IS NULL OR term IS NULL),
  0::BIGINT,
  'every published row has a verified academic term'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE source_url !~ '^https://([a-z0-9-]+\.)*(mcmaster\.ca|simplesyllabusca\.com)(/|$)'),
  0::BIGINT,
  'every published row uses an allowed official HTTPS host'
);

SELECT is(
  (SELECT COUNT(*)
   FROM (
     SELECT course_id, source_url
     FROM public.course_external_outlines
     GROUP BY course_id, source_url
     HAVING COUNT(*) > 1
   ) duplicates),
  0::BIGINT,
  'no course contains a duplicate external document URL'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_external_outlines
   WHERE (source_kind = 'external_pdf' AND mime_type <> 'application/pdf')
      OR (source_kind = 'external_web' AND mime_type <> 'text/html')),
  0::BIGINT,
  'source kinds use the expected MIME type'
);

SELECT is(
  (SELECT COUNT(*) FROM public.course_outlines WHERE storage_path IS NULL),
  0::BIGINT,
  'the existing private Storage outline contract is still unchanged'
);

SELECT ok(
  has_function_privilege(
    'authenticated', 'public.get_course_catalog_v2()', 'EXECUTE'
  ),
  'authenticated clients can call the extended catalog'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.get_course_catalog_v2()', 'EXECUTE'),
  'anonymous clients cannot call the extended catalog'
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
  (SELECT COUNT(*) FROM public.get_course_catalog_v2()),
  (SELECT COUNT(*) FROM public.courses),
  'the V2 catalog returns every imported subject'
);

SELECT is(
  (SELECT COUNT(*) FROM public.get_course_catalog()),
  (SELECT COUNT(*) FROM public.courses
   WHERE subject IN ('MATH', 'STATS', 'ECON', 'COMMERCE')),
  'the V1 catalog remains restricted to old-client subject values'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.get_course_catalog_v2()
    WHERE subject IN ('BIOLOGY', 'CHEM', 'PHYSICS', 'PSYCH', 'SFWRENG')
  ),
  'the extended catalog exposes requested science and engineering subjects'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
