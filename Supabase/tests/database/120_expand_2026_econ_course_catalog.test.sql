BEGIN;

SELECT plan(15);

CREATE TEMP TABLE expected_2026_econ_courses (
  id UUID NOT NULL,
  code TEXT NOT NULL,
  title TEXT NOT NULL,
  year_level SMALLINT NOT NULL,
  is_popular BOOLEAN NOT NULL,
  professor_id UUID NOT NULL,
  professor_name TEXT NOT NULL,
  outline_term TEXT,
  outline_size BIGINT,
  outline_sha256 TEXT
) ON COMMIT DROP;

INSERT INTO expected_2026_econ_courses
VALUES
  (
    'ec011b03-0000-4000-8000-000000000001',
    'ECON 1B03',
    'Introductory Microeconomics',
    1,
    TRUE,
    'c0110000-0000-4000-8000-000000000001',
    'Colin Mang',
    'summer',
    216207,
    '8b0b4371f4c5b7e68aa635713f9a3100d38c4b5f93ae62240f920a405c01bad2'
  ),
  (
    'ec000000-0000-4000-8000-000000000002',
    'ECON 1BB3',
    'Introductory Macroeconomics',
    1,
    FALSE,
    'fa000000-0000-4000-8000-000000000002',
    'Bridget O’Shaughnessy',
    'spring',
    322881,
    '123a22b307f2061cce8d60b20f98832fbe31fa89c84b516ca1f737ee7caeee82'
  ),
  (
    'ec000000-0000-4000-8000-000000000003',
    'ECON 2A03',
    'Labour – Market Issues',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000003',
    'Boris Kralj',
    'summer',
    142558,
    'be1cc0654bc0597d4b3200902d40b7e67b88777136ef05b713d9a54fcb36e244'
  ),
  (
    'ec000000-0000-4000-8000-000000000004',
    'ECON 2CC3',
    'Health Economics and its Application to Health Policy',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000004',
    'Paul Contoyannis',
    'spring',
    222935,
    '2f5d861daa95f553f93cf0907d6fda76f7dd96091e96da0ad16d3cadd32368b0'
  ),
  (
    'ec000000-0000-4000-8000-000000000005',
    'ECON 2I03',
    'Financial Economics',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000005',
    'Rizwan Tahir',
    'spring',
    289735,
    'c7702a466482fc1da03667eee8cf933707bbbc5027c62e6f6a19137e40870b3f'
  ),
  (
    'ec000000-0000-4000-8000-000000000006',
    'ECON 2J03',
    'Environmental Economics',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000006',
    'Akio Yamazaki',
    'spring',
    251633,
    'e2a885b1595f3f3d7e493a7ee163d7c2cd42be01beb0d13344e148cf9ad469ce'
  ),
  (
    'ec000000-0000-4000-8000-000000000007',
    'ECON 2P03',
    'Economics of Professional Sports',
    2,
    FALSE,
    'c0110000-0000-4000-8000-000000000001',
    'Colin Mang',
    'summer',
    214992,
    '1697e25ec6fa50115cdfb53e9ae5951ff92d7af0119815ec29796f3c256100d8'
  ),
  (
    'ec000000-0000-4000-8000-000000000008',
    'ECON 2Y03',
    'Intermediate Macroeconomics I',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000005',
    'Rizwan Tahir',
    'spring',
    275473,
    '871325e78acd0fee608518201de0de492afdb77a7c3d2ccf539141304f1a04d3'
  ),
  (
    'ec000000-0000-4000-8000-000000000009',
    'ECON 2Z03',
    'Intermediate Microeconomics I',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000007',
    'Rumen Kostadinov',
    'spring',
    221383,
    '604ddaadb6808ea35eb25af821f4194419cb9c243e1e886d1902f482d07a3d59'
  ),
  (
    'ec000000-0000-4000-8000-000000000010',
    'ECON 2ZZ3',
    'Intermediate Microeconomics II',
    2,
    FALSE,
    'fa000000-0000-4000-8000-000000000008',
    'Anastasios Papanastasiou',
    'summer',
    197002,
    '093ded3ab64ce6e6843dbf2ece3413fc8a30fb854e3e5187e8cacc97ac06ffdd'
  ),
  (
    'ec000000-0000-4000-8000-000000000011',
    'ECON 3H03',
    'International Monetary Economics',
    3,
    FALSE,
    'fa000000-0000-4000-8000-000000000009',
    'Saeed-Ur-Rehman Rana',
    NULL,
    NULL,
    NULL
  ),
  (
    'ec000000-0000-4000-8000-000000000012',
    'ECON 3HH3',
    'International Trade',
    3,
    FALSE,
    'fa000000-0000-4000-8000-000000000010',
    'Pau S. Pujolas',
    'spring',
    186276,
    '1f748a57221fab6185178785c1bdc12eafa7529a7eb60ca61556e45212457635'
  ),
  (
    'ec000000-0000-4000-8000-000000000013',
    'ECON 3M03',
    'Introduction to Game Theory',
    3,
    FALSE,
    'fa000000-0000-4000-8000-000000000011',
    'Zhen He',
    NULL,
    NULL,
    NULL
  ),
  (
    'ec000000-0000-4000-8000-000000000014',
    'ECON 4T03',
    'Advanced Economic Theory I',
    4,
    FALSE,
    'fa000000-0000-4000-8000-000000000007',
    'Rumen Kostadinov',
    'summer',
    193328,
    '16fa1b878510782395038480fd041c68690100ad1be1f77734a11948188927ca'
  ),
  (
    'ec000000-0000-4000-8000-000000000015',
    'ECON 701',
    'Applied Research Workshop',
    4,
    FALSE,
    'fa000000-0000-4000-8000-000000000012',
    'Gajendran Raveendranathan',
    'summer',
    246321,
    'c846b14154b359d418e0f321238b1d1a031e988dc2de14079b44ab4d622b5671'
  );

