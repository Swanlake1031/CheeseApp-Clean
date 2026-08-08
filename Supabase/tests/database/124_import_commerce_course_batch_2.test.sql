BEGIN;

SELECT plan(19);

CREATE TEMP TABLE expected_commerce_batch_2 (
  id UUID NOT NULL,
  code TEXT NOT NULL,
  title TEXT NOT NULL,
  year_level SMALLINT NOT NULL,
  professor_count INTEGER NOT NULL,
  outline_year SMALLINT NOT NULL,
  outline_term TEXT NOT NULL,
  outline_size BIGINT NOT NULL,
  outline_sha256 TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO expected_commerce_batch_2
VALUES
  (
    '090f5eec-c94e-5f7e-93b1-a2f8aaeff0e6',
    'COMMERCE 2DA3',
    'Decision Making with Analytics',
    2::SMALLINT,
    2,
    2025::SMALLINT,
    'fall',
    347814::BIGINT,
    '11a1127a83a28a0c797308689a3fbe15da9761f94ab38c1430d64ade2b9d5d04'
  ),
  (
    '6b0a04df-808a-5852-a43a-974e89fddaa6',
    'COMMERCE 2GR0',
    'DeGroote Student Experience and Development II',
    2::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    385554::BIGINT,
    '0a6ad9ecf20f74bbcde2a937a10377fff5a064ef2626f14603ca514eff6caf10'
  ),
  (
    '4f3fd9b3-dd2f-514b-a383-5adf2c7b8f26',
    'COMMERCE 2IN0',
    'Career Development Course',
    2::SMALLINT,
    4,
    2026::SMALLINT,
    'winter',
    381959::BIGINT,
    'd8615323d99279129bdfd471a546ff5ab4145fae23567e90a89868151504fb6e'
  ),
  (
    '6bc3f9a0-e03a-5a9d-8d10-a983ff6e78f6',
    'COMMERCE 2NG3',
    'Negotiations',
    2::SMALLINT,
    3,
    2025::SMALLINT,
    'fall',
    317460::BIGINT,
    '79fb91c6b54af40cc924cbbaea8171dd4d0a6f0184b416f513e3857f90392c4e'
  ),
  (
    'efae50c0-c008-5951-a376-20aeecc59b9c',
    'COMMERCE 2OC3',
    'Operations Management',
    2::SMALLINT,
    2,
    2026::SMALLINT,
    'winter',
    1337028::BIGINT,
    'e8b5de689c2924407eb5a9fd1bb28d99b811a523ed1f5df8dafaff808b02e695'
  ),
  (
    '523023d5-efc8-5080-8ea5-bc05f8826a37',
    'COMMERCE 3AB3',
    'Intermediate Financial Accounting I',
    3::SMALLINT,
    2,
    2025::SMALLINT,
    'fall',
    594758::BIGINT,
    '00d04673cfc13e9798453f6f78592f79a46a646bf5857e581222c6288b89eaae'
  ),
  (
    '13593b6b-2fb0-5361-8f69-d2a860f7497d',
    'COMMERCE 3AC3',
    'Intermediate Financial Accounting II',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    295540::BIGINT,
    '29c79d96bd0260066ca11a49cafdadea38f65b797f098a9bf086404a792377a5'
  ),
  (
    'ed9df52e-89ca-5445-8bb1-c13634c1ba36',
    'COMMERCE 3DA3',
    'Predictive Analytics',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    175642::BIGINT,
    '91901dbc398b6b4604b50b55f1b2e0f2475af42613f8c708c56bfbb018354115'
  ),
  (
    'c0c133fb-e42c-5001-9b74-0326f2a667c7',
    'COMMERCE 3FB3',
    'Securities Analysis',
    3::SMALLINT,
    2,
    2026::SMALLINT,
    'winter',
    245880::BIGINT,
    '5c494ec0c80e44f3431c645616fc053b75fcccab126bfd9ca5a123dee30d5ed2'
  ),
  (
    'f4a0f3ed-a4f2-5bd2-8e8a-7040ce78e228',
    'COMMERCE 3FD3',
    'Financial Modelling',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    171865::BIGINT,
    '9a59f67c98b0d2999c746fcddaf00863c3eda8e2743a761e9c8ca281f8de7487'
  ),
  (
    '43e1c98c-9528-5910-b3ac-3f99a03a1f75',
    'COMMERCE 3FH3',
    'Alternative Investments and Portfolio Management',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    273313::BIGINT,
    '29074d9f05f1a16556fcbab4298f96b265b2d87273dc996fdbcb1cf7e2fc6292'
  ),
  (
    'a895c600-f660-5d40-ae65-a47a3714106d',
    'COMMERCE 3FI3',
    'Market Trading with Options and Futures',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    386988::BIGINT,
    'b43c921ec58fe11e09c1b5782946fd2e3e933edefbb874ceda2b79c7d44fc53b'
  ),
  (
    '8bf11b18-707a-5c00-83ce-15f7cbad1da0',
    'COMMERCE 3FK3',
    'Intermediate Corporate Finance',
    3::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    571996::BIGINT,
    '7d14e7b7c3c07a5d355f1493592eaedd38f3dd0dc9c8851631c1f815fc7e8fae'
  ),
  (
    '685e0de1-39e8-5e0c-9f62-8f283754777c',
    'COMMERCE 3FM3',
    'The History of Finance',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    306266::BIGINT,
    '6b139edb808cfac369da177827063b1c927cf71cb86d81d7d11bf2cb584b6b9e'
  ),
  (
    '9d96fe46-f27e-5414-81c7-c5a5fdaff398',
    'COMMERCE 3KA3',
    'System Analysis and Design',
    3::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    300728::BIGINT,
    'd306543a16c6f6eaeb8d3a76a85c5439c06a1a454113a99cddb5ebc51590d065'
  ),
  (
    'acfa9902-27d9-52ec-aecd-28fcd5f56fc4',
    'COMMERCE 3KD3',
    'Database Design Management and Applications',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    389265::BIGINT,
    '50e4d6ae92b8d25b208a5f8cd6739e2dfcee4c09c87da98728b1f99890145453'
  ),
  (
    '55ede7dc-ab76-591c-95cc-75621829d02c',
    'COMMERCE 3MB3',
    'Consumer Behaviour',
    3::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    417039::BIGINT,
    '8de1585419343e2bbbcd91966467729ee980c3515e709318304f3a95d67dbdc9'
  ),
  (
    'c7dbbf55-d35a-5272-ae25-e14d76a3a762',
    'COMMERCE 3MC3',
    'Applied Marketing Management',
    3::SMALLINT,
    3,
    2026::SMALLINT,
    'winter',
    481630::BIGINT,
    'e22f00d75ecd99221f8c3b6c5ab57e4e1f55dda5e2f90c379101e7de88679da5'
  ),
  (
    'bbe11765-bbc5-564c-92c9-7d6b1f98645d',
    'COMMERCE 3MD3',
    'Introduction to Contemporary Applied Marketing',
    3::SMALLINT,
    1,
    2023::SMALLINT,
    'winter',
    691751::BIGINT,
    'd8e2044eab2a69406f58c699dc4fd24c5064219f5483df577a56ce2b99db94c4'
  ),
  (
    '9cd88f06-6256-5eec-895d-acf8f492774d',
    'COMMERCE 3SO3',
    'Management Skills Development',
    3::SMALLINT,
    3,
    2023::SMALLINT,
    'winter',
    286263::BIGINT,
    '35ef763dd5bf52c56d17d3c88e2dd4a4a4a97575c2ecef2fa30ad4e6136ffafe'
  );

GRANT SELECT ON expected_commerce_batch_2 TO authenticated;

SELECT is((SELECT count(*) FROM expected_commerce_batch_2), 20::BIGINT,
  'the batch contains its reviewed course count');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_2 AS expected
  JOIN public.courses AS course
    ON course.id = expected.id
   AND course.code = expected.code
   AND course.title = expected.title
   AND course.subject = 'COMMERCE'
   AND course.year_level = expected.year_level
), 20::BIGINT, 'all courses use normalized catalog metadata');

