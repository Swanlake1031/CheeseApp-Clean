BEGIN;

SELECT plan(31);

CREATE TEMP TABLE expected_commerce_batch_1 (
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

INSERT INTO expected_commerce_batch_1
VALUES
  (
    'b0e2be60-1422-570c-9dce-0661be388bad',
    'COMMERCE 1AA3',
    'Introductory Financial Accounting',
    1,
    2,
    2026,
    'winter',
    332998,
    'd0bdee659ebc787f9230a5661153e4a122dee1e01cde642a7f3b02da7f11c4f0'
  ),
  (
    '38ac51d0-ac42-550d-bceb-bfa2b1e05c39',
    'COMMERCE 1BA3',
    'Organizational Behaviour',
    1,
    1,
    2026,
    'winter',
    443777,
    'a3ca6195f738bc8c4f158a75db09fff690b005fa924bec43a5ed24faee4ffbd4'
  ),
  (
    '13099e3a-db0e-52c8-b778-4cfea1fdce20',
    'COMMERCE 1DA3',
    'Business Data Analytics',
    1,
    4,
    2026,
    'winter',
    408446,
    'e86caadb8bd21138b23cef64809cc9f10c974b27fa995c0811e7519b1d23a5cb'
  ),
  (
    '42e876fb-8885-5914-8b4b-7f9e936917d2',
    'COMMERCE 1MA3',
    'Introduction to Marketing',
    1,
    2,
    2026,
    'winter',
    534720,
    'f8384b68f9c4b8d758d5503583dfdbe9dc687ee664722cec282ffe76b20598ec'
  ),
  (
    '618fffbd-d770-5110-a4e3-294a1cc9d2a1',
    'COMMERCE 2AB3',
    'Managerial Accounting I',
    2,
    2,
    2025,
    'fall',
    399088,
    '5234b160d060fcb79bf9ae43cb801387839411f3f92cae81d0a9e1229136ae4d'
  ),
  (
    '0d5cef2f-3d51-5a32-b405-43b7135f8860',
    'COMMERCE 2BC3',
    'Human Resource Management and Labour Relations',
    2,
    2,
    2026,
    'winter',
    427637,
    '27d5c0b63d0d4b2aef038c7bcc19f028b404aa65f2f536a83a3632d7f3b0009e'
  ),
  (
    'b0fe8194-75bf-5841-b826-25322c249e1a',
    'COMMERCE 2FA3',
    'Introduction to Finance',
    2,
    1,
    2026,
    'winter',
    341494,
    '77ec195ad7ba454ce9557dd9b31d1249919fe2ec4982f81f13b0dd43addff2d3'
  ),
  (
    '1739b38b-d2c8-5bc3-a39a-bea54633ab78',
    'COMMERCE 2KA3',
    'Information Systems in Management',
    2,
    2,
    2026,
    'winter',
    327165,
    '34037949303b75d1c41a13c155cfe71a8fe9438b13396a178d59915d71f45d3c'
  );

GRANT SELECT ON expected_commerce_batch_1 TO authenticated;

CREATE TEMP TABLE selected_commerce_review_term AS
SELECT id
FROM public.academic_terms
WHERE academic_year = 2026
  AND term = 'winter';

GRANT SELECT ON selected_commerce_review_term TO authenticated;

SELECT is(
  (SELECT count(*) FROM expected_commerce_batch_1),
  8::BIGINT,
  'batch 1 is intentionally limited to eight Commerce courses'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_commerce_batch_1 AS expected
    JOIN public.courses AS course
      ON course.id = expected.id
      AND course.code = expected.code
      AND course.title = expected.title
      AND course.subject = 'COMMERCE'
      AND course.year_level = expected.year_level
  ),
  8::BIGINT,
  'all Commerce courses use their normalized catalog identity and title'
);

SELECT is(
  (
    SELECT count(DISTINCT course.code)
    FROM public.courses AS course
    WHERE course.code IN (SELECT code FROM expected_commerce_batch_1)
  ),
  8::BIGINT,
  'the import does not create duplicate course codes'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.courses AS course
    WHERE course.code IN (SELECT code FROM expected_commerce_batch_1)
      AND course.code = upper(btrim(course.code))
      AND course.subject = 'COMMERCE'
  ),
  8::BIGINT,
  'course codes and faculty subject are normalized'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_professors AS mapping
    JOIN expected_commerce_batch_1 AS expected
      ON expected.id = mapping.course_id
  ),
  16::BIGINT,
  'all sixteen verified course-professor mappings are present after reconciliation'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_commerce_batch_1 AS expected
    WHERE expected.professor_count = (
      SELECT count(*)
      FROM public.course_professors AS mapping
      WHERE mapping.course_id = expected.id
    )
  ),
  8::BIGINT,
  'each course exposes every instructor verified for its selected academic term'
);

