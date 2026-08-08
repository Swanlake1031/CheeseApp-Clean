BEGIN;

SELECT plan(2);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT id
    FROM public.search_profiles(
      '00000000-0000-0000-0000-000000000001',
      20
    )
    LIMIT 1
  ),
  '00000000-0000-0000-0000-000000000001'::UUID,
  'a complete database UID finds the matching visible profile'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_profiles(
      'ffffffff-ffff-4fff-8fff-ffffffffffff',
      20
    )
  ),
  0::BIGINT,
  'an unknown UID does not match unrelated profiles'
);

SELECT * FROM finish();
ROLLBACK;
