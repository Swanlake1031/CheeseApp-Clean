-- Add URL-backed course outlines without changing the existing private Storage
-- table. Keeping a separate table is required for backward compatibility:
-- released app versions decode every course_outlines Storage field as non-null.
--
-- New clients merge this table with course_outlines. Existing clients ignore it
-- and continue to read private objects without a decoding regression.
--
-- Rollback limits:
-- - Dropping course_external_outlines removes only URL metadata, not PDFs.
-- - Course rows created here may later own reviews, so do not delete them as a
--   rollback after users begin reviewing those courses.
-- - No Storage object is created, replaced, or deleted by this migration.

BEGIN;

CREATE TABLE public.course_external_outlines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  academic_year SMALLINT NOT NULL,
  term TEXT NOT NULL,
  professor_name TEXT,
  title TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_url TEXT NOT NULL,
  source_page_url TEXT,
  source_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  retrieved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT course_external_outlines_academic_year_range
    CHECK (academic_year BETWEEN 2000 AND 2200),
  CONSTRAINT course_external_outlines_term_valid
    CHECK (term IN ('winter', 'spring', 'summer', 'fall')),
  CONSTRAINT course_external_outlines_professor_name_not_blank
    CHECK (professor_name IS NULL OR btrim(professor_name) <> ''),
  CONSTRAINT course_external_outlines_title_not_blank
    CHECK (btrim(title) <> ''),
  CONSTRAINT course_external_outlines_source_name_not_blank
    CHECK (btrim(source_name) <> ''),
  CONSTRAINT course_external_outlines_source_kind_valid
    CHECK (source_kind IN ('external_pdf', 'external_web')),
  CONSTRAINT course_external_outlines_mime_valid
    CHECK (
      (source_kind = 'external_pdf' AND mime_type = 'application/pdf')
      OR (source_kind = 'external_web' AND mime_type = 'text/html')
    ),
  CONSTRAINT course_external_outlines_source_url_valid
    CHECK (
      source_url ~ '^https://([a-z0-9-]+\.)*(mcmaster\.ca|simplesyllabusca\.com)(/|$)'
    ),
  CONSTRAINT course_external_outlines_source_page_url_valid
    CHECK (
      source_page_url IS NULL
      OR source_page_url ~ '^https://([a-z0-9-]+\.)*(mcmaster\.ca|simplesyllabusca\.com)(/|$)'
    ),
  UNIQUE (course_id, source_url)
);

CREATE INDEX course_external_outlines_course_term_idx
  ON public.course_external_outlines (course_id, academic_year DESC, term);

ALTER TABLE public.course_external_outlines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view external course outlines"
ON public.course_external_outlines
FOR SELECT
TO authenticated
USING (true);

REVOKE ALL ON public.course_external_outlines FROM anon, authenticated;
GRANT SELECT ON public.course_external_outlines TO authenticated;

INSERT INTO public.courses (id, code, title, subject, year_level, is_popular)
VALUES
  ('8d787edf-7853-516f-9748-6b2c6c68f90c', 'COMMERCE 1E03',
   'Business Environment and Organization', 'COMMERCE', 1, FALSE),
  ('45c4068b-5476-5310-acca-235becbf5a2c', 'COMMERCE 2CO0',
   'Co-op and Career Development Course', 'COMMERCE', 2, FALSE),
  ('378b8081-b15c-5b8a-b619-4275b4985d19', 'ECON 1ME3',
   'Introduction to Mathematical Economics', 'ECON', 1, FALSE),
  ('3880a3ba-f233-594d-a11b-af999c9cb2db', 'ECON 3B03',
   'Public Sector Economics: Expenditures', 'ECON', 3, FALSE)
ON CONFLICT (code) DO UPDATE
SET title = EXCLUDED.title,
    subject = EXCLUDED.subject,
    year_level = EXCLUDED.year_level,
    updated_at = NOW();

INSERT INTO public.professors (id, name)
VALUES ('ecd32005-1d84-5f96-9638-49b9db87c9fc', 'Zachary Mahone')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (
  VALUES
    ('COMMERCE 1E03', '99d1523f-abc3-5933-821b-cbe0e6eb18fb'::UUID),
    ('ECON 1ME3', 'fa000000-0000-4000-8000-000000000008'::UUID),
    ('ECON 2A03', 'fa000000-0000-4000-8000-000000000009'::UUID),
    ('ECON 2Z03', 'fa000000-0000-4000-8000-000000000011'::UUID),
    ('ECON 3B03', 'fa000000-0000-4000-8000-000000000011'::UUID),
    ('ECON 3H03', 'ecd32005-1d84-5f96-9638-49b9db87c9fc'::UUID)
) AS mapping(course_code, professor_id)
JOIN public.courses AS course ON course.code = mapping.course_code
ON CONFLICT (course_id, professor_id) DO NOTHING;

