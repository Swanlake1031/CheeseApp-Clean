BEGIN;

SELECT plan(6);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.professors'::REGCLASS
      AND contype = 'u'
      AND conname = 'professors_name_key'
  ),
  'professor display names are no longer globally unique'
);

SELECT is(
  (
    SELECT index_definition.indisunique
    FROM pg_index AS index_definition
    JOIN pg_class AS index_relation
      ON index_relation.oid = index_definition.indexrelid
    JOIN pg_namespace AS index_namespace
      ON index_namespace.oid = index_relation.relnamespace
    WHERE index_namespace.nspname = 'public'
      AND index_relation.relname = 'professors_name_id_idx'
  ),
  FALSE,
  'the replacement professor-name index is non-unique'
);

INSERT INTO public.professors (id, name)
VALUES
  (
    '10300000-0000-4000-8000-000000000001'::UUID,
    'Duplicate Name Test'
  ),
  (
    '10300000-0000-4000-8000-000000000002'::UUID,
    'Duplicate Name Test'
  );

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.professors
    WHERE name = 'Duplicate Name Test'
  ),
  2::BIGINT,
  'two distinct professor identities can share the same display name'
);

INSERT INTO public.course_professors (course_id, professor_id)
VALUES
  (
    'ec011b03-0000-4000-8000-000000000001'::UUID,
    '10300000-0000-4000-8000-000000000001'::UUID
  ),
  (
    'ec011b03-0000-4000-8000-000000000001'::UUID,
    '10300000-0000-4000-8000-000000000002'::UUID
  );

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.course_professors
    WHERE course_id = 'ec011b03-0000-4000-8000-000000000001'::UUID
      AND professor_id IN (
        '10300000-0000-4000-8000-000000000001'::UUID,
        '10300000-0000-4000-8000-000000000002'::UUID
      )
  ),
  2::BIGINT,
  'one course can reference two same-named professor identities'
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
    SELECT COUNT(*)
    FROM public.get_course_catalog() AS catalog
    CROSS JOIN LATERAL jsonb_array_elements(catalog.professors) AS professor
    WHERE catalog.id = 'ec011b03-0000-4000-8000-000000000001'::UUID
      AND professor->>'name' = 'Duplicate Name Test'
  ),
  2::BIGINT,
  'course catalog returns both same-named professors'
);

SELECT is(
  (
    SELECT COUNT(DISTINCT professor->>'id')
    FROM jsonb_array_elements(
      public.get_course_review_snapshot(
        'ec011b03-0000-4000-8000-000000000001'::UUID
      )->'professors'
    ) AS professor
    WHERE professor->>'name' = 'Duplicate Name Test'
  ),
  2::BIGINT,
  'review snapshot preserves both professor UUID identities'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
