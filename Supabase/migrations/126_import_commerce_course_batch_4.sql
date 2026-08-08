-- Import verified Commerce catalog batch 4.
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
  ('b65d7329-c360-546a-8be7-73b306bbaac4', 'COMMERCE 4FS3', 'Pension, Retirement and Estate Planning', 'COMMERCE', 4, FALSE),
  ('5a12c7a4-dcb1-539d-a403-b2525352f7de', 'COMMERCE 4FT3', 'Real Estate Finance and Investment', 'COMMERCE', 4, FALSE),
  ('0cbe9680-9176-56ae-b850-c50dbfb9f114', 'COMMERCE 4FU3', 'Behavioural Finance: The Psychology of Markets', 'COMMERCE', 4, FALSE),
  ('a0322229-2e76-5370-91af-bbbd5b5839e3', 'COMMERCE 4FV3', 'Venture Capital', 'COMMERCE', 4, FALSE),
  ('eb50b1b1-8939-5721-8fdc-54e2170d25b1', 'COMMERCE 4FW3', 'Finance for Entrepreneurs', 'COMMERCE', 4, FALSE),
  ('67308986-55fe-506e-aff5-897ea4fd48b4', 'COMMERCE 4FX3', 'Special Topics in Finance', 'COMMERCE', 4, FALSE),
  ('ac739e15-6341-5f3a-8117-775f0760009c', 'COMMERCE 4KF3', 'Project Management', 'COMMERCE', 4, FALSE),
  ('76296225-46d1-585f-986b-15427f0d138e', 'COMMERCE 4KG3', 'Data Mining For Business Analytics', 'COMMERCE', 4, FALSE),
  ('71e1a40d-c1f8-5742-8d2e-f5d85f728742', 'COMMERCE 4KH3', 'Strategies for Electronic and Mobile Business', 'COMMERCE', 4, FALSE),
  ('4d4eb5d4-f1ff-5b38-ba3c-0a4ad6a3b7a2', 'COMMERCE 4KI3', 'Business Process Management', 'COMMERCE', 4, FALSE),
  ('b928488e-5e8b-5d67-97d8-13f8b2d5b74e', 'COMMERCE 4MA3', 'Advertising and Integrated Marketing Communication', 'COMMERCE', 4, FALSE),
  ('8740b613-f4cd-56d3-bfba-bb83f49071fa', 'COMMERCE 4MC3', 'New Product Marketing', 'COMMERCE', 4, FALSE),
  ('03b0f744-76ad-5cc1-95d1-7c4e292f80bc', 'COMMERCE 4ME3', 'Sales Management', 'COMMERCE', 4, FALSE),
  ('3219121a-1456-5fc6-ba35-c855a5cc8a51', 'COMMERCE 4MF3', 'Retailing Management', 'COMMERCE', 4, FALSE),
  ('94bc1832-6f7c-577d-93ea-d9301d73d50c', 'COMMERCE 4MG3', 'Strategic Philanthropy and Leadership', 'COMMERCE', 4, FALSE),
  ('43769a50-cbcd-5da5-b72a-b33acb9e8887', 'COMMERCE 4OB3', 'Analysis of Production/Operations Problems', 'COMMERCE', 4, FALSE),
  ('54946a52-aacc-50d1-998a-32f11942dbe2', 'COMMERCE 4OD3', 'Purchasing and Supply Management', 'COMMERCE', 4, FALSE),
  ('f2260789-a24c-5177-b026-7f8590d0cc0a', 'COMMERCE 4OI3', 'Supply Chain Management', 'COMMERCE', 4, FALSE),
  ('2ef8d5a5-1fe6-5802-aa7f-a521d707f1f4', 'COMMERCE 4PA3', 'Business Policy: Strategic Management', 'COMMERCE', 4, FALSE),
  ('0265eff8-7126-594f-bea3-42e8e5689e9c', 'COMMERCE 4QA3', 'Operations Modelling and Analysis', 'COMMERCE', 4, FALSE),
  ('503a128f-6bff-59f2-9aac-1d6b13ed23f1', 'COMMERCE 4SA3', 'International Business', 'COMMERCE', 4, FALSE),
  ('c4b44871-8f3c-5c72-ac10-6795439a6cd3', 'COMMERCE 4SB3', 'Introduction to Canadian Taxation', 'COMMERCE', 4, FALSE),
  ('c682ae9d-c8d7-5649-97f7-e3d8caa82bab', 'COMMERCE 4SC3', 'Advanced Canadian Taxation', 'COMMERCE', 4, FALSE),
  ('92b3fe12-f0dd-5736-ab81-d66083a35aa3', 'COMMERCE 4SD3', 'Commercial Law', 'COMMERCE', 4, FALSE),
  ('3336076d-1b96-5753-9beb-7154d9919b32', 'COMMERCE 4SE3', 'Entrepreneurship', 'COMMERCE', 4, FALSE),
  ('93f7c483-3783-5071-a71b-72c2af8b4066', 'COMMERCE 4SG3', 'Sustainability: Corporations and Society', 'COMMERCE', 4, FALSE),
  ('26521ca5-5346-58e4-9ba9-17fc4e3340f6', 'COMMERCE 4SH3', 'Case Analysis and Presentation Skills', 'COMMERCE', 4, FALSE),
  ('ca453e0a-a694-5dd3-ac70-2e2aecfcdd48', 'COMMERCE 4SM3', 'Sports Management', 'COMMERCE', 4, FALSE),
  ('0cc3d097-72b3-54e9-a5c4-e611e3a046c7', 'COMMERCE 4SX3', 'Special Topics in Strategic Management: White Collar Crime', 'COMMERCE', 4, FALSE)
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
      ('COMMERCE 4FS3', 'b65d7329-c360-546a-8be7-73b306bbaac4'::UUID),
      ('COMMERCE 4FT3', '5a12c7a4-dcb1-539d-a403-b2525352f7de'::UUID),
      ('COMMERCE 4FU3', '0cbe9680-9176-56ae-b850-c50dbfb9f114'::UUID),
      ('COMMERCE 4FV3', 'a0322229-2e76-5370-91af-bbbd5b5839e3'::UUID),
      ('COMMERCE 4FW3', 'eb50b1b1-8939-5721-8fdc-54e2170d25b1'::UUID),
      ('COMMERCE 4FX3', '67308986-55fe-506e-aff5-897ea4fd48b4'::UUID),
      ('COMMERCE 4KF3', 'ac739e15-6341-5f3a-8117-775f0760009c'::UUID),
      ('COMMERCE 4KG3', '76296225-46d1-585f-986b-15427f0d138e'::UUID),
      ('COMMERCE 4KH3', '71e1a40d-c1f8-5742-8d2e-f5d85f728742'::UUID),
      ('COMMERCE 4KI3', '4d4eb5d4-f1ff-5b38-ba3c-0a4ad6a3b7a2'::UUID),
      ('COMMERCE 4MA3', 'b928488e-5e8b-5d67-97d8-13f8b2d5b74e'::UUID),
      ('COMMERCE 4MC3', '8740b613-f4cd-56d3-bfba-bb83f49071fa'::UUID),
      ('COMMERCE 4ME3', '03b0f744-76ad-5cc1-95d1-7c4e292f80bc'::UUID),
      ('COMMERCE 4MF3', '3219121a-1456-5fc6-ba35-c855a5cc8a51'::UUID),
      ('COMMERCE 4MG3', '94bc1832-6f7c-577d-93ea-d9301d73d50c'::UUID),
      ('COMMERCE 4OB3', '43769a50-cbcd-5da5-b72a-b33acb9e8887'::UUID),
      ('COMMERCE 4OD3', '54946a52-aacc-50d1-998a-32f11942dbe2'::UUID),
      ('COMMERCE 4OI3', 'f2260789-a24c-5177-b026-7f8590d0cc0a'::UUID),
      ('COMMERCE 4PA3', '2ef8d5a5-1fe6-5802-aa7f-a521d707f1f4'::UUID),
      ('COMMERCE 4QA3', '0265eff8-7126-594f-bea3-42e8e5689e9c'::UUID),
      ('COMMERCE 4SA3', '503a128f-6bff-59f2-9aac-1d6b13ed23f1'::UUID),
      ('COMMERCE 4SB3', 'c4b44871-8f3c-5c72-ac10-6795439a6cd3'::UUID),
      ('COMMERCE 4SC3', 'c682ae9d-c8d7-5649-97f7-e3d8caa82bab'::UUID),
      ('COMMERCE 4SD3', '92b3fe12-f0dd-5736-ab81-d66083a35aa3'::UUID),
      ('COMMERCE 4SE3', '3336076d-1b96-5753-9beb-7154d9919b32'::UUID),
      ('COMMERCE 4SG3', '93f7c483-3783-5071-a71b-72c2af8b4066'::UUID),
      ('COMMERCE 4SH3', '26521ca5-5346-58e4-9ba9-17fc4e3340f6'::UUID),
      ('COMMERCE 4SM3', 'ca453e0a-a694-5dd3-ac70-2e2aecfcdd48'::UUID),
      ('COMMERCE 4SX3', '0cc3d097-72b3-54e9-a5c4-e611e3a046c7'::UUID)
    ) AS expected(code, id)
    JOIN public.courses AS course ON course.code = expected.code
    WHERE course.id <> expected.id
  ) THEN
    RAISE EXCEPTION
      'Commerce batch 4 course IDs conflict with checked-in Storage paths';
  END IF;