SELECT is((
  SELECT count(DISTINCT course.code)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_2)
), 20::BIGINT, 'the import creates no duplicate course codes');

SELECT is((
  SELECT count(*)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_2)
    AND course.code = upper(btrim(course.code))
    AND course.subject = 'COMMERCE'
), 20::BIGINT, 'course codes and faculty subject are normalized');

SELECT is((
  SELECT count(*)
  FROM public.course_professors AS mapping
  JOIN expected_commerce_batch_2 AS expected ON expected.id = mapping.course_id
), 33::BIGINT, 'every verified instructor mapping is present');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_2 AS expected
  WHERE expected.professor_count = (
    SELECT count(*) FROM public.course_professors AS mapping
    WHERE mapping.course_id = expected.id
  )
), 20::BIGINT, 'each course exposes the exact selected-term professor set');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_2 AS expected
  JOIN public.course_outlines AS outline
    ON outline.course_id = expected.id
   AND outline.academic_year = expected.outline_year
   AND outline.term = expected.outline_term
   AND outline.file_size_bytes = expected.outline_size
   AND outline.sha256 = expected.outline_sha256
   AND outline.mime_type = 'application/pdf'
   AND outline.storage_path = expected.id::TEXT || '/' ||
       expected.outline_year::TEXT || '/' || expected.outline_term || '/' ||
       expected.outline_sha256 || '.pdf'
), 20::BIGINT, 'every PDF has exact hash-bound private Storage metadata');

