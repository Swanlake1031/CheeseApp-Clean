BEGIN;

SELECT plan(16);

CREATE TEMP TABLE expected_commerce_batch_4 (
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

INSERT INTO expected_commerce_batch_4
VALUES
  (
    'b65d7329-c360-546a-8be7-73b306bbaac4',
    'COMMERCE 4FS3',
    'Pension, Retirement and Estate Planning',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'winter',
    282717::BIGINT,
    'f75edd3c003468c502df63bac4be66a9f91bb88ada00a6a38a5653ad5697b7be'
  ),
  (
    '5a12c7a4-dcb1-539d-a403-b2525352f7de',
    'COMMERCE 4FT3',
    'Real Estate Finance and Investment',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    264566::BIGINT,
    '91b93135b027bc32b33f6a5418a107d1f4a2354cc28060dd1f32942f5c95fc32'
  ),
  (
    '0cbe9680-9176-56ae-b850-c50dbfb9f114',
    'COMMERCE 4FU3',
    'Behavioural Finance: The Psychology of Markets',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    374467::BIGINT,
    '32cab9583cc391b2382e45c3d0c8cdac2965ae9ebb09b9bd0dff7ba8c4cc5ebb'
  ),
  (
    'a0322229-2e76-5370-91af-bbbd5b5839e3',
    'COMMERCE 4FV3',
    'Venture Capital',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    298233::BIGINT,
    '9e4b52ba5f5a1934ed6a5fd4f1adcc4cf132f987e7b73cfa2200c5594d35f536'
  ),
  (
    'eb50b1b1-8939-5721-8fdc-54e2170d25b1',
    'COMMERCE 4FW3',
    'Finance for Entrepreneurs',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    224967::BIGINT,
    'c1a6d88c72cbb05d973cd52a3ced42cb64bdf97e874c3a2ceabbdf6fa0cf08ce'
  ),
  (
    '67308986-55fe-506e-aff5-897ea4fd48b4',
    'COMMERCE 4FX3',
    'Special Topics in Finance',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    311862::BIGINT,
    'f8c6c079594f6cf6309456c1ff9d36e5db56b15f8ff25464324d65157acc5afd'
  ),
  (
    'ac739e15-6341-5f3a-8117-775f0760009c',
    'COMMERCE 4KF3',
    'Project Management',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    327981::BIGINT,
    'f5dc41af7c0bdd8886ada9ee62a04f3aec2a81f969ed95344397def5926dc0ba'
  ),
  (
    '76296225-46d1-585f-986b-15427f0d138e',
    'COMMERCE 4KG3',
    'Data Mining For Business Analytics',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'winter',
    260406::BIGINT,
    '6a6a0dab074a63063bfd1b6e5e8ee8fd2ce2e7ff6f49ad96dffdb432d02944ff'
  ),
  (
    '71e1a40d-c1f8-5742-8d2e-f5d85f728742',
    'COMMERCE 4KH3',
    'Strategies for Electronic and Mobile Business',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    405150::BIGINT,
    'ce8287d7213e0105211cc7ca05fd8047734458e4b9cf4e85904f43db30c8b955'
  ),
  (
    '4d4eb5d4-f1ff-5b38-ba3c-0a4ad6a3b7a2',
    'COMMERCE 4KI3',
    'Business Process Management',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    146058::BIGINT,
    'ee370614bed709a60efaee42ad5a51e0678aafcf19d2a489b378e96bc71b4923'
  ),
  (
    'b928488e-5e8b-5d67-97d8-13f8b2d5b74e',
    'COMMERCE 4MA3',
    'Advertising and Integrated Marketing Communication',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    247480::BIGINT,
    '2424c5e3c1b59c355f1ee86107dd22ae328f8206dceccc94e22fdf57b42e123e'
  ),
  (
    '8740b613-f4cd-56d3-bfba-bb83f49071fa',
    'COMMERCE 4MC3',
    'New Product Marketing',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    469006::BIGINT,
    'b73c2a42a8cebe2863272ab7b689b6a975426d42fc3a17223437aa01eea7e5e4'
  ),
  (
    '03b0f744-76ad-5cc1-95d1-7c4e292f80bc',
    'COMMERCE 4ME3',
    'Sales Management',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    414156::BIGINT,
    '2310d31d466316849ce52b632a69bde8e4533aab49b2e5d6aaf3d106e2ee8283'
  ),
  (
    '3219121a-1456-5fc6-ba35-c855a5cc8a51',
    'COMMERCE 4MF3',
    'Retailing Management',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    263908::BIGINT,
    'a069d827292f03c6f36cbbe28417056abb4125e0a597c281781e8c0a074507b0'
  ),
  (
    '94bc1832-6f7c-577d-93ea-d9301d73d50c',
    'COMMERCE 4MG3',
    'Strategic Philanthropy and Leadership',
    4::SMALLINT,
    2,
    2021::SMALLINT,
    'fall',
    508265::BIGINT,
    'c267224f810b929c8282aaba450343d269ae946ee5bb3c27747fef3a9b9a4f9a'
  ),
  (
    '43769a50-cbcd-5da5-b72a-b33acb9e8887',
    'COMMERCE 4OB3',
    'Analysis of Production/Operations Problems',
    4::SMALLINT,
    1,
    2024::SMALLINT,
    'fall',
    262002::BIGINT,
    'ec2fa3e7d9a965e556d111f023dd3cb83c68ee7b86fddadf3d44bec1e02e80cd'
  ),
  (
    '54946a52-aacc-50d1-998a-32f11942dbe2',
    'COMMERCE 4OD3',
    'Purchasing and Supply Management',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    652798::BIGINT,
    'f32a6e6cc751c1000deb08fdf663867e88327dc3437a875bfd770160a41dd778'
  ),
  (
    'f2260789-a24c-5177-b026-7f8590d0cc0a',
    'COMMERCE 4OI3',
    'Supply Chain Management',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    1223766::BIGINT,
    '811b2654a5596c7a86d841295b9aca1166bde032d9a4c4435d7be9f21eeb27af'
  ),
  (
    '2ef8d5a5-1fe6-5802-aa7f-a521d707f1f4',
    'COMMERCE 4PA3',
    'Business Policy: Strategic Management',
    4::SMALLINT,
    3,
    2026::SMALLINT,
    'winter',
    293460::BIGINT,
    '7e4635ab9443d187a00c9b6625aa049ae55161a213a8d9a8c354c7ff4300ef50'
  ),
  (
    '0265eff8-7126-594f-bea3-42e8e5689e9c',
    'COMMERCE 4QA3',
    'Operations Modelling and Analysis',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    345197::BIGINT,
    '95cd43e30ca6cb6cf3868ea903b6c92a166995eb7f91a18e53ffd80b37e2229f'
  ),
  (
    '503a128f-6bff-59f2-9aac-1d6b13ed23f1',
    'COMMERCE 4SA3',
    'International Business',
    4::SMALLINT,
    3,
    2026::SMALLINT,
    'winter',
    450631::BIGINT,
    'b6c450dd72fc95eb1a35341d6ed7b534f72dcf508ed218cf58bd7057744268dd'
  ),
  (
    'c4b44871-8f3c-5c72-ac10-6795439a6cd3',
    'COMMERCE 4SB3',
    'Introduction to Canadian Taxation',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    211893::BIGINT,
    'b70e7dcb7b4a0640d0591d7f834fc93d6b78fe10c50eb8f514e8792eded82d15'
  ),
  (
    'c682ae9d-c8d7-5649-97f7-e3d8caa82bab',
    'COMMERCE 4SC3',
    'Advanced Canadian Taxation',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    397564::BIGINT,
    '3b6dd83ce85bc0b16c9763f630d08146459a5127715c3e1bdbc477d89932324d'
  ),
  (
    '92b3fe12-f0dd-5736-ab81-d66083a35aa3',
    'COMMERCE 4SD3',
    'Commercial Law',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    508991::BIGINT,
    'cb45c0237868db5554f644f8cad327b9e38354187e3a1abbb0cb6f709f9b9790'
  ),
  (
    '3336076d-1b96-5753-9beb-7154d9919b32',
    'COMMERCE 4SE3',
    'Entrepreneurship',
    4::SMALLINT,
    1,
    2025::SMALLINT,
    'fall',
    534720::BIGINT,
    '0e8aae2fce57a2d0a3908dc9481134be85ea0785b01b658837371540f4f50df6'
  ),
  (
    '93f7c483-3783-5071-a71b-72c2af8b4066',
    'COMMERCE 4SG3',
    'Sustainability: Corporations and Society',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    346070::BIGINT,
    '06377f3c2e4c7e6d8421fb5fc811e20730cf63063169ac169fc4f1686eda273f'
  ),
  (
    '26521ca5-5346-58e4-9ba9-17fc4e3340f6',
    'COMMERCE 4SH3',
    'Case Analysis and Presentation Skills',
    4::SMALLINT,
    1,
    2019::SMALLINT,
    'fall',
    143403::BIGINT,
    '72fc07e8b3cee75a50582480d242d1a859a31f38e019bfb3a58c5812f808bb74'
  ),
  (
    'ca453e0a-a694-5dd3-ac70-2e2aecfcdd48',
    'COMMERCE 4SM3',
    'Sports Management',
    4::SMALLINT,
    1,
    2026::SMALLINT,
    'winter',
    327981::BIGINT,
    '91457f913bbed6398ffad55d16bd9feb4beeeb2dac2b288b6125e9a2deac9025'
  ),
  (
    '0cc3d097-72b3-54e9-a5c4-e611e3a046c7',
    'COMMERCE 4SX3',
    'Special Topics in Strategic Management: White Collar Crime',
    4::SMALLINT,
    1,
    2020::SMALLINT,
    'summer',
    265750::BIGINT,
    '4142c7056cd1643e654d018b31fdc5e3ea468a87ce6be629a07a2bea58556b5f'
  );

GRANT SELECT ON expected_commerce_batch_4 TO authenticated;

SELECT is((SELECT count(*) FROM expected_commerce_batch_4), 29::BIGINT,
  'the batch contains its reviewed course count');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_4 AS expected
  JOIN public.courses AS course
    ON course.id = expected.id
   AND course.code = expected.code
   AND course.title = expected.title
   AND course.subject = 'COMMERCE'
   AND course.year_level = expected.year_level
), 29::BIGINT, 'all courses use normalized catalog metadata');

