BEGIN;

SELECT plan(4);

SELECT hasnt_function(
  'public',
  'complete_profile',
  ARRAY['text', 'text', 'text', 'text', 'text', 'text', 'boolean'],
  'the graduated profile-completion RPC is removed'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.complete_profile(text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'the standard profile-completion RPC remains available'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profiles
    WHERE is_graduated = TRUE
  ),
  0::BIGINT,
  'legacy graduation preferences are cleared'
);

SELECT throws_like(
  $$UPDATE public.profiles
    SET is_graduated = TRUE
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID$$,
  '%profiles_graduation_feature_removed_check%',
  'the compatibility column cannot reactivate the removed feature'
);

SELECT * FROM finish();
ROLLBACK;
