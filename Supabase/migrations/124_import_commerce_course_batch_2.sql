-- Import verified Commerce catalog batch 2.
--
-- Terms were selected from PDF content using the approved order:
-- Winter 2026, Fall 2025, Summer 2025, Winter 2025, then closest available.
-- The checked-in PDFs retain exact source bytes. Private Storage paths are
-- immutable and bound to their course UUID, term, byte size, and SHA-256.
-- Upload the matching Supabase/course-outlines objects before applying this
-- migration in a linked environment. Do not overwrite an existing object.

BEGIN;

-- Forward-only corrections discovered during the full source reconciliation.
UPDATE public.courses
SET title = 'Introductory Financial Accounting', updated_at = NOW()
WHERE code = 'COMMERCE 1AA3';

UPDATE public.courses
SET title = 'Managerial Accounting I', updated_at = NOW()
WHERE code = 'COMMERCE 2AB3';

INSERT INTO public.professors (id, name)
VALUES ('e5713643-8651-5adb-9b92-69dab26895b6', 'Sean O''Brady')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, 'e5713643-8651-5adb-9b92-69dab26895b6'::UUID
FROM public.courses AS course
WHERE course.code = 'COMMERCE 2BC3'
ON CONFLICT (course_id, professor_id) DO NOTHING;

INSERT INTO public.courses (id, code, title, subject, year_level, is_popular)
VALUES
  ('090f5eec-c94e-5f7e-93b1-a2f8aaeff0e6', 'COMMERCE 2DA3', 'Decision Making with Analytics', 'COMMERCE', 2, FALSE),
  ('6b0a04df-808a-5852-a43a-974e89fddaa6', 'COMMERCE 2GR0', 'DeGroote Student Experience and Development II', 'COMMERCE', 2, FALSE),
  ('4f3fd9b3-dd2f-514b-a383-5adf2c7b8f26', 'COMMERCE 2IN0', 'Career Development Course', 'COMMERCE', 2, FALSE),
  ('6bc3f9a0-e03a-5a9d-8d10-a983ff6e78f6', 'COMMERCE 2NG3', 'Negotiations', 'COMMERCE', 2, FALSE),
  ('efae50c0-c008-5951-a376-20aeecc59b9c', 'COMMERCE 2OC3', 'Operations Management', 'COMMERCE', 2, FALSE),
  ('523023d5-efc8-5080-8ea5-bc05f8826a37', 'COMMERCE 3AB3', 'Intermediate Financial Accounting I', 'COMMERCE', 3, FALSE),
  ('13593b6b-2fb0-5361-8f69-d2a860f7497d', 'COMMERCE 3AC3', 'Intermediate Financial Accounting II', 'COMMERCE', 3, FALSE),
  ('ed9df52e-89ca-5445-8bb1-c13634c1ba36', 'COMMERCE 3DA3', 'Predictive Analytics', 'COMMERCE', 3, FALSE),
  ('c0c133fb-e42c-5001-9b74-0326f2a667c7', 'COMMERCE 3FB3', 'Securities Analysis', 'COMMERCE', 3, FALSE),
  ('f4a0f3ed-a4f2-5bd2-8e8a-7040ce78e228', 'COMMERCE 3FD3', 'Financial Modelling', 'COMMERCE', 3, FALSE),
  ('43e1c98c-9528-5910-b3ac-3f99a03a1f75', 'COMMERCE 3FH3', 'Alternative Investments and Portfolio Management', 'COMMERCE', 3, FALSE),
  ('a895c600-f660-5d40-ae65-a47a3714106d', 'COMMERCE 3FI3', 'Market Trading with Options and Futures', 'COMMERCE', 3, FALSE),
  ('8bf11b18-707a-5c00-83ce-15f7cbad1da0', 'COMMERCE 3FK3', 'Intermediate Corporate Finance', 'COMMERCE', 3, FALSE),
  ('685e0de1-39e8-5e0c-9f62-8f283754777c', 'COMMERCE 3FM3', 'The History of Finance', 'COMMERCE', 3, FALSE),
  ('9d96fe46-f27e-5414-81c7-c5a5fdaff398', 'COMMERCE 3KA3', 'System Analysis and Design', 'COMMERCE', 3, FALSE),
  ('acfa9902-27d9-52ec-aecd-28fcd5f56fc4', 'COMMERCE 3KD3', 'Database Design Management and Applications', 'COMMERCE', 3, FALSE),
  ('55ede7dc-ab76-591c-95cc-75621829d02c', 'COMMERCE 3MB3', 'Consumer Behaviour', 'COMMERCE', 3, FALSE),
  ('c7dbbf55-d35a-5272-ae25-e14d76a3a762', 'COMMERCE 3MC3', 'Applied Marketing Management', 'COMMERCE', 3, FALSE),
  ('bbe11765-bbc5-564c-92c9-7d6b1f98645d', 'COMMERCE 3MD3', 'Introduction to Contemporary Applied Marketing', 'COMMERCE', 3, FALSE),
  ('9cd88f06-6256-5eec-895d-acf8f492774d', 'COMMERCE 3SO3', 'Management Skills Development', 'COMMERCE', 3, FALSE)
