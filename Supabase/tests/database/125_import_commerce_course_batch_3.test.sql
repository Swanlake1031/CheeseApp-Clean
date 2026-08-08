BEGIN;

SELECT plan(16);

CREATE TEMP TABLE expected_commerce_batch_3 (
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

INSERT INTO expected_commerce_batch_3
VALUES
  (
    'b6e6a608-4fad-5699-a468-7d8c7a28f967',
    'COMMERCE 4AA3',
    'Managerial Accounting II',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    435773::BIGINT,
    'c2d7ac85bcbc4106c663fee3d729afd79265c8833e679b4ec52aa280506b0c7d'
  ),
  (
    '9ab60091-6472-5611-8849-f1fdd63c5677',
    'COMMERCE 4AC3',
    'Advanced Financial Accounting',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    416709::BIGINT,
    'ffa90d7fae87a02052b03fcaac17322067a736bb962980b55f4d843e8a99cb00'
  ),
  (
    'c1f248b2-b8b4-56d0-a73d-15b517135cd3',
    'COMMERCE 4AF3',
    'Accounting Theory',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    378266::BIGINT,
    '88e6376b83c1cb4ddaf85d5c0633e42e02153619a407ae5b3c7c53648f702491'
  ),
  (
    '4076138c-68fd-5db3-aa2c-4164b9cc2cf1',
    'COMMERCE 4AK3',
    'Accounting Information for Decision Making',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'winter',
    220230::BIGINT,
    'c5b73c988ee2e84e39576d5ee9ba6b2f281aef5d515f8fcb8f2752094ffc31a7'
  ),
  (
    '36371648-e8b9-5a0a-982b-3bab344f3c94',
    'COMMERCE 4BB3',
    'Recruitment and Selection',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    146537::BIGINT,
    '980823733b349a95b781acc3e36d47382f6a3c2ef26ad8d52e43abc7e70f3faf'
  ),
  (
    'c203fac3-6e6d-56b8-adfb-f765c8c68e78',
    'COMMERCE 4BC3',
    'Collective Bargaining',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    474813::BIGINT,
    '94de0c1a46db60b36a333878fc3b4a780f557a0b1c9c33f592ce85e11c4c0c74'
  ),
  (
    '319f925d-3c2d-5d36-9850-39fb4f17d546',
    'COMMERCE 4BE3',
    'Strategic Compensation/Reward Systems',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    326032::BIGINT,
    '5a1a2e84a5822286fb2be89b6aa7929ba08b9e4b6b0b6f1eaa6e62356831cdb3'
  ),
  (
    '02f63f29-47ab-5b12-88c8-d590bc3a6380',
    'COMMERCE 4BF3',
    'Labour Law and Policy',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'winter',
    315323::BIGINT,
    'c3de34d4ed396dc85b8843717e5db593e4bd42cff62c01b30f2b970030c1c7f4'
  ),
  (
    '945c079a-b7c7-5601-a3d6-caceef871a03',
    'COMMERCE 4BI3',
    'Training and Development',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    967560::BIGINT,
    'a5bbc3087cd41dd41b4cc699d09a8ae2b658c5b9a2ae1e8cd6480ebe636cab91'
  ),
  (
    '6edc9f86-ecb1-5457-a158-ef617ca25df7',
    'COMMERCE 4BL3',
    'Occupational Health and Safety Management',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    398167::BIGINT,
    'e167c5b2646435debf445138bd287139bbf414718cfabdf3f25e2eb0e7e8d2ba'
  ),
  (
    'd42c74a4-6b10-58cc-982e-09e3c5a55236',
    'COMMERCE 4BM3',
    'Strategic Human Resource Planning',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    150347::BIGINT,
    '1b42ca13ba508c8eaaf67f3f2c1f42537735f1b66538558fdb1297a31394b277'
  ),
  (
    'd46a9323-083d-5adc-b1d0-a5886135e9b1',
    'COMMERCE 4BP3',
    'Principles of Leadership',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    470353::BIGINT,
    '7f2e095cfc5cacfc1cf6bfe0f59e405fdd667f88c442f4fcd96b454283f18aaa'
  ),
  (
    '34d50da7-6430-536c-b6d0-ac3ef3dd916b',
    'COMMERCE 4CA3',
    'Managing and Promoting Health and Healthcare Services',
    4::SMALLINT,
    1,
    2021::SMALLINT,
    'winter',
    219434::BIGINT,
    '952cdf0fb82f4b1d8264ae3608446f9a55747a0fda1c2ff66ae447ad9d5789f0'
  ),
  (
    '35be3104-54a0-51a8-8d9b-013276dc64c1',
    'COMMERCE 4DA3',
    'Modelling and Prescriptive Analytics',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    357115::BIGINT,
    '93af84ebd9c8d66124cc95b0b5cdeac97b0400965c12a357c4bd6086f9b5fbf4'
  ),
  (
    '2f2071b3-a5fa-572c-85d9-aef051bfb768',
    'COMMERCE 4FA3',
    'Applied Corporate Finance',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    329432::BIGINT,
    '5f01b6480c56714cccacc1e2714a1a69a491cbbbf8544952babf5d8be5bb26b8'
  ),
  (
    'a21aecdc-3ec4-5c50-9f80-5be75f5ca455',
    'COMMERCE 4FB3',
    'Valuation for Finance Professionals',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    455382::BIGINT,
    '6603151c53fc4e3981c7fbdcc234836e3141b0ab1aa0dd6c9912029afe61fb95'
  ),
  (
    '9a80a174-be90-5b42-b0c7-e4a8a33a5ba3',
    'COMMERCE 4FC3',
    'Ethics and Professional Practice in Finance',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    350799::BIGINT,
    '29ff170864cdf44c8401319f469fa005a5a16212774ee959cd3c849fcff657bd'
  ),
  (
    'a35ec800-9996-5322-8ba3-8a4b276e9ee6',
    'COMMERCE 4FD3',
    'Financial Institutions',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    375751::BIGINT,
    'd35d4e5baea59f942cd5948f8465fd1cf2fb266011ebe16a3d492c06083629ea'
  ),
  (
    '4c6d8fae-d625-59bb-a0d3-370bc5b22479',
    'COMMERCE 4FE3',
    'Options and Futures',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'winter',
    296310::BIGINT,
    'f63077bee0eea71bf3e8908c8698171d0737ee7711c912722f035577ddb80370'
  ),
  (
    'bfcf3c9d-a087-590e-b08e-d8883a1387f9',
    'COMMERCE 4FF3',
    'Portfolio Theory and Management',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    274610::BIGINT,
    '2b1128758ab5566461dd32fd37b2ea217ce364ccf7e9643d8738f8a2fe6c7200'
  ),
  (
    '1d3f0e64-d6be-50b6-9710-d890b41cb26a',
    'COMMERCE 4FG3',
    'Financial Theory',
    4::SMALLINT,
    1,
    2023::SMALLINT,
    'winter',
    121021::BIGINT,
    'c250bde93ec3e92b9a6785d5305ea281725fec7236bb303d32ebcb8040b36e62'
  ),
  (
    'a83e0070-ebd6-508d-9b54-43981e726fe2',
    'COMMERCE 4FH3',
    'Mergers, Acquisitions and Corporate Control',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    734328::BIGINT,
    '3de41ffd32d837e222851020c0ef226d93ce67427a0c3265cb6b8006555305dc'
  ),
  (
    '1a3e8e58-36c1-5028-8124-eb93673ba883',
    'COMMERCE 4FK3',
    'Financial Statement Analysis',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'winter',
    165079::BIGINT,
    'd7d7052a73bba1409ad7f6c85bd8c48b9e11960cd41ac361dbf5ada4dd647e1c'
  ),
  (
    '6b23b18f-6c5f-50b8-8089-09bc59959986',
    'COMMERCE 4FL3',
    'Personal Financial Management',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    357037::BIGINT,
    'e0638b0f1c24646b8ac9c29ca47c981eb8df94d0feba09fce319c743f5def891'
  ),
  (
    '22f7b586-bb6a-53e9-89ac-68b42f03ea2e',
    'COMMERCE 4FM3',
    'Personal Financial Planning and Advising',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    351300::BIGINT,
    '482344de1e70fa598628d54981f7a43b566e787ba38908ff6981e7ec935535ad'
  ),
  (
    'd70a91bb-c7a6-5824-b260-95c57c3ca5ea',
    'COMMERCE 4FN3',
    'Financial Risk Management',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    141134::BIGINT,
    '3500d54edbabcc483852f682590a69fde096b502156546ae98faabddcda38f84'
  ),
  (
    '9d645975-9018-5cc6-8dac-3c1e49efc771',
    'COMMERCE 4FO3',
    'Small Business and Entrepreneurial Finance',
    4::SMALLINT,
    1,
    2023::SMALLINT,
    'fall',
    336881::BIGINT,
    '90da5e0ef208b810ccc5ca368f189da331dda2857bef666dbd207c17c4759a10'
  ),
  (
    'bd0433ee-75d1-5e3d-a363-3604b4778d74',
    'COMMERCE 4FP3',
    'Personal Finance',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    328220::BIGINT,
    '0cd1218e3f2098346ba69237e82f48ff46114384fc897ef9375a8811919b4c26'
  ),
  (
    '5df6871a-eca2-5b92-8d78-86ff654f6819',
    'COMMERCE 4FQ3',
    'Working Capital Management',
    4::SMALLINT,
    1,
    2023::SMALLINT,
    'winter',
    569592::BIGINT,
    'bf05cd51a78f27efd59952a61528a2d119dbae140c077048cd9fa8a58880fdb7'
  ),
  (
    'f4238e45-f45e-5a6f-8aba-97fb3b3694be',
    'COMMERCE 4FR3',
    'Insurance and Risk Management',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    298760::BIGINT,
    '8992a07125534b86aacc54301a4ebc3ca1f302878746e464418ec538113f6209'
  );

GRANT SELECT ON expected_commerce_batch_3 TO authenticated;

SELECT is((SELECT count(*) FROM expected_commerce_batch_3), 30::BIGINT,
  'the batch contains its reviewed course count');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_3 AS expected
  JOIN public.courses AS course
    ON course.id = expected.id
   AND course.code = expected.code
   AND course.title = expected.title
   AND course.subject = 'COMMERCE'
   AND course.year_level = expected.year_level
), 30::BIGINT, 'all courses use normalized catalog metadata');

