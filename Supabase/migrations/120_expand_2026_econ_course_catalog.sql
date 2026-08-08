-- Expand the 2026 ECON catalog from the verified McMaster course-outline set.
--
-- Storage rollout order for a linked environment:
-- 1. Upload the files under Supabase/course-outlines to the existing private
--    course-outlines bucket. Their names are immutable SHA-256 paths.
-- 2. Apply this migration so authenticated clients can discover the objects.
-- 3. Verify one Spring and one Summer download through the app contract.
--
-- Local reset order differs only because migrations run before bucket seeds:
-- 1. supabase db reset
-- 2. supabase seed buckets --local
-- 3. supabase test db
--
-- ECON 3H03 and ECON 3M03 are catalogued below, but deliberately have no
-- course_outlines row: the source set contains links, not verified PDF files.
--
-- Rollback limits:
-- - Removing this migration's catalog rows can also remove dependent reviews.
-- - Storage objects are not transactional with PostgreSQL and must be removed
--   separately if this catalog expansion is intentionally rolled back.

BEGIN;

INSERT INTO public.courses (
  id,
  code,
  title,
  subject,
  year_level,
  is_popular
)
VALUES
  (
    'ec011b03-0000-4000-8000-000000000001',
    'ECON 1B03',
    'Introductory Microeconomics',
    'ECON',
    1,
    TRUE
  ),
  (
    'ec000000-0000-4000-8000-000000000002',
    'ECON 1BB3',
    'Introductory Macroeconomics',
    'ECON',
    1,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000003',
    'ECON 2A03',
    'Labour – Market Issues',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000004',
    'ECON 2CC3',
    'Health Economics and its Application to Health Policy',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000005',
    'ECON 2I03',
    'Financial Economics',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000006',
    'ECON 2J03',
    'Environmental Economics',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000007',
    'ECON 2P03',
    'Economics of Professional Sports',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000008',
    'ECON 2Y03',
    'Intermediate Macroeconomics I',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000009',
    'ECON 2Z03',
    'Intermediate Microeconomics I',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000010',
    'ECON 2ZZ3',
    'Intermediate Microeconomics II',
    'ECON',
    2,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000011',
    'ECON 3H03',
    'International Monetary Economics',
    'ECON',
    3,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000012',
    'ECON 3HH3',
    'International Trade',
    'ECON',
    3,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000013',
    'ECON 3M03',
    'Introduction to Game Theory',
    'ECON',
    3,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000014',
    'ECON 4T03',
    'Advanced Economic Theory I',
    'ECON',
    4,
    FALSE
  ),
  (
    'ec000000-0000-4000-8000-000000000015',
    'ECON 701',
    'Applied Research Workshop',
    'ECON',
    4,
    FALSE
  )
ON CONFLICT (code) DO UPDATE
SET
  title = EXCLUDED.title,
  subject = EXCLUDED.subject,
  year_level = EXCLUDED.year_level,
  is_popular = EXCLUDED.is_popular,
  updated_at = NOW();

-- The checked-in Storage seed paths use these stable course IDs. Refuse to
-- create metadata that points at a different path if an unexpected conflicting
-- catalog row already exists in an environment.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM (
      VALUES
        ('ECON 1B03', 'ec011b03-0000-4000-8000-000000000001'::UUID),
        ('ECON 1BB3', 'ec000000-0000-4000-8000-000000000002'::UUID),
        ('ECON 2A03', 'ec000000-0000-4000-8000-000000000003'::UUID),
        ('ECON 2CC3', 'ec000000-0000-4000-8000-000000000004'::UUID),
        ('ECON 2I03', 'ec000000-0000-4000-8000-000000000005'::UUID),
        ('ECON 2J03', 'ec000000-0000-4000-8000-000000000006'::UUID),
        ('ECON 2P03', 'ec000000-0000-4000-8000-000000000007'::UUID),
        ('ECON 2Y03', 'ec000000-0000-4000-8000-000000000008'::UUID),
        ('ECON 2Z03', 'ec000000-0000-4000-8000-000000000009'::UUID),
        ('ECON 2ZZ3', 'ec000000-0000-4000-8000-000000000010'::UUID),
        ('ECON 3H03', 'ec000000-0000-4000-8000-000000000011'::UUID),
        ('ECON 3HH3', 'ec000000-0000-4000-8000-000000000012'::UUID),
        ('ECON 3M03', 'ec000000-0000-4000-8000-000000000013'::UUID),
        ('ECON 4T03', 'ec000000-0000-4000-8000-000000000014'::UUID),
        ('ECON 701', 'ec000000-0000-4000-8000-000000000015'::UUID)
    ) AS expected(code, id)
    JOIN public.courses AS course ON course.code = expected.code
    WHERE course.id <> expected.id
  ) THEN
    RAISE EXCEPTION
      'ECON catalog course IDs conflict with the checked-in Storage seed paths';
  END IF;