SELECT is((
  SELECT count(DISTINCT course.code)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_4)
), 29::BIGINT, 'the import creates no duplicate course codes');

SELECT is((
  SELECT count(*)
  FROM public.courses AS course
  WHERE course.code IN (SELECT code FROM expected_commerce_batch_4)
    AND course.code = upper(btrim(course.code))
    AND course.subject = 'COMMERCE'
), 29::BIGINT, 'course codes and faculty subject are normalized');

SELECT is((
  SELECT count(*)
  FROM public.course_professors AS mapping
  JOIN expected_commerce_batch_4 AS expected ON expected.id = mapping.course_id
), 34::BIGINT, 'every verified instructor mapping is present');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_4 AS expected
  WHERE expected.professor_count = (
    SELECT count(*) FROM public.course_professors AS mapping
    WHERE mapping.course_id = expected.id
  )
), 29::BIGINT, 'each course exposes the exact selected-term professor set');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_4 AS expected
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
), 29::BIGINT, 'every PDF has exact hash-bound private Storage metadata');

SELECT is((
  SELECT count(*)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_4 AS expected ON expected.id = outline.course_id
), 29::BIGINT, 'the batch registers exactly one outline per course');

SELECT ok((
  SELECT bool_and(outline.file_size_bytes <= 20971520)
  FROM public.course_outlines AS outline
  JOIN expected_commerce_batch_4 AS expected ON expected.id = outline.course_id
), 'all selected assets satisfy the existing outline size contract');

SELECT is((SELECT public FROM storage.buckets WHERE id = 'course-outlines'), FALSE,
  'Commerce outlines remain in the shared private bucket');

SELECT is((
  SELECT count(*)
  FROM storage.objects AS object
  JOIN expected_commerce_batch_4 AS expected
    ON object.bucket_id = 'course-outlines'
   AND object.name = expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
       expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
), 29::BIGINT, 'all immutable PDFs were seeded into local Storage');

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT is((SELECT count(*) FROM public.get_course_catalog()
  WHERE code IN (SELECT code FROM expected_commerce_batch_4)),
  29::BIGINT, 'authenticated discovery returns every batch course');

SELECT is((
  SELECT count(*)
  FROM public.get_course_catalog() AS catalog
  JOIN expected_commerce_batch_4 AS expected ON expected.id = catalog.id
  WHERE jsonb_array_length(catalog.professors) = expected.professor_count
), 29::BIGINT, 'discovery exposes exact professor filters');

SELECT is((
  SELECT count(*)
  FROM expected_commerce_batch_4 AS expected
  WHERE jsonb_array_length(public.get_course_review_snapshot(expected.id)->'professors') =
        expected.professor_count
), 29::BIGINT, 'every course loads the shared review editor professor data');

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