END;
$$;

INSERT INTO public.professors (id, name)
VALUES
  ('358c640d-b903-56fe-900f-8ca894733a28', 'Adeel Mahmood'),
  ('aba2f7ad-ec3d-51e5-8bb5-5fa137b6fe5d', 'Ahmed Foda'),
  ('748dcac3-9183-58ca-95b5-8d0676e40891', 'Ahzam Ali'),
  ('e628d60b-20f0-5a50-bf66-062efb02f78e', 'Ali Reza Montazemi'),
  ('fc0f93f2-7c50-5b8b-9b28-72e0bab2d0ee', 'Amir Taherizadeh'),
  ('99d1523f-abc3-5933-821b-cbe0e6eb18fb', 'Carolyn Capretta'),
  ('92ad2ab1-8e04-5bc7-a00c-7c388641df5e', 'Christina DeVries'),
  ('ff022314-1084-5883-954a-3afdccc1d3cc', 'Dom Sorbara'),
  ('91956689-2977-5123-b6bf-141c54fc6893', 'Eric Bentzen-Bilkvist'),
  ('37530873-0e8a-5e99-9cf5-fc1f1445784a', 'François Neville'),
  ('b94858f9-7c04-5c95-95e1-a39dc3b1e7c6', 'Grace Huang'),
  ('d5c0f03c-0da3-5246-9ed0-3b99573bb902', 'Jukyeong (Judy) Han'),
  ('7faa98cb-682f-51f7-9ebc-6da9d11a1a16', 'Kai Christine Lesage'),
  ('9d045c55-14f7-5fed-8536-78ebadfd2545', 'Kai Huang'),
  ('86c371ea-ba48-5bc4-9b8c-6d821d7e9f43', 'Kate Siklosi'),
  ('a2152349-99b3-5a36-a26e-90dc866c6411', 'Keiwan Wind'),
  ('a755299d-1b30-51be-9a5c-8226d8176dfc', 'Konstantine Ketsetzis'),
  ('4f064076-e068-50dc-996e-d2aebe1362c1', 'Leonard Waverman'),
  ('8c3e6fdc-138b-51a2-a8e7-cdd4bc762712', 'Lynn Fergusson'),
  ('c145aaf0-6515-5fd3-9225-208b935f0c34', 'Mandeep Malik'),
  ('4032d83f-4b69-5aed-92a1-49fd4b8c3caa', 'Marvin Ryder'),
  ('ad9182dd-7212-5f30-ae49-9885b8ee76a5', 'Nicole Wagner'),
  ('8db9316f-f676-5c90-81fe-5c46df66752c', 'Pavithra Balaji'),
  ('611a2ec0-d222-506a-a6f9-540d5abd9290', 'Prakash Abad'),
  ('7e634242-2ad9-50b2-8f4a-e7c14f25c8af', 'Rita Cossa'),
  ('0c028948-9669-527e-83ca-3cff25974555', 'Sumit Bose'),
  ('a290bc89-0cb9-5e56-8ad8-966ccea97c30', 'Trevor Chamberlain'),
  ('835fef0f-3b46-5845-800b-3d79de55280d', 'Vijay Kumar')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT course.id, mapping.professor_id