END;
$$;

INSERT INTO public.professors (id, name)
VALUES
  ('c0110000-0000-4000-8000-000000000001', 'Colin Mang'),
  ('fa000000-0000-4000-8000-000000000002', 'Bridget O’Shaughnessy'),
  ('fa000000-0000-4000-8000-000000000003', 'Boris Kralj'),
  ('fa000000-0000-4000-8000-000000000004', 'Paul Contoyannis'),
  ('fa000000-0000-4000-8000-000000000005', 'Rizwan Tahir'),
  ('fa000000-0000-4000-8000-000000000006', 'Akio Yamazaki'),
  ('fa000000-0000-4000-8000-000000000007', 'Rumen Kostadinov'),
  ('fa000000-0000-4000-8000-000000000008', 'Anastasios Papanastasiou'),
  ('fa000000-0000-4000-8000-000000000009', 'Saeed-Ur-Rehman Rana'),
  ('fa000000-0000-4000-8000-000000000010', 'Pau S. Pujolas'),
  ('fa000000-0000-4000-8000-000000000011', 'Zhen He'),
  ('fa000000-0000-4000-8000-000000000012', 'Gajendran Raveendranathan')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (
  VALUES
    ('ECON 1B03', 'c0110000-0000-4000-8000-000000000001'::UUID),
    ('ECON 1BB3', 'fa000000-0000-4000-8000-000000000002'::UUID),
    ('ECON 2A03', 'fa000000-0000-4000-8000-000000000003'::UUID),
    ('ECON 2CC3', 'fa000000-0000-4000-8000-000000000004'::UUID),
    ('ECON 2I03', 'fa000000-0000-4000-8000-000000000005'::UUID),
    ('ECON 2J03', 'fa000000-0000-4000-8000-000000000006'::UUID),
    ('ECON 2P03', 'c0110000-0000-4000-8000-000000000001'::UUID),
    ('ECON 2Y03', 'fa000000-0000-4000-8000-000000000005'::UUID),
    ('ECON 2Z03', 'fa000000-0000-4000-8000-000000000007'::UUID),
    ('ECON 2ZZ3', 'fa000000-0000-4000-8000-000000000008'::UUID),
    ('ECON 3H03', 'fa000000-0000-4000-8000-000000000009'::UUID),
    ('ECON 3HH3', 'fa000000-0000-4000-8000-000000000010'::UUID),
    ('ECON 3M03', 'fa000000-0000-4000-8000-000000000011'::UUID),
    ('ECON 4T03', 'fa000000-0000-4000-8000-000000000007'::UUID),
    ('ECON 701', 'fa000000-0000-4000-8000-000000000012'::UUID)
) AS mapping(course_code, professor_id)
JOIN public.courses AS course ON course.code = mapping.course_code
ON CONFLICT (course_id, professor_id) DO NOTHING;

INSERT INTO public.course_outlines (
  course_id,
  academic_year,
  term,
  professor_name,
  title,
  storage_path,
  original_filename,
  mime_type,
  file_size_bytes,
  sha256
)
SELECT
  course.id,
  2026,
  outline.term,
  outline.professor_name,
  outline.title,
  course.id::TEXT || '/2026/' || outline.term || '/' || outline.sha256 || '.pdf',
  outline.original_filename,
  'application/pdf',
  outline.file_size_bytes,
  outline.sha256
