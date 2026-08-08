BEGIN;

SELECT plan(7);

SELECT has_column(
  'public',
  'profiles',
  'show_gender',
  'profiles store the public gender-label preference'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.complete_profile(text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'authenticated users can complete their profile'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT throws_like(
  $$SELECT public.complete_profile(
    p_full_name => 'Gender Test',
    p_university => NULL,
    p_gender => NULL,
    p_occupation => NULL
  )$$,
  '%Gender is required%',
  'profile completion rejects an omitted gender'
);

SELECT lives_ok(
  $$SELECT public.complete_profile(
    p_full_name => 'Gender Test',
    p_university => NULL,
    p_gender => 'female',
    p_occupation => NULL
  )$$,
  'profile completion accepts a supported gender'
);

SELECT is(
  (
    SELECT university
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  NULL::TEXT,
  'an omitted optional school remains empty'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

UPDATE public.profiles
SET show_gender = FALSE
WHERE id = '00000000-0000-0000-0000-000000000001'::UUID;

RESET ROLE;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT gender
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  NULL::TEXT,
  'the public profile hides gender when the preference is disabled'
);

SELECT is(
  (
    SELECT show_gender
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  FALSE,
  'the public profile exposes the disabled visibility state'
);

SELECT * FROM finish();
ROLLBACK;
