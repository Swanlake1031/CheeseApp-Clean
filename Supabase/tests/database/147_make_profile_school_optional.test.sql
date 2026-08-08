BEGIN;

SELECT plan(4);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$SELECT public.complete_profile(
    p_full_name => 'Optional School',
    p_university => NULL,
    p_gender => 'female',
    p_occupation => NULL
  )$$,
  'profile completion accepts an empty school'
);

SELECT is(
  (
    SELECT university
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  NULL::TEXT,
  'the public school value remains empty'
);

SELECT is(
  (
    SELECT profile_completed
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  TRUE,
  'an empty school does not block profile completion'
);

SELECT isnt(
  (
    SELECT school_id
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  NULL::UUID,
  'the internal school routing id remains available'
);

SELECT * FROM finish();
ROLLBACK;