FROM (
  VALUES
    (
      'ECON 1B03',
      'summer',
      'Colin Mang',
      'ECON 1B03 Course Outline Summer 2026',
      'ECON 1B03 Course Outline Summer 2026 - C.Mang.pdf',
      216207::BIGINT,
      '8b0b4371f4c5b7e68aa635713f9a3100d38c4b5f93ae62240f920a405c01bad2'
    ),
    (
      'ECON 1BB3',
      'spring',
      'Bridget O’Shaughnessy',
      'ECON 1BB3 Course Outline Spring 2026',
      'ECON 1BB3 Course Outline Spring 2026 - B.O''Shaughnessy.pdf',
      322881::BIGINT,
      '123a22b307f2061cce8d60b20f98832fbe31fa89c84b516ca1f737ee7caeee82'
    ),
    (
      'ECON 2A03',
      'summer',
      'Boris Kralj',
      'ECON 2A03 Course Outline Summer 2026',
      'ECON 2A03 Course Outline Summer 2026 - B.Kralj.pdf',
      142558::BIGINT,
      'be1cc0654bc0597d4b3200902d40b7e67b88777136ef05b713d9a54fcb36e244'
    ),
    (
      'ECON 2CC3',
      'spring',
      'Paul Contoyannis',
      'ECON 2CC3 Course Outline Spring 2026',
      'ECON 2CC3 Course Outline Spring 2026 - P.Contoyannis.pdf',
      222935::BIGINT,
      '2f5d861daa95f553f93cf0907d6fda76f7dd96091e96da0ad16d3cadd32368b0'
    ),
    (
      'ECON 2I03',
      'spring',
      'Rizwan Tahir',
      'ECON 2I03 Course Outline Spring 2026',
      'ECON 2I03 Course Outline Spring 2026 - R.Tahir.pdf',
      289735::BIGINT,
      'c7702a466482fc1da03667eee8cf933707bbbc5027c62e6f6a19137e40870b3f'
    ),
    (
      'ECON 2J03',
      'spring',
      'Akio Yamazaki',
      'ECON 2J03 Course Outline Spring 2026',
      'ECON 2J03 Course Outline Spring 2026 - A.Yamazaki.pdf',
      251633::BIGINT,
      'e2a885b1595f3f3d7e493a7ee163d7c2cd42be01beb0d13344e148cf9ad469ce'
    ),
    (
      'ECON 2P03',
      'summer',
      'Colin Mang',
      'ECON 2P03 Course Outline Summer 2026',
      'ECON 2P03 Course Outline Summer 2026 - C.Mang.pdf',
      214992::BIGINT,
      '1697e25ec6fa50115cdfb53e9ae5951ff92d7af0119815ec29796f3c256100d8'
    ),
    (
      'ECON 2Y03',
      'spring',
      'Rizwan Tahir',
      'ECON 2Y03 Course Outline Spring 2026',
      'ECON 2Y03 Course Outline Spring 2026 - R.Tahir.pdf',
      275473::BIGINT,
      '871325e78acd0fee608518201de0de492afdb77a7c3d2ccf539141304f1a04d3'
    ),
    (
      'ECON 2Z03',
      'spring',
      'Rumen Kostadinov',
      'ECON 2Z03 Course Outline Spring 2026',
      'ECON 2Z03 Course Outline Spring 2026 - R.Kostadinov.pdf',
      221383::BIGINT,
      '604ddaadb6808ea35eb25af821f4194419cb9c243e1e886d1902f482d07a3d59'
    ),
    (
      'ECON 2ZZ3',
      'summer',
      'Anastasios Papanastasiou',
      'ECON 2ZZ3 Course Outline Summer 2026',
      'ECON 2ZZ3 C01 Course Outline Summer 2026 - A.Papanastasiou.pdf',
      197002::BIGINT,
      '093ded3ab64ce6e6843dbf2ece3413fc8a30fb854e3e5187e8cacc97ac06ffdd'
    ),
    (
      'ECON 3HH3',
      'spring',
      'Pau S. Pujolas',
      'ECON 3HH3 Course Outline Spring 2026',
      'ECON 3HH3 Course Outline Spring 2026 - P.Pujolas.pdf',
      186276::BIGINT,
      '1f748a57221fab6185178785c1bdc12eafa7529a7eb60ca61556e45212457635'
    ),
    (
      'ECON 4T03',
      'summer',
      'Rumen Kostadinov',
      'ECON 4T03 Course Outline Summer 2026',
      'ECON 4T03 Course Outline Summer 2026 - R.Kostadinov.pdf',
      193328::BIGINT,
      '16fa1b878510782395038480fd041c68690100ad1be1f77734a11948188927ca'
    ),
    (
      'ECON 701',
      'summer',
      'Gajendran Raveendranathan',
      'ECON 701 Course Outline Summer 2026',
      'ECON 701 Course Outline Summer 2026 - G.Raveendranathan.pdf',
      246321::BIGINT,
      'c846b14154b359d418e0f321238b1d1a031e988dc2de14079b44ab4d622b5671'
    )
) AS outline(
  course_code,
  term,
  professor_name,
  title,
  original_filename,
  file_size_bytes,
  sha256
)
JOIN public.courses AS course ON course.code = outline.course_code
ON CONFLICT (storage_path) DO UPDATE
SET
  professor_name = EXCLUDED.professor_name,
  title = EXCLUDED.title,
  original_filename = EXCLUDED.original_filename,
  mime_type = EXCLUDED.mime_type,
  file_size_bytes = EXCLUDED.file_size_bytes,
  sha256 = EXCLUDED.sha256;

NOTIFY pgrst, 'reload schema';

COMMIT;