WITH external_outlines(
  id, course_code, academic_year, term, professor_name, title,
  source_kind, source_url, source_page_url, source_name, mime_type
) AS (
  VALUES
    ('1f2ae6af-2020-578e-8103-ad7db3bcb364'::UUID,
     'COMMERCE 1BA3', 2026::SMALLINT, 'summer', 'Y. Lee',
     'COMMERCE 1BA3 Course Outline Summer 2026', 'external_pdf',
     'https://ug.degroote.mcmaster.ca/wp-content/uploads/sites/91/2026/05/COMM-1BA3-SS26-course-outline-Lee-3.pdf',
     'https://ug.degroote.mcmaster.ca/descriptions/1ba3/',
     'degroote_commerce', 'application/pdf'),
    ('31088d7f-0a56-5b7a-936d-fa1b42f2953d'::UUID,
     'COMMERCE 1E03', 2026::SMALLINT, 'fall', 'C. Capretta',
     'COMMERCE 1E03 Course Outline Fall 2026', 'external_pdf',
     'https://ug.degroote.mcmaster.ca/wp-content/uploads/sites/91/2026/09/COMM-1E03-F26-Capretta.pdf',
     'https://ug.degroote.mcmaster.ca/descriptions/1e03/',
     'degroote_commerce', 'application/pdf'),
    ('50b6fb81-6e29-5f79-ac34-d0562a072488'::UUID,
     'COMMERCE 2CO0', 2026::SMALLINT, 'fall', NULL,
     'COMMERCE 2CO0 Co-op and Career Development Course Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/765xzttj4/Fall-2026-COMMERCE-2CO0-C01-DLITTLE-Co-op-and-Career-Development-Course?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/765xzttj4/Fall-2026-COMMERCE-2CO0-C01-DLITTLE-Co-op-and-Career-Development-Course?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('d74acb74-8046-55ca-97f6-1790f9a10e52'::UUID,
     'COMMERCE 4SD3', 2026::SMALLINT, 'summer', 'K. Ketsetzis',
     'COMMERCE 4SD3 Course Outline Summer 2026', 'external_pdf',
     'https://ug.degroote.mcmaster.ca/wp-content/uploads/sites/91/2026/05/COMM-4SD3-S26-Ketsetzis.pdf',
     'https://ug.degroote.mcmaster.ca/descriptions/4sd3/',
     'degroote_commerce', 'application/pdf'),
    ('ae1d9b1a-2873-5ed5-944f-de99ca397c3c'::UUID,
     'ECON 1ME3', 2026::SMALLINT, 'fall', 'Anastasios Papanastasiou',
     'ECON 1ME3 Introduction to Mathematical Economics Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/z31rzzl3g/Fall-2026-ECON-1ME3-C01-PAPANASA-Introduction-to-Mathematical-Economics?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/z31rzzl3g/Fall-2026-ECON-1ME3-C01-PAPANASA-Introduction-to-Mathematical-Economics?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('693c7c37-f820-5121-bddb-b205d2e52472'::UUID,
     'ECON 2A03', 2026::SMALLINT, 'fall', 'Saeed-Ur-Rehman Rana',
     'ECON 2A03 Economics of Labour-Market Issues Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/rqunmrlfb/Fall-2026-ECON-2A03-C01-RANAS3-Economics-of-Labour-Market-Issues?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/rqunmrlfb/Fall-2026-ECON-2A03-C01-RANAS3-Economics-of-Labour-Market-Issues?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('f4702e02-4d78-5cf5-86f4-21c09a976511'::UUID,
     'ECON 2Z03', 2026::SMALLINT, 'fall', NULL,
     'ECON 2Z03 Intermediate Microeconomics I Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/polmoc4pz/Fall-2026-ECON-2Z03-C02-HEZ13-Intermediate-Microeconomics-I?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/polmoc4pz/Fall-2026-ECON-2Z03-C02-HEZ13-Intermediate-Microeconomics-I?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('b91a8389-e3de-561e-8e12-a84f28ca470d'::UUID,
     'ECON 2ZZ3', 2026::SMALLINT, 'fall', 'Anastasios Papanastasiou',
     'ECON 2ZZ3 Intermediate Microeconomics II Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/ipdj3wlsi/Fall-2026-ECON-2ZZ3-C01-PAPANASA-Intermediate-Microeconomics-II?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/ipdj3wlsi/Fall-2026-ECON-2ZZ3-C01-PAPANASA-Intermediate-Microeconomics-II?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('4348a8f4-5c05-54d7-8cf5-53b37a406bb2'::UUID,
     'ECON 3B03', 2026::SMALLINT, 'fall', 'Dr. Zhen He',
     'ECON 3B03 Public Sector Economics: Expenditures Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/usgitxxeb/Fall-2026-ECON-3B03-C01-HEZ13-Public-Sector-Economics-Expenditures?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/usgitxxeb/Fall-2026-ECON-3B03-C01-HEZ13-Public-Sector-Economics-Expenditures?mode=view',
     'mcmaster_simple_syllabus', 'text/html'),
    ('7c8352e6-c912-5afa-ac2e-fff887907d8e'::UUID,
     'ECON 3H03', 2026::SMALLINT, 'fall', 'Zachary Mahone',
     'ECON 3H03 International Monetary Economics Fall 2026', 'external_web',
     'https://mcmaster.simplesyllabusca.com/doc/6jdjxjb05/Fall-2026-ECON-3H03-C01-MAHONEZ-International-Monetary-Economics?mode=view',
     'https://mcmaster.simplesyllabusca.com/doc/6jdjxjb05/Fall-2026-ECON-3H03-C01-MAHONEZ-International-Monetary-Economics?mode=view',
     'mcmaster_simple_syllabus', 'text/html')
)
INSERT INTO public.course_external_outlines (
  id, course_id, academic_year, term, professor_name, title,
  source_kind, source_url, source_page_url, source_name, mime_type,
  last_verified_at
)
SELECT external.id, course.id, external.academic_year, external.term,
  external.professor_name, external.title, external.source_kind,
  external.source_url, external.source_page_url, external.source_name,
  external.mime_type, NOW()
FROM external_outlines AS external
JOIN public.courses AS course ON course.code = external.course_code;

NOTIFY pgrst, 'reload schema';

COMMIT;
