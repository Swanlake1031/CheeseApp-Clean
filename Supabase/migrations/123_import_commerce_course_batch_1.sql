-- Import the first verified Commerce catalog batch.
--
-- Selection policy:
-- - Academic terms were verified from the PDF content, not filesystem dates.
-- - Winter 2026 is preferred; COMMERCE 2AB3 uses Fall 2025 because no
--   Winter 2026 outline exists in the supplied source set.
-- - One outline is registered per course. Where that outline covers multiple
--   sections, every instructor named by the outline is mapped to the course.
-- - Course and professor UUIDs are deterministic catalog identities so this
--   migration and later Commerce batches do not rely on display-name identity.
--
-- Storage rollout order for a linked environment:
-- 1. Upload the eight files under Supabase/course-outlines to the existing
--    private course-outlines bucket without replacing existing objects.
-- 2. Apply this migration so authenticated clients can discover the metadata.
-- 3. Verify signed-in download plus anonymous denial before releasing the app.
--
-- Local reset order:
-- 1. supabase db reset
-- 2. supabase seed buckets --local
-- 3. supabase test db
--
-- The selected PDFs are 327-535 KB, so recompression would add risk without a
-- meaningful storage or download benefit. The checked-in files are exact source
-- bytes and their immutable object paths are bound to SHA-256 metadata.

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
    'b0e2be60-1422-570c-9dce-0661be388bad',
    'COMMERCE 1AA3',
    'Financial Accounting',
    'COMMERCE',
    1,
    FALSE
  ),
  (
    '38ac51d0-ac42-550d-bceb-bfa2b1e05c39',
    'COMMERCE 1BA3',
    'Organizational Behaviour',
    'COMMERCE',
    1,
    FALSE
  ),
  (
    '13099e3a-db0e-52c8-b778-4cfea1fdce20',
    'COMMERCE 1DA3',
    'Business Data Analytics',
    'COMMERCE',
    1,
    FALSE
  ),
  (
    '42e876fb-8885-5914-8b4b-7f9e936917d2',
    'COMMERCE 1MA3',
    'Introduction to Marketing',
    'COMMERCE',
    1,
    FALSE
  ),
  (
    '618fffbd-d770-5110-a4e3-294a1cc9d2a1',
    'COMMERCE 2AB3',
    'Managerial Accounting',
    'COMMERCE',
    2,
    FALSE
  ),
  (
    '0d5cef2f-3d51-5a32-b405-43b7135f8860',
    'COMMERCE 2BC3',
    'Human Resource Management and Labour Relations',
    'COMMERCE',
    2,
    FALSE
  ),
  (
    'b0fe8194-75bf-5841-b826-25322c249e1a',
    'COMMERCE 2FA3',
    'Introduction to Finance',
    'COMMERCE',
    2,
    FALSE
  ),
  (
    '1739b38b-d2c8-5bc3-a39a-bea54633ab78',
    'COMMERCE 2KA3',
    'Information Systems in Management',
    'COMMERCE',
    2,
    FALSE
  )
ON CONFLICT (code) DO UPDATE
SET
  title = EXCLUDED.title,
  subject = EXCLUDED.subject,
  year_level = EXCLUDED.year_level,
  updated_at = NOW();

-- The private Storage seed paths use these course UUIDs. A conflicting course
-- code must not silently point outline metadata at another catalog identity.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM (
      VALUES
        ('COMMERCE 1AA3', 'b0e2be60-1422-570c-9dce-0661be388bad'::UUID),
        ('COMMERCE 1BA3', '38ac51d0-ac42-550d-bceb-bfa2b1e05c39'::UUID),
        ('COMMERCE 1DA3', '13099e3a-db0e-52c8-b778-4cfea1fdce20'::UUID),
        ('COMMERCE 1MA3', '42e876fb-8885-5914-8b4b-7f9e936917d2'::UUID),
        ('COMMERCE 2AB3', '618fffbd-d770-5110-a4e3-294a1cc9d2a1'::UUID),
        ('COMMERCE 2BC3', '0d5cef2f-3d51-5a32-b405-43b7135f8860'::UUID),
        ('COMMERCE 2FA3', 'b0fe8194-75bf-5841-b826-25322c249e1a'::UUID),
        ('COMMERCE 2KA3', '1739b38b-d2c8-5bc3-a39a-bea54633ab78'::UUID)
    ) AS expected(code, id)
    JOIN public.courses AS course ON course.code = expected.code
    WHERE course.id <> expected.id
  ) THEN
    RAISE EXCEPTION
      'Commerce batch 1 course IDs conflict with the checked-in Storage paths';
  END IF;
