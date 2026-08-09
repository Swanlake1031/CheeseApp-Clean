BEGIN;

SELECT plan(3);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.search_posts_page(text,text,double precision,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'authenticated users retain the paginated Search contract'
);

SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);

SELECT lives_ok(
  $$
    SELECT *
    FROM public.search_posts_page('', 'market', NULL, NULL, NULL, 1)
  $$,
  'Marketplace Search uses only columns in the active schema'
);

SELECT ok(
  position(
    'pickup_location'
    IN pg_get_functiondef(
      'public.search_posts_page(text,text,double precision,timestamp with time zone,uuid,integer)'::REGPROCEDURE
    )
  ) = 0,
  'the retired pickup_location field is not restored'
);

SELECT * FROM finish();
ROLLBACK;
