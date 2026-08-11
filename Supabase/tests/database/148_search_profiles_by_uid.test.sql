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
      (
        SELECT profile.public_uid
        FROM public.profiles profile
        WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID
      ),
      20
    )
    LIMIT 1
  ),
  '00000000-0000-0000-0000-000000000001'::UUID,
  'an eight-digit public UID finds the matching visible profile'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_profiles(
      '00000000',
      20
    )
  ),
  0::BIGINT,
  'an unknown public UID does not match unrelated profiles'
);

SELECT * FROM finish();
ROLLBACK;