SELECT is(
  (SELECT count(*) FROM expected_2026_econ_courses),
  15::BIGINT,
  'the verified source set contains fifteen ECON courses'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_2026_econ_courses AS expected
    JOIN public.courses AS course
      ON course.id = expected.id
      AND course.code = expected.code
      AND course.title = expected.title
      AND course.subject = 'ECON'
      AND course.year_level = expected.year_level
      AND course.is_popular = expected.is_popular
  ),
  15::BIGINT,
  'all verified ECON courses use the expected stable catalog identity'
);

SELECT is(
  (
    SELECT count(DISTINCT professor.id)
    FROM (
      SELECT DISTINCT professor_id, professor_name
      FROM expected_2026_econ_courses
    ) AS expected
    JOIN public.professors AS professor
      ON professor.id = expected.professor_id
      AND professor.name = expected.professor_name
  ),
  12::BIGINT,
  'all twelve instructor identities are present without name-based identity'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_2026_econ_courses AS expected
    JOIN public.course_professors AS mapping
      ON mapping.course_id = expected.id
      AND mapping.professor_id = expected.professor_id
  ),
  15::BIGINT,
  'every ECON course is mapped to its verified instructor'
);

SELECT is(
  (
    SELECT count(DISTINCT expected.id)
    FROM expected_2026_econ_courses AS expected
    JOIN public.course_professors AS mapping
      ON mapping.course_id = expected.id
  ),
  15::BIGINT,
  'no catalogued ECON course is left without an instructor'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_2026_econ_courses AS expected
    JOIN public.course_outlines AS outline
      ON outline.course_id = expected.id
      AND outline.academic_year = 2026
      AND outline.term = expected.outline_term
      AND outline.professor_name = expected.professor_name
      AND outline.file_size_bytes = expected.outline_size
      AND outline.sha256 = expected.outline_sha256
      AND outline.mime_type = 'application/pdf'
      AND outline.storage_path =
        expected.id::TEXT || '/2026/' || expected.outline_term || '/' ||
        expected.outline_sha256 || '.pdf'
    WHERE expected.outline_sha256 IS NOT NULL
  ),
  13::BIGINT,
  'all thirteen real PDFs have exact hash-bound metadata'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_2026_econ_courses AS expected
      ON expected.id = outline.course_id
    WHERE outline.academic_year = 2026
  ),
  13::BIGINT,
  'the imported ECON set has no extra or fabricated outline rows'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_2026_econ_courses AS expected
      ON expected.id = outline.course_id
    WHERE expected.outline_sha256 IS NULL
  ),
  0::BIGINT,
  'URL-only ECON 3H03 and ECON 3M03 do not pretend to have PDF objects'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_2026_econ_courses AS expected
      ON expected.id = outline.course_id
    WHERE outline.term = 'spring'
  ),
  7::BIGINT,
  'seven verified Spring 2026 outlines are registered'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_2026_econ_courses AS expected
      ON expected.id = outline.course_id
    WHERE outline.term = 'summer'
  ),
  6::BIGINT,
  'six verified Summer 2026 outlines are registered'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.academic_terms
    WHERE academic_year = 2026
      AND term IN ('spring', 'summer')
  ),
  2::BIGINT,
  'the imported outline terms exist in the review term catalog'
);

SELECT is(
  (SELECT public FROM storage.buckets WHERE id = 'course-outlines'),
  FALSE,
  'the course outline bucket remains private'
);

SELECT ok(
  (
    SELECT file_size_limit = 20971520
      AND allowed_mime_types = ARRAY['application/pdf']::TEXT[]
    FROM storage.buckets
    WHERE id = 'course-outlines'
  ),
  'the course outline bucket remains PDF-only with a 20 MB limit'
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
  (
    SELECT count(*)
    FROM public.get_course_catalog()
    WHERE code = ANY (
      ARRAY[
        'ECON 1B03', 'ECON 1BB3', 'ECON 2A03', 'ECON 2CC3',
        'ECON 2I03', 'ECON 2J03', 'ECON 2P03', 'ECON 2Y03',
        'ECON 2Z03', 'ECON 2ZZ3', 'ECON 3H03', 'ECON 3HH3',
        'ECON 3M03', 'ECON 4T03', 'ECON 701'
      ]
    )
  ),
  15::BIGINT,
  'authenticated course discovery returns every imported ECON course'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.get_course_catalog()
    WHERE code = ANY (
      ARRAY[
        'ECON 1B03', 'ECON 1BB3', 'ECON 2A03', 'ECON 2CC3',
        'ECON 2I03', 'ECON 2J03', 'ECON 2P03', 'ECON 2Y03',
        'ECON 2Z03', 'ECON 2ZZ3', 'ECON 3H03', 'ECON 3HH3',
        'ECON 3M03', 'ECON 4T03', 'ECON 701'
      ]
    )
      AND jsonb_array_length(professors) > 0
  ),
  15::BIGINT,
  'course discovery returns an instructor for every imported ECON course'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