ON CONFLICT (code) DO UPDATE
SET title = EXCLUDED.title,
    subject = EXCLUDED.subject,
    year_level = EXCLUDED.year_level,
    updated_at = NOW();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('COMMERCE 2DA3', '090f5eec-c94e-5f7e-93b1-a2f8aaeff0e6'::UUID),
      ('COMMERCE 2GR0', '6b0a04df-808a-5852-a43a-974e89fddaa6'::UUID),
      ('COMMERCE 2IN0', '4f3fd9b3-dd2f-514b-a383-5adf2c7b8f26'::UUID),
      ('COMMERCE 2NG3', '6bc3f9a0-e03a-5a9d-8d10-a983ff6e78f6'::UUID),
      ('COMMERCE 2OC3', 'efae50c0-c008-5951-a376-20aeecc59b9c'::UUID),
      ('COMMERCE 3AB3', '523023d5-efc8-5080-8ea5-bc05f8826a37'::UUID),
      ('COMMERCE 3AC3', '13593b6b-2fb0-5361-8f69-d2a860f7497d'::UUID),
      ('COMMERCE 3DA3', 'ed9df52e-89ca-5445-8bb1-c13634c1ba36'::UUID),
      ('COMMERCE 3FB3', 'c0c133fb-e42c-5001-9b74-0326f2a667c7'::UUID),
      ('COMMERCE 3FD3', 'f4a0f3ed-a4f2-5bd2-8e8a-7040ce78e228'::UUID),
      ('COMMERCE 3FH3', '43e1c98c-9528-5910-b3ac-3f99a03a1f75'::UUID),
      ('COMMERCE 3FI3', 'a895c600-f660-5d40-ae65-a47a3714106d'::UUID),
      ('COMMERCE 3FK3', '8bf11b18-707a-5c00-83ce-15f7cbad1da0'::UUID),
      ('COMMERCE 3FM3', '685e0de1-39e8-5e0c-9f62-8f283754777c'::UUID),
      ('COMMERCE 3KA3', '9d96fe46-f27e-5414-81c7-c5a5fdaff398'::UUID),
      ('COMMERCE 3KD3', 'acfa9902-27d9-52ec-aecd-28fcd5f56fc4'::UUID),
      ('COMMERCE 3MB3', '55ede7dc-ab76-591c-95cc-75621829d02c'::UUID),
      ('COMMERCE 3MC3', 'c7dbbf55-d35a-5272-ae25-e14d76a3a762'::UUID),
      ('COMMERCE 3MD3', 'bbe11765-bbc5-564c-92c9-7d6b1f98645d'::UUID),
      ('COMMERCE 3SO3', '9cd88f06-6256-5eec-895d-acf8f492774d'::UUID)
    ) AS expected(code, id)
    JOIN public.courses AS course ON course.code = expected.code
    WHERE course.id <> expected.id
  ) THEN
    RAISE EXCEPTION
      'Commerce batch 2 course IDs conflict with checked-in Storage paths';
  END IF;
END;
$$;

