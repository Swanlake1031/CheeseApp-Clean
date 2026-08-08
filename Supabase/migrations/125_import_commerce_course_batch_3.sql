-- Import verified Commerce catalog batch 3.
--
-- Terms were selected from PDF content using the approved order:
-- Winter 2026, Fall 2025, Summer 2025, Winter 2025, then closest available.
-- The checked-in PDFs retain exact source bytes. Private Storage paths are
-- immutable and bound to their course UUID, term, byte size, and SHA-256.
-- Upload the matching Supabase/course-outlines objects before applying this
-- migration in a linked environment. Do not overwrite an existing object.

BEGIN;

INSERT INTO public.courses (id, code, title, subject, year_level, is_popular)
VALUES
  ('b6e6a608-4fad-5699-a468-7d8c7a28f967', 'COMMERCE 4AA3', 'Managerial Accounting II', 'COMMERCE', 4, FALSE),
  ('9ab60091-6472-5611-8849-f1fdd63c5677', 'COMMERCE 4AC3', 'Advanced Financial Accounting', 'COMMERCE', 4, FALSE),
  ('c1f248b2-b8b4-56d0-a73d-15b517135cd3', 'COMMERCE 4AF3', 'Accounting Theory', 'COMMERCE', 4, FALSE),
  ('4076138c-68fd-5db3-aa2c-4164b9cc2cf1', 'COMMERCE 4AK3', 'Accounting Information for Decision Making', 'COMMERCE', 4, FALSE),
  ('36371648-e8b9-5a0a-982b-3bab344f3c94', 'COMMERCE 4BB3', 'Recruitment and Selection', 'COMMERCE', 4, FALSE),
  ('c203fac3-6e6d-56b8-adfb-f765c8c68e78', 'COMMERCE 4BC3', 'Collective Bargaining', 'COMMERCE', 4, FALSE),
  ('319f925d-3c2d-5d36-9850-39fb4f17d546', 'COMMERCE 4BE3', 'Strategic Compensation/Reward Systems', 'COMMERCE', 4, FALSE),
  ('02f63f29-47ab-5b12-88c8-d590bc3a6380', 'COMMERCE 4BF3', 'Labour Law and Policy', 'COMMERCE', 4, FALSE),
  ('945c079a-b7c7-5601-a3d6-caceef871a03', 'COMMERCE 4BI3', 'Training and Development', 'COMMERCE', 4, FALSE),
  ('6edc9f86-ecb1-5457-a158-ef617ca25df7', 'COMMERCE 4BL3', 'Occupational Health and Safety Management', 'COMMERCE', 4, FALSE),
  ('d42c74a4-6b10-58cc-982e-09e3c5a55236', 'COMMERCE 4BM3', 'Strategic Human Resource Planning', 'COMMERCE', 4, FALSE),
  ('d46a9323-083d-5adc-b1d0-a5886135e9b1', 'COMMERCE 4BP3', 'Principles of Leadership', 'COMMERCE', 4, FALSE),
  ('34d50da7-6430-536c-b6d0-ac3ef3dd916b', 'COMMERCE 4CA3', 'Managing and Promoting Health and Healthcare Services', 'COMMERCE', 4, FALSE),
  ('35be3104-54a0-51a8-8d9b-013276dc64c1', 'COMMERCE 4DA3', 'Modelling and Prescriptive Analytics', 'COMMERCE', 4, FALSE),
  ('2f2071b3-a5fa-572c-85d9-aef051bfb768', 'COMMERCE 4FA3', 'Applied Corporate Finance', 'COMMERCE', 4, FALSE),
  ('a21aecdc-3ec4-5c50-9f80-5be75f5ca455', 'COMMERCE 4FB3', 'Valuation for Finance Professionals', 'COMMERCE', 4, FALSE),
  ('9a80a174-be90-5b42-b0c7-e4a8a33a5ba3', 'COMMERCE 4FC3', 'Ethics and Professional Practice in Finance', 'COMMERCE', 4, FALSE),
  ('a35ec800-9996-5322-8ba3-8a4b276e9ee6', 'COMMERCE 4FD3', 'Financial Institutions', 'COMMERCE', 4, FALSE),
  ('4c6d8fae-d625-59bb-a0d3-370bc5b22479', 'COMMERCE 4FE3', 'Options and Futures', 'COMMERCE', 4, FALSE),
  ('bfcf3c9d-a087-590e-b08e-d8883a1387f9', 'COMMERCE 4FF3', 'Portfolio Theory and Management', 'COMMERCE', 4, FALSE),
  ('1d3f0e64-d6be-50b6-9710-d890b41cb26a', 'COMMERCE 4FG3', 'Financial Theory', 'COMMERCE', 4, FALSE),
  ('a83e0070-ebd6-508d-9b54-43981e726fe2', 'COMMERCE 4FH3', 'Mergers, Acquisitions and Corporate Control', 'COMMERCE', 4, FALSE),
  ('1a3e8e58-36c1-5028-8124-eb93673ba883', 'COMMERCE 4FK3', 'Financial Statement Analysis', 'COMMERCE', 4, FALSE),
  ('6b23b18f-6c5f-50b8-8089-09bc59959986', 'COMMERCE 4FL3', 'Personal Financial Management', 'COMMERCE', 4, FALSE),
  ('22f7b586-bb6a-53e9-89ac-68b42f03ea2e', 'COMMERCE 4FM3', 'Personal Financial Planning and Advising', 'COMMERCE', 4, FALSE),
  ('d70a91bb-c7a6-5824-b260-95c57c3ca5ea', 'COMMERCE 4FN3', 'Financial Risk Management', 'COMMERCE', 4, FALSE),
  ('9d645975-9018-5cc6-8dac-3c1e49efc771', 'COMMERCE 4FO3', 'Small Business and Entrepreneurial Finance', 'COMMERCE', 4, FALSE),
  ('bd0433ee-75d1-5e3d-a363-3604b4778d74', 'COMMERCE 4FP3', 'Personal Finance', 'COMMERCE', 4, FALSE),
  ('5df6871a-eca2-5b92-8d78-86ff654f6819', 'COMMERCE 4FQ3', 'Working Capital Management', 'COMMERCE', 4, FALSE),
  ('f4238e45-f45e-5a6f-8aba-97fb3b3694be', 'COMMERCE 4FR3', 'Insurance and Risk Management', 'COMMERCE', 4, FALSE)
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
      ('COMMERCE 4AA3', 'b6e6a608-4fad-5699-a468-7d8c7a28f967'::UUID),
      ('COMMERCE 4AC3', '9ab60091-6472-5611-8849-f1fdd63c5677'::UUID),
      ('COMMERCE 4AF3', 'c1f248b2-b8b4-56d0-a73d-15b517135cd3'::UUID),
      ('COMMERCE 4AK3', '4076138c-68fd-5db3-aa2c-4164b9cc2cf1'::UUID),
      ('COMMERCE 4BB3', '36371648-e8b9-5a0a-982b-3bab344f3c94'::UUID),
      ('COMMERCE 4BC3', 'c203fac3-6e6d-56b8-adfb-f765c8c68e78'::UUID),
      ('COMMERCE 4BE3', '319f925d-3c2d-5d36-9850-39fb4f17d546'::UUID),
      ('COMMERCE 4BF3', '02f63f29-47ab-5b12-88c8-d590bc3a6380'::UUID),
      ('COMMERCE 4BI3', '945c079a-b7c7-5601-a3d6-caceef871a03'::UUID),
      ('COMMERCE 4BL3', '6edc9f86-ecb1-5457-a158-ef617ca25df7'::UUID),
      ('COMMERCE 4BM3', 'd42c74a4-6b10-58cc-982e-09e3c5a55236'::UUID),
      ('COMMERCE 4BP3', 'd46a9323-083d-5adc-b1d0-a5886135e9b1'::UUID),
      ('COMMERCE 4CA3', '34d50da7-6430-536c-b6d0-ac3ef3dd916b'::UUID),
      ('COMMERCE 4DA3', '35be3104-54a0-51a8-8d9b-013276dc64c1'::UUID),
      ('COMMERCE 4FA3', '2f2071b3-a5fa-572c-85d9-aef051bfb768'::UUID),
      ('COMMERCE 4FB3', 'a21aecdc-3ec4-5c50-9f80-5be75f5ca455'::UUID),
      ('COMMERCE 4FC3', '9a80a174-be90-5b42-b0c7-e4a8a33a5ba3'::UUID),
      ('COMMERCE 4FD3', 'a35ec800-9996-5322-8ba3-8a4b276e9ee6'::UUID),
      ('COMMERCE 4FE3', '4c6d8fae-d625-59bb-a0d3-370bc5b22479'::UUID),
      ('COMMERCE 4FF3', 'bfcf3c9d-a087-590e-b08e-d8883a1387f9'::UUID),
      ('COMMERCE 4FG3', '1d3f0e64-d6be-50b6-9710-d890b41cb26a'::UUID),
      ('COMMERCE 4FH3', 'a83e0070-ebd6-508d-9b54-43981e726fe2'::UUID),
      ('COMMERCE 4FK3', '1a3e8e58-36c1-5028-8124-eb93673ba883'::UUID),
      ('COMMERCE 4FL3', '6b23b18f-6c5f-50b8-8089-09bc59959986'::UUID),
      ('COMMERCE 4FM3', '22f7b586-bb6a-53e9-89ac-68b42f03ea2e'::UUID),
      ('COMMERCE 4FN3', 'd70a91bb-c7a6-5824-b260-95c57c3ca5ea'::UUID),
      ('COMMERCE 4FO3', '9d645975-9018-5cc6-8dac-3c1e49efc771'::UUID),
      ('COMMERCE 4FP3', 'bd0433ee-75d1-5e3d-a363-3604b4778d74'::UUID),
      ('COMMERCE 4FQ3', '5df6871a-eca2-5b92-8d78-86ff654f6819'::UUID),
      ('COMMERCE 4FR3', 'f4238e45-f45e-5a6f-8aba-97fb3b3694be'::UUID)
    ) AS expected(code, id)
    JOIN public.courses AS course ON course.code = expected.code
    WHERE course.id <> expected.id
  ) THEN
    RAISE EXCEPTION
      'Commerce batch 3 course IDs conflict with checked-in Storage paths';
  END IF;