SELECT is(
  (
    SELECT count(*)
    FROM expected_commerce_batch_1 AS expected
    JOIN public.course_outlines AS outline
      ON outline.course_id = expected.id
      AND outline.academic_year = expected.outline_year
      AND outline.term = expected.outline_term
      AND outline.file_size_bytes = expected.outline_size
      AND outline.sha256 = expected.outline_sha256
      AND outline.mime_type = 'application/pdf'
      AND outline.storage_path =
        expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
        expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
  ),
  8::BIGINT,
  'every selected PDF has exact hash-bound private Storage metadata'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_commerce_batch_1 AS expected
      ON expected.id = outline.course_id
  ),
  8::BIGINT,
  'the batch registers one outline per course without duplicates'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_commerce_batch_1 AS expected
      ON expected.id = outline.course_id
    WHERE outline.academic_year = 2026
      AND outline.term = 'winter'
  ),
  7::BIGINT,
  'seven courses use the preferred Winter 2026 outline'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    JOIN expected_commerce_batch_1 AS expected
      ON expected.id = outline.course_id
    WHERE outline.academic_year = 2025
      AND outline.term = 'fall'
      AND expected.code = 'COMMERCE 2AB3'
  ),
  1::BIGINT,
  'COMMERCE 2AB3 uses its closest available Fall 2025 outline'
);

SELECT ok(
  (
    SELECT bool_and(outline.file_size_bytes < 1048576)
    FROM public.course_outlines AS outline
    JOIN expected_commerce_batch_1 AS expected
      ON expected.id = outline.course_id
  ),
  'the small source PDFs do not need lossy or redundant recompression'
);

SELECT is(
  (SELECT public FROM storage.buckets WHERE id = 'course-outlines'),
  FALSE,
  'Commerce outlines remain in the shared private course bucket'
);

SELECT is(
  (
    SELECT count(*)
    FROM storage.objects AS object
    JOIN expected_commerce_batch_1 AS expected
      ON object.bucket_id = 'course-outlines'
      AND object.name =
        expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
        expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
  ),
  8::BIGINT,
  'all eight immutable PDF objects were seeded into local Storage'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_course_catalog()',
    'EXECUTE'
  )
  AND has_function_privilege(
    'authenticated',
    'public.get_course_review_snapshot(uuid)',
    'EXECUTE'
  )
  AND has_function_privilege(
    'authenticated',
    'public.upsert_course_review(uuid,uuid,smallint,smallint,smallint,smallint,smallint,text,uuid)',
    'EXECUTE'
  )
  AND has_function_privilege(
    'authenticated',
    'public.delete_course_review(uuid)',
    'EXECUTE'
  ),
  'authenticated Commerce users reuse the existing catalog and review RPCs'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.course_reviews', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.course_reviews', 'DELETE'),
  'clients cannot bypass owner-scoped review mutation RPCs'
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
    WHERE code IN (SELECT code FROM expected_commerce_batch_1)
  ),
  8::BIGINT,
  'authenticated course discovery returns every Commerce batch course'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.get_course_catalog() AS catalog
    JOIN expected_commerce_batch_1 AS expected ON expected.id = catalog.id
    WHERE jsonb_array_length(catalog.professors) = expected.professor_count
  ),
  8::BIGINT,
  'course discovery exposes the correct professor filter options'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.course_outlines AS outline
    WHERE outline.course_id IN (SELECT id FROM expected_commerce_batch_1)
  ),
  8::BIGINT,
  'authenticated users can discover all Commerce outline metadata'
);

SELECT is(
  (
    SELECT count(*)
    FROM storage.objects AS object
    WHERE object.bucket_id = 'course-outlines'
      AND object.name IN (
        SELECT
          expected.id::TEXT || '/' || expected.outline_year::TEXT || '/' ||
          expected.outline_term || '/' || expected.outline_sha256 || '.pdf'
        FROM expected_commerce_batch_1 AS expected
      )
  ),
  8::BIGINT,
  'authenticated users can read registered Commerce Storage objects'
);

SELECT is(
  jsonb_array_length(
    public.get_course_review_snapshot(
      '13099e3a-db0e-52c8-b778-4cfea1fdce20'
    )->'professors'
  ),
  4,
  'the review editor loads all four COMMERCE 1DA3 professors'
);

