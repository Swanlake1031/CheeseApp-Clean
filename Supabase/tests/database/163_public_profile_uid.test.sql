BEGIN;

SELECT plan(9);

SELECT has_column(
  'public',
  'profiles',
  'public_uid',
  'profiles store a public user ID'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'public.profiles'::REGCLASS
      AND constraint_row.conname = 'profiles_public_uid_key'
      AND constraint_row.contype = 'u'
  ),
  'public user IDs have a database unique constraint'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.profiles'::REGCLASS
      AND trigger_row.tgname = 'profiles_assign_public_uid'
      AND NOT trigger_row.tgisinternal
  ),
  'new profiles receive a database-generated public user ID'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profiles profile
    WHERE profile.public_uid IS NULL
       OR profile.public_uid !~ '^[0-9]{8}$'
  ),
  0::BIGINT,
  'all existing profiles are backfilled with eight digits'
);

SELECT is(
  (SELECT COUNT(*) FROM public.profiles),
  (SELECT COUNT(DISTINCT profile.public_uid) FROM public.profiles profile),
  'backfilled public user IDs are unique'
);

CREATE TEMP TABLE public_uid_fixture AS
SELECT profile.id, profile.public_uid
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT result.id
    FROM public.search_profiles(
      (SELECT fixture.public_uid FROM public_uid_fixture fixture),
      20
    ) result
    LIMIT 1
  ),
  '00000000-0000-0000-0000-000000000001'::UUID,
  'an exact public user ID finds the visible profile'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_profiles('00000000', 20)
  ),
  0::BIGINT,
  'an unknown public user ID does not match other profiles'
);

RESET ROLE;

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
)
ON CONFLICT DO NOTHING;

SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_profiles(
      (SELECT fixture.public_uid FROM public_uid_fixture fixture),
      20
    )
  ),
  0::BIGINT,
  'public user ID lookup preserves profile block visibility'
);

RESET ROLE;

SELECT throws_like(
  $$UPDATE public.profiles
    SET public_uid = '12345678'
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID$$,
  '%cannot be changed%',
  'a public user ID is immutable after creation'
);

SELECT * FROM finish();
ROLLBACK;