FROM (VALUES
  ('COMMERCE 4FS3', '0c028948-9669-527e-83ca-3cff25974555'::UUID),
  ('COMMERCE 4FT3', '358c640d-b903-56fe-900f-8ca894733a28'::UUID),
  ('COMMERCE 4FU3', '0c028948-9669-527e-83ca-3cff25974555'::UUID),
  ('COMMERCE 4FV3', '358c640d-b903-56fe-900f-8ca894733a28'::UUID),
  ('COMMERCE 4FW3', 'a290bc89-0cb9-5e56-8ad8-966ccea97c30'::UUID),
  ('COMMERCE 4FX3', '4f064076-e068-50dc-996e-d2aebe1362c1'::UUID),
  ('COMMERCE 4KF3', 'ad9182dd-7212-5f30-ae49-9885b8ee76a5'::UUID),
  ('COMMERCE 4KG3', 'a2152349-99b3-5a36-a26e-90dc866c6411'::UUID),
  ('COMMERCE 4KH3', 'e628d60b-20f0-5a50-bf66-062efb02f78e'::UUID),
  ('COMMERCE 4KI3', 'e628d60b-20f0-5a50-bf66-062efb02f78e'::UUID),
  ('COMMERCE 4MA3', '92ad2ab1-8e04-5bc7-a00c-7c388641df5e'::UUID),
  ('COMMERCE 4MC3', '7faa98cb-682f-51f7-9ebc-6da9d11a1a16'::UUID),
  ('COMMERCE 4ME3', 'c145aaf0-6515-5fd3-9225-208b935f0c34'::UUID),
  ('COMMERCE 4MF3', '835fef0f-3b46-5845-800b-3d79de55280d'::UUID),
  ('COMMERCE 4MG3', '8c3e6fdc-138b-51a2-a8e7-cdd4bc762712'::UUID),
  ('COMMERCE 4MG3', '86c371ea-ba48-5bc4-9b8c-6d821d7e9f43'::UUID),
  ('COMMERCE 4OB3', '611a2ec0-d222-506a-a6f9-540d5abd9290'::UUID),
  ('COMMERCE 4OD3', '9d045c55-14f7-5fed-8536-78ebadfd2545'::UUID),
  ('COMMERCE 4OI3', '9d045c55-14f7-5fed-8536-78ebadfd2545'::UUID),
  ('COMMERCE 4PA3', '7e634242-2ad9-50b2-8f4a-e7c14f25c8af'::UUID),
  ('COMMERCE 4PA3', 'b94858f9-7c04-5c95-95e1-a39dc3b1e7c6'::UUID),
  ('COMMERCE 4PA3', '748dcac3-9183-58ca-95b5-8d0676e40891'::UUID),
  ('COMMERCE 4QA3', 'aba2f7ad-ec3d-51e5-8bb5-5fa137b6fe5d'::UUID),
  ('COMMERCE 4SA3', '8db9316f-f676-5c90-81fe-5c46df66752c'::UUID),
  ('COMMERCE 4SA3', 'd5c0f03c-0da3-5246-9ed0-3b99573bb902'::UUID),
  ('COMMERCE 4SA3', 'fc0f93f2-7c50-5b8b-9b28-72e0bab2d0ee'::UUID),
  ('COMMERCE 4SB3', '91956689-2977-5123-b6bf-141c54fc6893'::UUID),
  ('COMMERCE 4SC3', '91956689-2977-5123-b6bf-141c54fc6893'::UUID),
  ('COMMERCE 4SD3', 'a755299d-1b30-51be-9a5c-8226d8176dfc'::UUID),
  ('COMMERCE 4SE3', '4032d83f-4b69-5aed-92a1-49fd4b8c3caa'::UUID),
  ('COMMERCE 4SG3', '99d1523f-abc3-5933-821b-cbe0e6eb18fb'::UUID),
  ('COMMERCE 4SH3', '37530873-0e8a-5e99-9cf5-fc1f1445784a'::UUID),
  ('COMMERCE 4SM3', 'b94858f9-7c04-5c95-95e1-a39dc3b1e7c6'::UUID),
  ('COMMERCE 4SX3', 'ff022314-1084-5883-954a-3afdccc1d3cc'::UUID)
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
      'COMMERCE 4FS3',
      2025::SMALLINT,
      'winter',
      'Sumit Bose',
      'COMMERCE 4FS3 Course Outline Winter 2025',
      '4FS3 - Winter 2025 - C01 - S. Bose.pdf',
      282717::BIGINT,
      'f75edd3c003468c502df63bac4be66a9f91bb88ada00a6a38a5653ad5697b7be'
    ),
  (
      'COMMERCE 4FT3',
      2026::SMALLINT,
      'winter',
      'Adeel Mahmood',
      'COMMERCE 4FT3 Course Outline Winter 2026',
      '4FT3 - Winter 2026 - A. Mahmood.pdf',
      264566::BIGINT,
      '91b93135b027bc32b33f6a5418a107d1f4a2354cc28060dd1f32942f5c95fc32'
    ),
  (
      'COMMERCE 4FU3',
      2025::SMALLINT,
      'fall',
      'Sumit Bose',
      'COMMERCE 4FU3 Course Outline Fall 2025',
      '4FU3 - Fall 2025 - C01 - S. Bose.pdf',
      374467::BIGINT,
      '32cab9583cc391b2382e45c3d0c8cdac2965ae9ebb09b9bd0dff7ba8c4cc5ebb'
    ),
  (
      'COMMERCE 4FV3',
      2025::SMALLINT,
      'fall',
      'Adeel Mahmood',
      'COMMERCE 4FV3 Course Outline Fall 2025',
      '4FV3 - Fall 2025 - A. Mahmood.pdf',
      298233::BIGINT,
      '9e4b52ba5f5a1934ed6a5fd4f1adcc4cf132f987e7b73cfa2200c5594d35f536'
    ),
  (
      'COMMERCE 4FW3',
      2025::SMALLINT,
      'fall',
      'Trevor Chamberlain',
      'COMMERCE 4FW3 Course Outline Fall 2025',
      '4FW3 - Fall 2025 - T. Chamberlain.pdf',
      224967::BIGINT,
      'c1a6d88c72cbb05d973cd52a3ced42cb64bdf97e874c3a2ceabbdf6fa0cf08ce'
    ),
  (
      'COMMERCE 4FX3',
      2024::SMALLINT,
      'fall',
      'Leonard Waverman',
      'COMMERCE 4FX3 Course Outline Fall 2024',
      '4FX3 - Fall 2024 - L. Waverman.pdf',
      311862::BIGINT,
      'f8c6c079594f6cf6309456c1ff9d36e5db56b15f8ff25464324d65157acc5afd'
    ),
  (
      'COMMERCE 4KF3',
      2026::SMALLINT,
      'winter',
      'Nicole Wagner',
      'COMMERCE 4KF3 Course Outline Winter 2026',
      '4KF3 - Winter 2026 - C01, C02 - N.Wagner.pdf',
      327981::BIGINT,
      'f5dc41af7c0bdd8886ada9ee62a04f3aec2a81f969ed95344397def5926dc0ba'
    ),
  (
      'COMMERCE 4KG3',
      2025::SMALLINT,
      'winter',
      'Keiwan Wind',
      'COMMERCE 4KG3 Course Outline Winter 2025',
      '4KG3 - Winter 2025 - C01, C02, C03 - K. Wind.pdf',
      260406::BIGINT,
      '6a6a0dab074a63063bfd1b6e5e8ee8fd2ce2e7ff6f49ad96dffdb432d02944ff'
    ),
  (
      'COMMERCE 4KH3',
      2025::SMALLINT,
      'fall',
      'Ali Reza Montazemi',
      'COMMERCE 4KH3 Course Outline Fall 2025',
      '4KH3 - Fall 2025 - C01 - A. Montazemi.pdf',
      405150::BIGINT,
      'ce8287d7213e0105211cc7ca05fd8047734458e4b9cf4e85904f43db30c8b955'
    ),
  (
      'COMMERCE 4KI3',
      2024::SMALLINT,
      'fall',
      'Ali Reza Montazemi',
      'COMMERCE 4KI3 Course Outline Fall 2024',
      '4KI3 - Fall 2024 - C01 - A. Montazemi.pdf',
      146058::BIGINT,
      'ee370614bed709a60efaee42ad5a51e0678aafcf19d2a489b378e96bc71b4923'
    ),
  (
      'COMMERCE 4MA3',
      2026::SMALLINT,
      'winter',
      'Christina DeVries',
      'COMMERCE 4MA3 Course Outline Winter 2026',
      '4MA3 - Winter 2026 - C. DeVries.pdf',
      247480::BIGINT,
      '2424c5e3c1b59c355f1ee86107dd22ae328f8206dceccc94e22fdf57b42e123e'
    ),
  (
      'COMMERCE 4MC3',
      2026::SMALLINT,
      'winter',
      'Kai Christine Lesage',
      'COMMERCE 4MC3 Course Outline Winter 2026',
      '4MC3 - Winter 2026 - K. C. Lesage.pdf',
      469006::BIGINT,
      'b73c2a42a8cebe2863272ab7b689b6a975426d42fc3a17223437aa01eea7e5e4'
    ),
  (
      'COMMERCE 4ME3',
      2026::SMALLINT,
      'winter',
      'Mandeep Malik',
      'COMMERCE 4ME3 Course Outline Winter 2026',
      '4ME3 - Winter 2026 - M. Malik.pdf',
      414156::BIGINT,
      '2310d31d466316849ce52b632a69bde8e4533aab49b2e5d6aaf3d106e2ee8283'
    ),
  (
      'COMMERCE 4MF3',
      2024::SMALLINT,
      'fall',
      'Vijay Kumar',
      'COMMERCE 4MF3 Course Outline Fall 2024',
      '4MF3 - Fall 2024 - V. Kumar.pdf',
      263908::BIGINT,
      'a069d827292f03c6f36cbbe28417056abb4125e0a597c281781e8c0a074507b0'
    ),
  (
      'COMMERCE 4MG3',
      2021::SMALLINT,
      'fall',
      'Lynn Fergusson; Kate Siklosi',
      'COMMERCE 4MG3 Course Outline Fall 2021',
      '4MG3 - Fall 2021 - C01 - C. Siklosi, L. Fergusson.pdf',
      508265::BIGINT,
      'c267224f810b929c8282aaba450343d269ae946ee5bb3c27747fef3a9b9a4f9a'
    ),
  (
      'COMMERCE 4OB3',
      2024::SMALLINT,
      'fall',
      'Prakash Abad',
      'COMMERCE 4OB3 Course Outline Fall 2024',
      '4OB3 - Fall 2024 - C01 - P. Abad.pdf',
      262002::BIGINT,
      'ec2fa3e7d9a965e556d111f023dd3cb83c68ee7b86fddadf3d44bec1e02e80cd'
    ),
  (
      'COMMERCE 4OD3',
      2026::SMALLINT,
      'winter',
      'Kai Huang',
      'COMMERCE 4OD3 Course Outline Winter 2026',
      '4OD3 - Winter 2026 - C01 - K. Huang.pdf',
      652798::BIGINT,
      'f32a6e6cc751c1000deb08fdf663867e88327dc3437a875bfd770160a41dd778'
    ),
  (
      'COMMERCE 4OI3',
      2025::SMALLINT,
      'fall',
      'Kai Huang',
      'COMMERCE 4OI3 Course Outline Fall 2025',
      '4OI3 - Fall 2025 - C01 - K. Huang.pdf',
      1223766::BIGINT,
      '811b2654a5596c7a86d841295b9aca1166bde032d9a4c4435d7be9f21eeb27af'
    ),
  (
      'COMMERCE 4PA3',
      2026::SMALLINT,
      'winter',
      'Rita Cossa; Grace Huang; Ahzam Ali',
      'COMMERCE 4PA3 Course Outline Winter 2026',
      '4PA3 - Winter 2026 - R. Cossa, G. Huang, A. Ali.pdf',
      293460::BIGINT,
      '7e4635ab9443d187a00c9b6625aa049ae55161a213a8d9a8c354c7ff4300ef50'
    ),
  (
      'COMMERCE 4QA3',
      2026::SMALLINT,
      'winter',
      'Ahmed Foda',
      'COMMERCE 4QA3 Course Outline Winter 2026',
      '4QA3 - Winter 2026 - C01 - A. Foda.pdf',
      345197::BIGINT,
      '95cd43e30ca6cb6cf3868ea903b6c92a166995eb7f91a18e53ffd80b37e2229f'
    ),
  (
      'COMMERCE 4SA3',
      2026::SMALLINT,
      'winter',
      'Pavithra Balaji; Jukyeong (Judy) Han; Amir Taherizadeh',
      'COMMERCE 4SA3 Course Outline Winter 2026',
      '4SA3 - Winter 2026 - P. Balaji, J. Han, A. Taherizadeh.pdf',
      450631::BIGINT,
      'b6c450dd72fc95eb1a35341d6ed7b534f72dcf508ed218cf58bd7057744268dd'
    ),
  (
      'COMMERCE 4SB3',
      2025::SMALLINT,
      'fall',
      'Eric Bentzen-Bilkvist',
      'COMMERCE 4SB3 Course Outline Fall 2025',
      '4SB3 - Fall 2025 - E. Bentzen-Bilkvist.pdf',
      211893::BIGINT,
      'b70e7dcb7b4a0640d0591d7f834fc93d6b78fe10c50eb8f514e8792eded82d15'
    ),
  (
      'COMMERCE 4SC3',
      2026::SMALLINT,
      'winter',
      'Eric Bentzen-Bilkvist',
      'COMMERCE 4SC3 Course Outline Winter 2026',
      '4SC3 - Winter 2026 - E. Bentzen Bilkvist.pdf',
      397564::BIGINT,
      '3b6dd83ce85bc0b16c9763f630d08146459a5127715c3e1bdbc477d89932324d'
    ),
  (
      'COMMERCE 4SD3',
      2026::SMALLINT,
      'winter',
      'Konstantine Ketsetzis',
      'COMMERCE 4SD3 Course Outline Winter 2026',
      '4SD3 - Winter 2026 - K. Ketsetzis.pdf',
      508991::BIGINT,
      'cb45c0237868db5554f644f8cad327b9e38354187e3a1abbb0cb6f709f9b9790'
    ),
  (
      'COMMERCE 4SE3',
      2025::SMALLINT,
      'fall',
      'Marvin Ryder',
      'COMMERCE 4SE3 Course Outline Fall 2025',
      '4SE3 - Fall 2025 - M. Ryder.pdf',
      534720::BIGINT,
      '0e8aae2fce57a2d0a3908dc9481134be85ea0785b01b658837371540f4f50df6'
    ),
  (
      'COMMERCE 4SG3',
      2026::SMALLINT,
      'winter',
      'Carolyn Capretta',
      'COMMERCE 4SG3 Course Outline Winter 2026',
      '4SG3 - Winter 2026 - C. Capretta.pdf',
      346070::BIGINT,
      '06377f3c2e4c7e6d8421fb5fc811e20730cf63063169ac169fc4f1686eda273f'
    ),
  (
      'COMMERCE 4SH3',
      2019::SMALLINT,
      'fall',
      'François Neville',
      'COMMERCE 4SH3 Course Outline Fall 2019',
      '4SH3 - Fall 2019 - C01 - F. Neville.pdf',
      143403::BIGINT,
      '72fc07e8b3cee75a50582480d242d1a859a31f38e019bfb3a58c5812f808bb74'
    ),
  (
      'COMMERCE 4SM3',
      2026::SMALLINT,
      'winter',
      'Grace Huang',
      'COMMERCE 4SM3 Course Outline Winter 2026',
      '4SM3 - Winter 2026 - G. Huang.pdf',
      327981::BIGINT,
      '91457f913bbed6398ffad55d16bd9feb4beeeb2dac2b288b6125e9a2deac9025'
    ),
  (
      'COMMERCE 4SX3',
      2020::SMALLINT,
      'summer',
      'Dom Sorbara',
      'COMMERCE 4SX3 Course Outline Summer 2020',
      '4SX3 - Summer 2020 - C01 - D. Sorbara.pdf',
      265750::BIGINT,
      '4142c7056cd1643e654d018b31fdc5e3ea468a87ce6be629a07a2bea58556b5f'
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