SELECT ok(
  public.upsert_course_review(
    '13099e3a-db0e-52c8-b778-4cfea1fdce20',
    'e200a9c7-fd79-5440-a966-c4da8025c726',
    4::SMALLINT,
    5::SMALLINT,
    4::SMALLINT,
    3::SMALLINT,
    5::SMALLINT,
    'Clear Commerce review.',
    (SELECT id FROM selected_commerce_review_term)
  ) IS NOT NULL,
  'a valid user can submit every rating dimension and written review'
);

SELECT ok(
  (
    SELECT count(*) = 1
    FROM jsonb_array_elements(
      public.get_course_review_snapshot(
        '13099e3a-db0e-52c8-b778-4cfea1fdce20'
      )->'reviews'
    ) AS review
    WHERE (review->>'overall_rating')::INTEGER = 4
      AND (review->>'fun_rating')::INTEGER = 5
      AND (review->>'useful_rating')::INTEGER = 4
      AND (review->>'easy_a_rating')::INTEGER = 3
      AND (review->>'professor_rating')::INTEGER = 5
      AND review->>'review_text' = 'Clear Commerce review.'
      AND (review->>'is_mine')::BOOLEAN
  ),
  'the shared review table stores all Commerce dimensions and comment text'
);

SELECT ok(
  public.upsert_course_review(
    '13099e3a-db0e-52c8-b778-4cfea1fdce20',
    '6c70d705-1df0-5a4b-999d-8cd86b4dc83f',
    5::SMALLINT,
    4::SMALLINT,
    5::SMALLINT,
    4::SMALLINT,
    4::SMALLINT,
    'Updated Commerce review.',
    (SELECT id FROM selected_commerce_review_term)
  ) IS NOT NULL,
  'the owner can edit the review and professor selection through the same RPC'
);

SELECT is(
  (
    SELECT count(*)
    FROM jsonb_array_elements(
      public.get_course_review_snapshot(
        '13099e3a-db0e-52c8-b778-4cfea1fdce20'
      )->'reviews'
    ) AS review
    WHERE review->>'review_text' = 'Updated Commerce review.'
      AND review->>'professor_id' = '6c70d705-1df0-5a4b-999d-8cd86b4dc83f'
      AND (review->>'is_mine')::BOOLEAN
  ),
  1::BIGINT,
  'editing is idempotent and does not duplicate the user review'
);

SELECT is(
  jsonb_array_length(
    public.get_course_review_snapshot(
      '13099e3a-db0e-52c8-b778-4cfea1fdce20'
    )->'reviews'
  ),
  1,
  'a newly submitted review appears on refresh without restarting the app'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*)
    FROM jsonb_array_elements(
      public.get_course_review_snapshot(
        '13099e3a-db0e-52c8-b778-4cfea1fdce20'
      )->'reviews'
    ) AS review
    WHERE review->>'review_text' = 'Updated Commerce review.'
      AND (review->>'is_mine')::BOOLEAN = FALSE
  ),
  1::BIGINT,
  'another user can view the Commerce review without becoming its owner'
);

SELECT is(
  public.delete_course_review('13099e3a-db0e-52c8-b778-4cfea1fdce20'),
  FALSE,
  'another user cannot delete the owner review through the scoped RPC'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.delete_course_review('13099e3a-db0e-52c8-b778-4cfea1fdce20'),
  TRUE,
  'the owner can delete their Commerce review'
);

SELECT is(
  jsonb_array_length(
    public.get_course_review_snapshot(
      '13099e3a-db0e-52c8-b778-4cfea1fdce20'
    )->'reviews'
  ),
  0,
  'the deleted review disappears from the refreshed snapshot'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config('request.jwt.claim.role', 'anon', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
SET LOCAL ROLE anon;

SELECT ok(
  NOT has_function_privilege('anon', 'public.get_course_catalog()', 'EXECUTE')
  AND NOT has_function_privilege(
    'anon',
    'public.get_course_review_snapshot(uuid)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.upsert_course_review(uuid,uuid,smallint,smallint,smallint,smallint,smallint,text,uuid)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.delete_course_review(uuid)',
    'EXECUTE'
  ),
  'anonymous users cannot access Commerce catalog or review mutation RPCs'
);

SELECT is(
  (
    SELECT count(*)
    FROM storage.objects
    WHERE bucket_id = 'course-outlines'
  ),
  0::BIGINT,
  'anonymous users cannot read private Commerce outline objects'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