INSERT INTO public.professors (id, name)
VALUES
  ('358c640d-b903-56fe-900f-8ca894733a28', 'Adeel Mahmood'),
  ('e628d60b-20f0-5a50-bf66-062efb02f78e', 'Ali Reza Montazemi'),
  ('b6409bf7-cb22-5c3d-981b-4e1ce931d667', 'Amar Sandher'),
  ('bdb1addc-8316-597d-9ef9-76b34a1363e6', 'Anita Boey'),
  ('aa6db7a1-12fa-5ca8-9a89-1b345231e11a', 'Brooke Russell'),
  ('99d1523f-abc3-5933-821b-cbe0e6eb18fb', 'Carolyn Capretta'),
  ('70710f34-7633-5470-b217-5345ae685363', 'Emanuele Blasioli'),
  ('789de7b3-add6-5421-ad1c-9bb9a446997d', 'Gabriel Jacobs'),
  ('79eab175-0e75-5942-b121-f671bf038218', 'John J. Siam'),
  ('91ea24a1-b40e-5186-a3ac-9e9eee15eb23', 'Justin Y. Jin'),
  ('7faa98cb-682f-51f7-9ebc-6da9d11a1a16', 'Kai Christine Lesage'),
  ('04c961af-aa6f-5209-8cc9-101ebc3e0613', 'Karlene Harry'),
  ('9a507ea8-24ee-5b65-b4a8-47761d50f871', 'Ken Li'),
  ('8cf5b583-2577-5974-926f-1d3959b9b152', 'Lingling Shi'),
  ('c145aaf0-6515-5fd3-9225-208b935f0c34', 'Mandeep Malik'),
  ('4032d83f-4b69-5aed-92a1-49fd4b8c3caa', 'Marvin Ryder'),
  ('1b40cf6c-3729-5aea-a0bf-df3172c5afde', 'Maureen Hupfer'),
  ('5354dfdb-589b-51ae-b3e9-9697227988e8', 'Rami Alasadi'),
  ('a28bd442-6666-5c5e-b744-47fa272ae798', 'Rouxanne Irving'),
  ('ad45f951-767a-5ea0-bada-d89832dd2ec8', 'Ruohan Jin'),
  ('c46e9218-e637-59d2-87ff-ef8df52232de', 'Shraddha Wilfred'),
  ('5dd38677-7b35-589e-bc18-e7c8bf6fc4ad', 'Skylar Wang'),
  ('e97f604d-f432-5c1b-9c46-c14b5e11158e', 'Sudipto Sarkar'),
  ('d8215b42-f164-5746-9b50-d96cec047de6', 'William Huggins'),
  ('3274b0d0-7d8c-53b3-a879-9496a09c6db6', 'Yingnan Zhao'),
  ('d7630827-2a0c-517b-abe6-9e7d9bceb555', 'Yufei Yuan'),
  ('0a9b8ede-b905-588e-a217-ccc991d408bc', 'Yun Zhou'),
  ('04d7d7e3-32a6-5467-9d67-a62c131a73a6', 'Yvonne S. Kwok'),
  ('f94e909a-e1c7-59b5-9e57-63532a060832', 'Zahra Mashayekhi'),
  ('855fcfe9-365e-5654-9769-1ee8fe0cf8ba', 'Zeinab Vosooghi'),
  ('820a3f59-a985-592c-ada0-996a303c563d', 'Zobia Jawed')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (VALUES
  ('COMMERCE 2DA3', '8cf5b583-2577-5974-926f-1d3959b9b152'::UUID),
  ('COMMERCE 2DA3', 'f94e909a-e1c7-59b5-9e57-63532a060832'::UUID),
  ('COMMERCE 2GR0', 'bdb1addc-8316-597d-9ef9-76b34a1363e6'::UUID),
  ('COMMERCE 2IN0', 'a28bd442-6666-5c5e-b744-47fa272ae798'::UUID),
  ('COMMERCE 2IN0', 'aa6db7a1-12fa-5ca8-9a89-1b345231e11a'::UUID),
  ('COMMERCE 2IN0', 'b6409bf7-cb22-5c3d-981b-4e1ce931d667'::UUID),
  ('COMMERCE 2IN0', '789de7b3-add6-5421-ad1c-9bb9a446997d'::UUID),
  ('COMMERCE 2NG3', 'bdb1addc-8316-597d-9ef9-76b34a1363e6'::UUID),
  ('COMMERCE 2NG3', '5354dfdb-589b-51ae-b3e9-9697227988e8'::UUID),
  ('COMMERCE 2NG3', '99d1523f-abc3-5933-821b-cbe0e6eb18fb'::UUID),
  ('COMMERCE 2OC3', '0a9b8ede-b905-588e-a217-ccc991d408bc'::UUID),
  ('COMMERCE 2OC3', '855fcfe9-365e-5654-9769-1ee8fe0cf8ba'::UUID),
  ('COMMERCE 3AB3', '9a507ea8-24ee-5b65-b4a8-47761d50f871'::UUID),
  ('COMMERCE 3AB3', '04d7d7e3-32a6-5467-9d67-a62c131a73a6'::UUID),
  ('COMMERCE 3AC3', '91ea24a1-b40e-5186-a3ac-9e9eee15eb23'::UUID),
  ('COMMERCE 3DA3', '70710f34-7633-5470-b217-5345ae685363'::UUID),
  ('COMMERCE 3FB3', '5dd38677-7b35-589e-bc18-e7c8bf6fc4ad'::UUID),
  ('COMMERCE 3FB3', 'ad45f951-767a-5ea0-bada-d89832dd2ec8'::UUID),
  ('COMMERCE 3FD3', '3274b0d0-7d8c-53b3-a879-9496a09c6db6'::UUID),
  ('COMMERCE 3FH3', '358c640d-b903-56fe-900f-8ca894733a28'::UUID),
  ('COMMERCE 3FI3', '79eab175-0e75-5942-b121-f671bf038218'::UUID),
  ('COMMERCE 3FK3', 'e97f604d-f432-5c1b-9c46-c14b5e11158e'::UUID),
  ('COMMERCE 3FM3', 'd8215b42-f164-5746-9b50-d96cec047de6'::UUID),
  ('COMMERCE 3KA3', 'e628d60b-20f0-5a50-bf66-062efb02f78e'::UUID),
  ('COMMERCE 3KD3', 'd7630827-2a0c-517b-abe6-9e7d9bceb555'::UUID),
  ('COMMERCE 3MB3', '1b40cf6c-3729-5aea-a0bf-df3172c5afde'::UUID),
  ('COMMERCE 3MC3', 'c145aaf0-6515-5fd3-9225-208b935f0c34'::UUID),
  ('COMMERCE 3MC3', '7faa98cb-682f-51f7-9ebc-6da9d11a1a16'::UUID),
  ('COMMERCE 3MC3', '4032d83f-4b69-5aed-92a1-49fd4b8c3caa'::UUID),
  ('COMMERCE 3MD3', '820a3f59-a985-592c-ada0-996a303c563d'::UUID),
  ('COMMERCE 3SO3', '99d1523f-abc3-5933-821b-cbe0e6eb18fb'::UUID),
  ('COMMERCE 3SO3', 'c46e9218-e637-59d2-87ff-ef8df52232de'::UUID),
  ('COMMERCE 3SO3', '04c961af-aa6f-5209-8cc9-101ebc3e0613'::UUID)
) AS mapping(course_code, professor_id)
JOIN public.courses AS course ON course.code = mapping.course_code
ON CONFLICT (course_id, professor_id) DO NOTHING;

