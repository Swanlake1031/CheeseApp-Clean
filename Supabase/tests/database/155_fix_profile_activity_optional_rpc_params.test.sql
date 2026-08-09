BEGIN;

SELECT plan(3);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_my_profile_activity_page(text,text,text,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'authenticated owners retain access to the canonical activity RPC'
);

SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$
    SELECT *
    FROM public.get_my_profile_activity_page(
      p_activity_kind => 'published',
      p_visibility => 'visible',
      p_limit => 30
    )
  $$,
  'the unfiltered first page may omit post type and cursor parameters'
);

SELECT lives_ok(
  $$
    SELECT *
    FROM public.get_my_profile_activity_page(
      p_activity_kind => 'published',
      p_post_type => 'forum',
      p_visibility => 'hidden',
      p_limit => 30
    )
  $$,
  'a filtered first page may omit cursor parameters'
);

SELECT * FROM finish();
ROLLBACK;