END;
$$;

INSERT INTO public.professors (id, name)
VALUES
  ('84ff9ac9-2586-527e-98d2-fa738b175a63', 'Ebadul Islam'),
  ('b62bd62a-61b1-5f44-9e5c-5aab854513ca', 'Linyang Yu'),
  ('f0198649-5b12-52be-8a07-2bcdd41d78cb', 'Teal McAteer'),
  ('e200a9c7-fd79-5440-a966-c4da8025c726', 'Behrouz Bakhtiari'),
  ('ebb204cf-5366-5734-8a69-e5b48878b899', 'Maryam Mashayekhi'),
  ('6c70d705-1df0-5a4b-999d-8cd86b4dc83f', 'Mingyao Song'),
  ('7e8d48c9-69ad-5e47-a1ed-c3e21aaf9978', 'Hamedhossein Afshari'),
  ('1794f2d7-83f4-57d8-9cdd-7d6fc5325f94', 'Chris Ling'),
  ('c8205786-7cf0-58ea-a2a8-76176de1c48a', 'Sanghwa Kim'),
  ('89f40e0e-8cd3-5904-a47c-28c5291bec77', 'Ala Mokhtar'),
  ('e36b08a0-3ccc-56bf-908e-47d769b208a3', 'A. S. Merali'),
  ('bdb1addc-8316-597d-9ef9-76b34a1363e6', 'Anita Boey'),
  ('5b9aa72f-1ce0-5423-b815-1cb29ff40f6f', 'Jason Tome'),
  ('4941ffb8-6a33-5869-864a-8eb9c6e3d54a', 'Cansu Ekmekcioglu'),
  ('d6c00da5-cca7-5aa2-ae78-c06d93517886', 'Rae Elgamal')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (
  VALUES
    ('COMMERCE 1AA3', '84ff9ac9-2586-527e-98d2-fa738b175a63'::UUID),
    ('COMMERCE 1AA3', 'b62bd62a-61b1-5f44-9e5c-5aab854513ca'::UUID),
    ('COMMERCE 1BA3', 'f0198649-5b12-52be-8a07-2bcdd41d78cb'::UUID),
    ('COMMERCE 1DA3', 'e200a9c7-fd79-5440-a966-c4da8025c726'::UUID),
    ('COMMERCE 1DA3', 'ebb204cf-5366-5734-8a69-e5b48878b899'::UUID),
    ('COMMERCE 1DA3', '6c70d705-1df0-5a4b-999d-8cd86b4dc83f'::UUID),
    ('COMMERCE 1DA3', '7e8d48c9-69ad-5e47-a1ed-c3e21aaf9978'::UUID),
    ('COMMERCE 1MA3', '1794f2d7-83f4-57d8-9cdd-7d6fc5325f94'::UUID),
    ('COMMERCE 1MA3', 'c8205786-7cf0-58ea-a2a8-76176de1c48a'::UUID),
    ('COMMERCE 2AB3', '89f40e0e-8cd3-5904-a47c-28c5291bec77'::UUID),
    ('COMMERCE 2AB3', 'e36b08a0-3ccc-56bf-908e-47d769b208a3'::UUID),
    ('COMMERCE 2BC3', 'bdb1addc-8316-597d-9ef9-76b34a1363e6'::UUID),
    ('COMMERCE 2FA3', '5b9aa72f-1ce0-5423-b815-1cb29ff40f6f'::UUID),
    ('COMMERCE 2KA3', '4941ffb8-6a33-5869-864a-8eb9c6e3d54a'::UUID),
    ('COMMERCE 2KA3', 'd6c00da5-cca7-5aa2-ae78-c06d93517886'::UUID)
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
  outline.academic_year,
  outline.term,
  outline.professor_name,
  outline.title,
  course.id::TEXT || '/' || outline.academic_year::TEXT || '/' ||
    outline.term || '/' || outline.sha256 || '.pdf',
  outline.original_filename,
  'application/pdf',
  outline.file_size_bytes,
  outline.sha256
FROM (
  VALUES
    (
      'COMMERCE 1AA3',
      2026::SMALLINT,
      'winter',
      'Ebadul Islam; Linyang Yu',
      'COMMERCE 1AA3 Course Outline Winter 2026',
      '1AA3 - Winter 2026 - C01 - E. Islam.pdf',
      332998::BIGINT,
      'd0bdee659ebc787f9230a5661153e4a122dee1e01cde642a7f3b02da7f11c4f0'
    ),
    (
      'COMMERCE 1BA3',
      2026::SMALLINT,
      'winter',
      'Teal McAteer',
      'COMMERCE 1BA3 Course Outline Winter 2026',
      '1BA3 - Winter 2026 - C01, C02, C03, C04 - T. McAteer.pdf',
      443777::BIGINT,
      'a3ca6195f738bc8c4f158a75db09fff690b005fa924bec43a5ed24faee4ffbd4'
    ),
    (
      'COMMERCE 1DA3',
      2026::SMALLINT,
      'winter',
      'Behrouz Bakhtiari; Maryam Mashayekhi; Mingyao Song; Hamedhossein Afshari',
      'COMMERCE 1DA3 Course Outline Winter 2026',
      '1DA3 - Winter 2026 - C01, C04, C05 - B. Bakhtiari.pdf',
      408446::BIGINT,
      'e86caadb8bd21138b23cef64809cc9f10c974b27fa995c0811e7519b1d23a5cb'
    ),
    (
      'COMMERCE 1MA3',
      2026::SMALLINT,
      'winter',
      'Chris Ling; Sanghwa Kim',
      'COMMERCE 1MA3 Course Outline Winter 2026',
      '1MA3 - Winter 2026 - C. Ling, S. Kim.pdf',
      534720::BIGINT,
      'f8384b68f9c4b8d758d5503583dfdbe9dc687ee664722cec282ffe76b20598ec'
    ),
    (
      'COMMERCE 2AB3',
      2025::SMALLINT,
      'fall',
      'Ala Mokhtar; A. S. Merali',
      'COMMERCE 2AB3 Course Outline Fall 2025',
      '2AB3 - Fall 2025 - C01-C03 - A. Mokhtar.pdf',
      399088::BIGINT,
      '5234b160d060fcb79bf9ae43cb801387839411f3f92cae81d0a9e1229136ae4d'
    ),
    (
      'COMMERCE 2BC3',
      2026::SMALLINT,
      'winter',
      'Anita Boey',
      'COMMERCE 2BC3 Course Outline Winter 2026',
      '2BC3 - Winter 2026 - C01 - A. Boey.pdf',
      427637::BIGINT,
      '27d5c0b63d0d4b2aef038c7bcc19f028b404aa65f2f536a83a3632d7f3b0009e'
    ),
    (
      'COMMERCE 2FA3',
      2026::SMALLINT,
      'winter',
      'Jason Tome',
      'COMMERCE 2FA3 Course Outline Winter 2026',
      '2FA3 - Winter 2026 - J. Tome.pdf',
      341494::BIGINT,
      '77ec195ad7ba454ce9557dd9b31d1249919fe2ec4982f81f13b0dd43addff2d3'
    ),
    (
      'COMMERCE 2KA3',
      2026::SMALLINT,
      'winter',
      'Cansu Ekmekcioglu; Rae Elgamal',
      'COMMERCE 2KA3 Course Outline Winter 2026',
      '2KA3 - Winter 2026 - C01, C03, C05 - C. Ekmekcioglu.pdf',
      327165::BIGINT,
      '34037949303b75d1c41a13c155cfe71a8fe9438b13396a178d59915d71f45d3c'
    )
) AS outline(
  course_code,
  academic_year,
  term,
  professor_name,
  title,
  original_filename,
  file_size_bytes,
  sha256
)
JOIN public.courses AS course ON course.code = outline.course_code
ON CONFLICT (course_id, academic_year, term, sha256) DO UPDATE
SET
  professor_name = EXCLUDED.professor_name,
  title = EXCLUDED.title,
  original_filename = EXCLUDED.original_filename,
  mime_type = EXCLUDED.mime_type,
  file_size_bytes = EXCLUDED.file_size_bytes;

NOTIFY pgrst, 'reload schema';

COMMIT;