INSERT INTO public.course_outlines (
  course_id, academic_year, term, professor_name, title, storage_path,
  original_filename, mime_type, file_size_bytes, sha256
)
SELECT course.id,
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
FROM (VALUES
  (
      'COMMERCE 2DA3',
      2025::SMALLINT,
      'fall',
      'Lingling Shi',
      'COMMERCE 2DA3 Course Outline Fall 2025',
      '2DA3 - Fall 2025 - C01, C02, C04 - L. Shi.pdf',
      347814::BIGINT,
      '11a1127a83a28a0c797308689a3fbe15da9761f94ab38c1430d64ade2b9d5d04'
    ),
  (
      'COMMERCE 2GR0',
      2026::SMALLINT,
      'winter',
      'Anita Boey',
      'COMMERCE 2GR0 Course Outline Winter 2026',
      '2GR0 - Winter 2026 - C01, C02 - A. Boey.pdf',
      385554::BIGINT,
      '0a6ad9ecf20f74bbcde2a937a10377fff5a064ef2626f14603ca514eff6caf10'
    ),
  (
      'COMMERCE 2IN0',
      2026::SMALLINT,
      'winter',
      'Rouxanne Irving; Brooke Russell; Amar Sandher; Gabriel Jacobs',
      'COMMERCE 2IN0 Course Outline Winter 2026',
      '2IN0 - Winter 2026 - Irving (R), Russell (B), Sandher (A), Jacobs (G).pdf',
      381959::BIGINT,
      'd8615323d99279129bdfd471a546ff5ab4145fae23567e90a89868151504fb6e'
    ),
  (
      'COMMERCE 2NG3',
      2025::SMALLINT,
      'fall',
      'Anita Boey',
      'COMMERCE 2NG3 Course Outline Fall 2025',
      '2NG3 - Fall 2025 - C01, C02, C05 - A. Boey.pdf',
      317460::BIGINT,
      '79fb91c6b54af40cc924cbbaea8171dd4d0a6f0184b416f513e3857f90392c4e'
    ),
  (
      'COMMERCE 2OC3',
      2026::SMALLINT,
      'winter',
      'Yun Zhou',
      'COMMERCE 2OC3 Course Outline Winter 2026',
      '2OC3 - Winter 2026 - C01, C02, C03 - Y.Zhou.pdf',
      1337028::BIGINT,
      'e8b5de689c2924407eb5a9fd1bb28d99b811a523ed1f5df8dafaff808b02e695'
    ),
  (
      'COMMERCE 3AB3',
      2025::SMALLINT,
      'fall',
      'Ken Li; Yvonne S. Kwok',
      'COMMERCE 3AB3 Course Outline Fall 2025',
      '3AB3 - Fall 2025 - K. Li _ Y. Kwok.pdf',
      594758::BIGINT,
      '00d04673cfc13e9798453f6f78592f79a46a646bf5857e581222c6288b89eaae'
    ),
  (
      'COMMERCE 3AC3',
      2026::SMALLINT,
      'winter',
      'Justin Y. Jin',
      'COMMERCE 3AC3 Course Outline Winter 2026',
      '3AC3 - Winter 2026 - J.Jin.pdf',
      295540::BIGINT,
      '29c79d96bd0260066ca11a49cafdadea38f65b797f098a9bf086404a792377a5'
    ),
  (
      'COMMERCE 3DA3',
      2026::SMALLINT,
      'winter',
      'Emanuele Blasioli',
      'COMMERCE 3DA3 Course Outline Winter 2026',
      '3DA3 - Winter 2026 - C01 - E. Blasioli.pdf',
      175642::BIGINT,
      '91901dbc398b6b4604b50b55f1b2e0f2475af42613f8c708c56bfbb018354115'
    ),
  (
      'COMMERCE 3FB3',
      2026::SMALLINT,
      'winter',
      'Skylar Wang',
      'COMMERCE 3FB3 Course Outline Winter 2026',
      '3FB3 - Winter 2026 - S. Wang.pdf',
      245880::BIGINT,
      '5c494ec0c80e44f3431c645616fc053b75fcccab126bfd9ca5a123dee30d5ed2'
    ),
  (
      'COMMERCE 3FD3',
      2026::SMALLINT,
      'winter',
      'Yingnan Zhao',
      'COMMERCE 3FD3 Course Outline Winter 2026',
      '3FD3 - Winter 2026 - Y. Zhao.pdf',
      171865::BIGINT,
      '9a59f67c98b0d2999c746fcddaf00863c3eda8e2743a761e9c8ca281f8de7487'
    ),
  (
      'COMMERCE 3FH3',
      2026::SMALLINT,
      'winter',
      'Adeel Mahmood',
      'COMMERCE 3FH3 Course Outline Winter 2026',
      '3FH3 - Winter 2026 - A. Mahmood.pdf',
      273313::BIGINT,
      '29074d9f05f1a16556fcbab4298f96b265b2d87273dc996fdbcb1cf7e2fc6292'
    ),
  (
      'COMMERCE 3FI3',
      2026::SMALLINT,
      'winter',
      'John J. Siam',
      'COMMERCE 3FI3 Course Outline Winter 2026',
      '3FI3 - Winter 2026 - J. Siam.pdf',
      386988::BIGINT,
      'b43c921ec58fe11e09c1b5782946fd2e3e933edefbb874ceda2b79c7d44fc53b'
    ),
  (
      'COMMERCE 3FK3',
      2025::SMALLINT,
      'fall',
      'Sudipto Sarkar',
      'COMMERCE 3FK3 Course Outline Fall 2025',
      '3FK3 - Fall 2025 - C01 - S. Sarkar.pdf',
      571996::BIGINT,
      '7d14e7b7c3c07a5d355f1493592eaedd38f3dd0dc9c8851631c1f815fc7e8fae'
    ),
  (
      'COMMERCE 3FM3',
      2026::SMALLINT,
      'winter',
      'William Huggins',
      'COMMERCE 3FM3 Course Outline Winter 2026',
      '3FM3 - Winter 2026 - W. Huggins.pdf',
      306266::BIGINT,
      '6b139edb808cfac369da177827063b1c927cf71cb86d81d7d11bf2cb584b6b9e'
    ),
  (
      'COMMERCE 3KA3',
      2025::SMALLINT,
      'fall',
      'Ali Reza Montazemi',
      'COMMERCE 3KA3 Course Outline Fall 2025',
      '3KA3 - Fall 2025 - C01 - A. Montazemi.pdf',
      300728::BIGINT,
      'd306543a16c6f6eaeb8d3a76a85c5439c06a1a454113a99cddb5ebc51590d065'
    ),
  (
      'COMMERCE 3KD3',
      2026::SMALLINT,
      'winter',
      'Yufei Yuan',
      'COMMERCE 3KD3 Course Outline Winter 2026',
      '3KD3 - Winter 2026 - C01, C02, C03 - Y. Yuan.pdf',
      389265::BIGINT,
      '50e4d6ae92b8d25b208a5f8cd6739e2dfcee4c09c87da98728b1f99890145453'
    ),
  (
      'COMMERCE 3MB3',
      2026::SMALLINT,
      'winter',
      'Maureen Hupfer',
      'COMMERCE 3MB3 Course Outline Winter 2026',
      '3MB3 - Winter 2026 - M. Hupfer.pdf',
      417039::BIGINT,
      '8de1585419343e2bbbcd91966467729ee980c3515e709318304f3a95d67dbdc9'
    ),
  (
      'COMMERCE 3MC3',
      2026::SMALLINT,
      'winter',
      'Mandeep Malik',
      'COMMERCE 3MC3 Course Outline Winter 2026',
      '3MC3 - Winter 2026 - C01, C03 - M. Malik.pdf',
      481630::BIGINT,
      'e22f00d75ecd99221f8c3b6c5ab57e4e1f55dda5e2f90c379101e7de88679da5'
    ),
  (
      'COMMERCE 3MD3',
      2023::SMALLINT,
      'winter',
      'Zobia Jawed',
      'COMMERCE 3MD3 Course Outline Winter 2023',
      '3MD3 - Winter 2023 - C01, C02 - Z. Jawed.pdf',
      691751::BIGINT,
      'd8e2044eab2a69406f58c699dc4fd24c5064219f5483df577a56ce2b99db94c4'
    ),
  (
      'COMMERCE 3SO3',
      2023::SMALLINT,
      'winter',
      'Carolyn Capretta',
      'COMMERCE 3SO3 Course Outline Winter 2023',
      '3SO3 - Winter 2023 - C01, C02, C03, C04, C05, C06 - C. Capretta.pdf',
      286263::BIGINT,
      '35ef763dd5bf52c56d17d3c88e2dd4a4a4a97575c2ecef2fa30ad4e6136ffafe'
    )
) AS outline(
  course_code, academic_year, term, professor_name, title,
  original_filename, file_size_bytes, sha256
)
JOIN public.courses AS course ON course.code = outline.course_code
ON CONFLICT (course_id, academic_year, term, sha256) DO UPDATE
SET professor_name = EXCLUDED.professor_name,
    title = EXCLUDED.title,
    original_filename = EXCLUDED.original_filename,
    mime_type = EXCLUDED.mime_type,
    file_size_bytes = EXCLUDED.file_size_bytes;

NOTIFY pgrst, 'reload schema';

COMMIT;