END;
$$;

INSERT INTO public.professors (id, name)
VALUES
  ('e36b08a0-3ccc-56bf-908e-47d769b208a3', 'A. S. Merali'),
  ('a6784f89-4458-5d2d-9be7-45b5e8758107', 'Alicia Damley'),
  ('a8f75436-b349-5f05-9deb-2734ca032154', 'Andrew Aziz'),
  ('4fe2ac13-7057-5cb9-a85e-ce7031154694', 'Anna N. Danielova'),
  ('13395958-d0d7-5672-982d-67424bb22338', 'C. Sherman Cheung'),
  ('fda8b519-6dc7-504d-b4b0-37e275af6f76', 'Greg Rombough'),
  ('d570dde4-10db-5ccc-8909-c42f0ffd2c62', 'Helen Chen'),
  ('0fd15427-eaea-5e57-a3b2-1af5ff8859d4', 'Imran Abdool'),
  ('6be7bafa-546e-5579-9999-d5a529c7a822', 'Judy Fudge'),
  ('91ea24a1-b40e-5186-a3ac-9e9eee15eb23', 'Justin Y. Jin'),
  ('1bcf7840-f642-5149-a3ff-d448c1f974cc', 'Katia Harvie'),
  ('6d7428c2-e18a-526e-88a9-b999c65086fb', 'Lucy Djelalian Pepper'),
  ('803c230f-42fa-5042-9553-0c4b01e20345', 'R. Luo'),
  ('8ffb4e01-9af0-5a24-9c39-240dbc83aa9c', 'Richard Smale'),
  ('e97f604d-f432-5c1b-9c46-c14b5e11158e', 'Sudipto Sarkar'),
  ('a590951d-be04-5a49-be92-f2c76958ef3a', 'Sultan M. Awan'),
  ('0c028948-9669-527e-83ca-3cff25974555', 'Sumit Bose'),
  ('70b14b60-dac6-5a13-a8a0-262c9c455292', 'Waquar Ahmad'),
  ('a83372a1-b8db-5a1a-9d1e-570f8e89ca2b', 'Yair Berson'),
  ('d2656efd-05d9-57e0-8a7b-2fbce3961fc8', 'Yao Yao'),
  ('04d7d7e3-32a6-5467-9d67-a62c131a73a6', 'Yvonne S. Kwok'),
  ('855fcfe9-365e-5654-9769-1ee8fe0cf8ba', 'Zeinab Vosooghi')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (VALUES
  ('COMMERCE 4AA3', 'e36b08a0-3ccc-56bf-908e-47d769b208a3'::UUID),
  ('COMMERCE 4AC3', '04d7d7e3-32a6-5467-9d67-a62c131a73a6'::UUID),
  ('COMMERCE 4AF3', '91ea24a1-b40e-5186-a3ac-9e9eee15eb23'::UUID),
  ('COMMERCE 4AK3', 'fda8b519-6dc7-504d-b4b0-37e275af6f76'::UUID),
  ('COMMERCE 4BB3', 'd2656efd-05d9-57e0-8a7b-2fbce3961fc8'::UUID),
  ('COMMERCE 4BC3', '8ffb4e01-9af0-5a24-9c39-240dbc83aa9c'::UUID),
  ('COMMERCE 4BE3', 'd2656efd-05d9-57e0-8a7b-2fbce3961fc8'::UUID),
  ('COMMERCE 4BF3', '6be7bafa-546e-5579-9999-d5a529c7a822'::UUID),
  ('COMMERCE 4BI3', 'd570dde4-10db-5ccc-8909-c42f0ffd2c62'::UUID),
  ('COMMERCE 4BL3', '6d7428c2-e18a-526e-88a9-b999c65086fb'::UUID),
  ('COMMERCE 4BM3', 'd2656efd-05d9-57e0-8a7b-2fbce3961fc8'::UUID),
  ('COMMERCE 4BP3', 'a83372a1-b8db-5a1a-9d1e-570f8e89ca2b'::UUID),
  ('COMMERCE 4CA3', '1bcf7840-f642-5149-a3ff-d448c1f974cc'::UUID),
  ('COMMERCE 4DA3', '855fcfe9-365e-5654-9769-1ee8fe0cf8ba'::UUID),
  ('COMMERCE 4FA3', '4fe2ac13-7057-5cb9-a85e-ce7031154694'::UUID),
  ('COMMERCE 4FB3', '4fe2ac13-7057-5cb9-a85e-ce7031154694'::UUID),
  ('COMMERCE 4FC3', '0c028948-9669-527e-83ca-3cff25974555'::UUID),
  ('COMMERCE 4FD3', 'a590951d-be04-5a49-be92-f2c76958ef3a'::UUID),
  ('COMMERCE 4FE3', '803c230f-42fa-5042-9553-0c4b01e20345'::UUID),
  ('COMMERCE 4FF3', 'a8f75436-b349-5f05-9deb-2734ca032154'::UUID),
  ('COMMERCE 4FG3', '0fd15427-eaea-5e57-a3b2-1af5ff8859d4'::UUID),
  ('COMMERCE 4FH3', 'e97f604d-f432-5c1b-9c46-c14b5e11158e'::UUID),
  ('COMMERCE 4FK3', 'a6784f89-4458-5d2d-9be7-45b5e8758107'::UUID),
  ('COMMERCE 4FL3', '0c028948-9669-527e-83ca-3cff25974555'::UUID),
  ('COMMERCE 4FM3', '0c028948-9669-527e-83ca-3cff25974555'::UUID),
  ('COMMERCE 4FN3', 'a6784f89-4458-5d2d-9be7-45b5e8758107'::UUID),
  ('COMMERCE 4FO3', '70b14b60-dac6-5a13-a8a0-262c9c455292'::UUID),
  ('COMMERCE 4FP3', '13395958-d0d7-5672-982d-67424bb22338'::UUID),
  ('COMMERCE 4FQ3', 'e97f604d-f432-5c1b-9c46-c14b5e11158e'::UUID),
  ('COMMERCE 4FR3', '0c028948-9669-527e-83ca-3cff25974555'::UUID)
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
      'COMMERCE 4AA3',
      2026::SMALLINT,
      'winter',
      'A. S. Merali',
      'COMMERCE 4AA3 Course Outline Winter 2026',
      '4AA3 - Winter 2026 - A. S. Merali.pdf',
      435773::BIGINT,
      'c2d7ac85bcbc4106c663fee3d729afd79265c8833e679b4ec52aa280506b0c7d'
    ),
  (
      'COMMERCE 4AC3',
      2026::SMALLINT,
      'winter',
      'Yvonne S. Kwok',
      'COMMERCE 4AC3 Course Outline Winter 2026',
      '4AC3 - Winter 2026 - Y. Kwok.pdf',
      416709::BIGINT,
      'ffa90d7fae87a02052b03fcaac17322067a736bb962980b55f4d843e8a99cb00'
    ),
  (
      'COMMERCE 4AF3',
      2026::SMALLINT,
      'winter',
      'Justin Y. Jin',
      'COMMERCE 4AF3 Course Outline Winter 2026',
      '4AF3 - Winter 2026 - J. Jin.pdf',
      378266::BIGINT,
      '88e6376b83c1cb4ddaf85d5c0633e42e02153619a407ae5b3c7c53648f702491'
    ),
  (
      'COMMERCE 4AK3',
      2025::SMALLINT,
      'winter',
      'Greg Rombough',
      'COMMERCE 4AK3 Course Outline Winter 2025',
      '4AK3 - Winter 2025 - G. Rombough.pdf',
      220230::BIGINT,
      'c5b73c988ee2e84e39576d5ee9ba6b2f281aef5d515f8fcb8f2752094ffc31a7'
    ),
  (
      'COMMERCE 4BB3',
      2026::SMALLINT,
      'winter',
      'Yao Yao',
      'COMMERCE 4BB3 Course Outline Winter 2026',
      '4BB3 - Winter 2026 - C01 - Y. Yao.pdf',
      146537::BIGINT,
      '980823733b349a95b781acc3e36d47382f6a3c2ef26ad8d52e43abc7e70f3faf'
    ),
  (
      'COMMERCE 4BC3',
      2026::SMALLINT,
      'winter',
      'Richard Smale',
      'COMMERCE 4BC3 Course Outline Winter 2026',
      '4BC3 - Winter 2026 - C01 - R. Smale.pdf',
      474813::BIGINT,
      '94de0c1a46db60b36a333878fc3b4a780f557a0b1c9c33f592ce85e11c4c0c74'
    ),
  (
      'COMMERCE 4BE3',
      2025::SMALLINT,
      'fall',
      'Yao Yao',
      'COMMERCE 4BE3 Course Outline Fall 2025',
      '4BE3 - Fall 2025 - C01 - Y. Yao.pdf',
      326032::BIGINT,
      '5a1a2e84a5822286fb2be89b6aa7929ba08b9e4b6b0b6f1eaa6e62356831cdb3'
    ),
  (
      'COMMERCE 4BF3',
      2024::SMALLINT,
      'winter',
      'Judy Fudge',
      'COMMERCE 4BF3 Course Outline Winter 2024',
      '4BF3 - Winter 2024 - C01 - J. Fudge.pdf',
      315323::BIGINT,
      'c3de34d4ed396dc85b8843717e5db593e4bd42cff62c01b30f2b970030c1c7f4'
    ),
  (
      'COMMERCE 4BI3',
      2025::SMALLINT,
      'fall',
      'Helen Chen',
      'COMMERCE 4BI3 Course Outline Fall 2025',
      '4BI3 - Fall 2025 - C01 - H. Chen.pdf',
      967560::BIGINT,
      'a5bbc3087cd41dd41b4cc699d09a8ae2b658c5b9a2ae1e8cd6480ebe636cab91'
    ),
  (
      'COMMERCE 4BL3',
      2025::SMALLINT,
      'fall',
      'Lucy Djelalian Pepper',
      'COMMERCE 4BL3 Course Outline Fall 2025',
      '4BL3 - Fall 2025 - C01 - L. Djelalian-Pepper.pdf',
      398167::BIGINT,
      'e167c5b2646435debf445138bd287139bbf414718cfabdf3f25e2eb0e7e8d2ba'
    ),
  (
      'COMMERCE 4BM3',
      2026::SMALLINT,
      'winter',
      'Yao Yao',
      'COMMERCE 4BM3 Course Outline Winter 2026',
      '4BM3 - Winter 2026 - C01 - Y. Yao.pdf',
      150347::BIGINT,
      '1b42ca13ba508c8eaaf67f3f2c1f42537735f1b66538558fdb1297a31394b277'
    ),
  (
      'COMMERCE 4BP3',
      2025::SMALLINT,
      'fall',
      'Yair Berson',
      'COMMERCE 4BP3 Course Outline Fall 2025',
      '4BP3 - Fall 2025 - C01 - Y. Berson.pdf',
      470353::BIGINT,
      '7f2e095cfc5cacfc1cf6bfe0f59e405fdd667f88c442f4fcd96b454283f18aaa'
    ),
  (
      'COMMERCE 4CA3',
      2021::SMALLINT,
      'winter',
      'Katia Harvie',
      'COMMERCE 4CA3 Course Outline Winter 2021',
      '4CA3 - Winter 2021 - C01 - K. Khaddadine (Harvie).pdf',
      219434::BIGINT,
      '952cdf0fb82f4b1d8264ae3608446f9a55747a0fda1c2ff66ae447ad9d5789f0'
    ),
  (
      'COMMERCE 4DA3',
      2025::SMALLINT,
      'fall',
      'Zeinab Vosooghi',
      'COMMERCE 4DA3 Course Outline Fall 2025',
      '4DA3 - Fall 2025 - C01 - Z. Vosooghi.pdf',
      357115::BIGINT,
      '93af84ebd9c8d66124cc95b0b5cdeac97b0400965c12a357c4bd6086f9b5fbf4'
    ),
  (
      'COMMERCE 4FA3',
      2026::SMALLINT,
      'winter',
      'Anna N. Danielova',
      'COMMERCE 4FA3 Course Outline Winter 2026',
      '4FA3 - Winter 2026 - A. Danielova.pdf',
      329432::BIGINT,
      '5f01b6480c56714cccacc1e2714a1a69a491cbbbf8544952babf5d8be5bb26b8'
    ),
  (
      'COMMERCE 4FB3',
      2026::SMALLINT,
      'winter',
      'Anna N. Danielova',
      'COMMERCE 4FB3 Course Outline Winter 2026',
      '4FB3 - Winter 2026 - A. Danielova.pdf',
      455382::BIGINT,
      '6603151c53fc4e3981c7fbdcc234836e3141b0ab1aa0dd6c9912029afe61fb95'
    ),
  (
      'COMMERCE 4FC3',
      2025::SMALLINT,
      'fall',
      'Sumit Bose',
      'COMMERCE 4FC3 Course Outline Fall 2025',
      '4FC3 - Fall 2025 - C01 - S. Bose.pdf',
      350799::BIGINT,
      '29ff170864cdf44c8401319f469fa005a5a16212774ee959cd3c849fcff657bd'
    ),
  (
      'COMMERCE 4FD3',
      2024::SMALLINT,
      'fall',
      'Sultan M. Awan',
      'COMMERCE 4FD3 Course Outline Fall 2024',
      '4FD3 - Fall 2024 - S. Mehmood.pdf',
      375751::BIGINT,
      'd35d4e5baea59f942cd5948f8465fd1cf2fb266011ebe16a3d492c06083629ea'
    ),
  (
      'COMMERCE 4FE3',
      2025::SMALLINT,
      'winter',
      'R. Luo',
      'COMMERCE 4FE3 Course Outline Winter 2025',
      '4FE3 - Winter 2025 - R. Luo.pdf',
      296310::BIGINT,
      'f63077bee0eea71bf3e8908c8698171d0737ee7711c912722f035577ddb80370'
    ),
  (
      'COMMERCE 4FF3',
      2024::SMALLINT,
      'fall',
      'Andrew Aziz',
      'COMMERCE 4FF3 Course Outline Fall 2024',
      '4FF3 - Fall 2024 - A. Aziz.pdf',
      274610::BIGINT,
      '2b1128758ab5566461dd32fd37b2ea217ce364ccf7e9643d8738f8a2fe6c7200'
    ),
  (
      'COMMERCE 4FG3',
      2023::SMALLINT,
      'winter',
      'Imran Abdool',
      'COMMERCE 4FG3 Course Outline Winter 2023',
      '4FG3 - Winter 2023 - I. Abdool.pdf',
      121021::BIGINT,
      'c250bde93ec3e92b9a6785d5305ea281725fec7236bb303d32ebcb8040b36e62'
    ),
  (
      'COMMERCE 4FH3',
      2026::SMALLINT,
      'winter',
      'Sudipto Sarkar',
      'COMMERCE 4FH3 Course Outline Winter 2026',
      '4FH3 - Winter 2026 - S. Sarkar.pdf',
      734328::BIGINT,
      '3de41ffd32d837e222851020c0ef226d93ce67427a0c3265cb6b8006555305dc'
    ),
  (
      'COMMERCE 4FK3',
      2025::SMALLINT,
      'winter',
      'Alicia Damley',
      'COMMERCE 4FK3 Course Outline Winter 2025',
      '4FK3 - Winter 2025 - A. Damley.pdf',
      165079::BIGINT,
      'd7d7052a73bba1409ad7f6c85bd8c48b9e11960cd41ac361dbf5ada4dd647e1c'
    ),
  (
      'COMMERCE 4FL3',
      2026::SMALLINT,
      'winter',
      'Sumit Bose',
      'COMMERCE 4FL3 Course Outline Winter 2026',
      '4FL3 - Winter 2026 - S. Bose.pdf',
      357037::BIGINT,
      'e0638b0f1c24646b8ac9c29ca47c981eb8df94d0feba09fce319c743f5def891'
    ),
  (
      'COMMERCE 4FM3',
      2026::SMALLINT,
      'winter',
      'Sumit Bose',
      'COMMERCE 4FM3 Course Outline Winter 2026',
      '4FM3 - Winter 2026 - S. Bose.pdf',
      351300::BIGINT,
      '482344de1e70fa598628d54981f7a43b566e787ba38908ff6981e7ec935535ad'
    ),
  (
      'COMMERCE 4FN3',
      2025::SMALLINT,
      'fall',
      'Alicia Damley',
      'COMMERCE 4FN3 Course Outline Fall 2025',
      '4FN3 - Fall 2025 - Damley.pdf',
      141134::BIGINT,
      '3500d54edbabcc483852f682590a69fde096b502156546ae98faabddcda38f84'
    ),
  (
      'COMMERCE 4FO3',
      2023::SMALLINT,
      'fall',
      'Waquar Ahmad',
      'COMMERCE 4FO3 Course Outline Fall 2023',
      '4FO3 - Fall 2023 - W. Ahmad.pdf',
      336881::BIGINT,
      '90da5e0ef208b810ccc5ca368f189da331dda2857bef666dbd207c17c4759a10'
    ),
  (
      'COMMERCE 4FP3',
      2025::SMALLINT,
      'fall',
      'C. Sherman Cheung',
      'COMMERCE 4FP3 Course Outline Fall 2025',
      '4FP3 - Fall 2025 - S. Cheung.pdf',
      328220::BIGINT,
      '0cd1218e3f2098346ba69237e82f48ff46114384fc897ef9375a8811919b4c26'
    ),
  (
      'COMMERCE 4FQ3',
      2023::SMALLINT,
      'winter',
      'Sudipto Sarkar',
      'COMMERCE 4FQ3 Course Outline Winter 2023',
      '4FQ3 - Winter 2023 - S. Sarkar.pdf',
      569592::BIGINT,
      'bf05cd51a78f27efd59952a61528a2d119dbae140c077048cd9fa8a58880fdb7'
    ),
  (
      'COMMERCE 4FR3',
      2024::SMALLINT,
      'fall',
      'Sumit Bose',
      'COMMERCE 4FR3 Course Outline Fall 2024',
      '4FR3 - Fall 2024 - S. Bose.pdf',
      298760::BIGINT,
      '8992a07125534b86aacc54301a4ebc3ca1f302878746e464418ec538113f6209'
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