SELECT is((
  SELECT count(DISTINCT course.code)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_3)
), 30::BIGINT, 'the import creates no duplicate course codes');

SELECT is((
  SELECT count(*)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_3)
    AND course.code = upper(btrim(course.code))
    AND course.subject = 'COMMERCE'
), 30::BIGINT, 'course codes and faculty subject are normalized');

SELECT is((
  SELECT count(*)
  FROM public.course_professors AS mapping
  JOIN expected_commerce_batch_3 AS expected ON expected.id = mapping.course_id
), 30::BIGINT, 'every verified instructor mapping is present');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_3 AS expected
  WHERE expected.professor_count = (
    SELECT count(*) FROM public.course_professors AS mapping
    WHERE mapping.course_id = expected.id
  )
), 30::BIGINT, 'each course exposes the exact selected-term professor set');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_3 AS expected
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
), 30::BIGINT, 'every PDF has exact hash-bound private Storage metadata');

SELECT is((
  SELECT count(*)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_3 AS expected ON expected.id = outline.course_id
), 30::BIGINT, 'the batch registers exactly one outline per course');

SELECT ok((
  SELECT bool_and(outline.file_size_bytes <= 20971520)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_3 AS expected ON expected.id = outline.course_id
), 'all selected assets satisfy the existing outline size contract');

SELECT is((SELECT public FROM storage.buckets WHERE id = 'course-outlines'), FALSE,
  'Commerce outlines remain in the shared private bucket');

SELECT is((
  SELECT count(*)
  FROM storage.objects AS object
  JOIN expected_commerce_batch_3 AS expected
    ON object.bucket_id = 'course-outlines'
   AND object.name = expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
       expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
), 30::BIGINT, 'all immutable PDFs were seeded into local Storage');

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT is((SELECT count(*) FROM public.get_course_catalog()
  WHERE code IN (SELECT code FROM expected_commerce_batch_3)),
  30::BIGINT, 'authenticated discovery returns every batch course');

SELECT is((
  SELECT count(*)
  FROM public.get_course_catalog() AS catalog
  JOIN expected_commerce_batch_3 AS expected ON expected.id = catalog.id
  WHERE jsonb_array_length(catalog.professors) = expected.professor_count
), 30::BIGINT, 'discovery exposes exact professor filters');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_3 AS expected
  WHERE jsonb_array_length(public.get_course_review_snapshot(expected.id)->'professors') =
        expected.professor_count
), 30::BIGINT, 'every course loads the shared review editor professor data');

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

SELECT * FROM finish();
ROLLBACK;