SELECT is((
  SELECT count(*)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_2 AS expected ON expected.id = outline.course_id
), 20::BIGINT, 'the batch registers exactly one outline per course');

SELECT ok((
  SELECT bool_and(outline.file_size_bytes <= 20971520)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_2 AS expected ON expected.id = outline.course_id
), 'all selected assets satisfy the existing outline size contract');

SELECT is((SELECT public FROM storage.buckets WHERE id = 'course-outlines'), FALSE,
  'Commerce outlines remain in the shared private bucket');

SELECT is((
  SELECT count(*)
  FROM storage.objects AS object
  JOIN expected_commerce_batch_2 AS expected
    ON object.bucket_id = 'course-outlines'
   AND object.name = expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
       expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
), 20::BIGINT, 'all immutable PDFs were seeded into local Storage');

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT is((SELECT count(*) FROM public.get_course_catalog()
  WHERE code IN (SELECT code FROM expected_commerce_batch_2)),
  20::BIGINT, 'authenticated discovery returns every batch course');

SELECT is((
  SELECT count(*)
  FROM public.get_course_catalog() AS catalog
  JOIN expected_commerce_batch_2 AS expected ON expected.id = catalog.id
  WHERE jsonb_array_length(catalog.professors) = expected.professor_count
), 20::BIGINT, 'discovery exposes exact professor filters');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_2 AS expected
  WHERE jsonb_array_length(public.get_course_review_snapshot(expected.id)->'professors') =
        expected.professor_count
), 20::BIGINT, 'every course loads the shared review editor professor data');

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config('request.jwt.claim.role', 'anon', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
SET LOCAL ROLE anon;

SELECT ok(NOT has_function_privilege('anon', 'public.get_course_catalog()', 'EXECUTE'),
  'anonymous discovery remains denied');

SELECT is((SELECT count(*) FROM storage.objects WHERE bucket_id = 'course-outlines'),
  0::BIGINT, 'anonymous users cannot read private outline objects');

RESET ROLE;

SELECT is(
  (SELECT title FROM public.courses WHERE code = 'COMMERCE 1AA3'),
  'Introductory Financial Accounting',
  'the full reconciliation corrects the 1AA3 catalog title forward-only'
);

SELECT is(
  (SELECT title FROM public.courses WHERE code = 'COMMERCE 2AB3'),
  'Managerial Accounting I',
  'the full reconciliation corrects the 2AB3 catalog title forward-only'
);

SELECT is(
  (SELECT count(*) FROM public.course_professors AS cp
   JOIN public.courses AS c ON c.id = cp.course_id
   WHERE c.code = 'COMMERCE 2BC3'),
  2::BIGINT,
  'the full Winter 2026 reconciliation connects both 2BC3 instructors'
);

SELECT * FROM finish();
ROLLBACK;
