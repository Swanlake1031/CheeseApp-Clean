BEGIN;

SELECT no_plan();

SELECT hasnt_table(
  'public',
  'rent_posts',
  'Rent detail table is removed'
);

SELECT hasnt_view(
  'public',
  'rent_posts_view',
  'Rent public view is removed'
);

SELECT is(
  (SELECT COUNT(*) FROM public.posts WHERE type = 'rent'),
  0::BIGINT,
  'No Rent base posts remain'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.proname ILIKE '%rent%'
  ),
  'No Rent-named public RPC remains'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prokind = 'f'
      AND pg_get_functiondef(procedure.oid) ~* E'\\mrent(_posts)?\\M'
  ),
  'Shared public functions no longer contain Rent branches'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('v', 'm')
      AND pg_get_viewdef(relation.oid, TRUE) ~* E'\\mrent(_posts)?\\M'
  ),
  'Active public views no longer reference Rent'
);

SELECT throws_like(
  $$
    INSERT INTO public.posts (
      id, user_id, school_id, type, title, status, is_anonymous, is_private
    )
    SELECT
      '12700000-0000-4000-8000-000000000001'::UUID,
      profile.id,
      profile.school_id,
      'rent',
      'retired module',
      'active',
      FALSE,
      FALSE
    FROM public.profiles profile
    WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID
  $$,
  '%posts_type_allowed_check%',
  'Base posts reject the retired Rent type'
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

SELECT throws_like(
  $$SELECT public.prepare_post_media_operation(
    '12700000-0000-4000-8000-000000000002'::UUID,
    '12700000-0000-4000-8000-000000000003'::UUID,
    'rent',
    '[]'::JSONB
  )$$,
  '%Unsupported post type%',
  'Media staging rejects the retired Rent type'
);

SELECT throws_like(
  $$SELECT * FROM public.search_posts_page(
    'retired', 'rent', NULL, NULL, NULL, 10
  )$$,
  '%unsupported search category%',
  'Search rejects the retired Rent category'
);

SELECT throws_like(
  $$SELECT public.has_sent_post_linked_card(
    '10800000-0000-4000-8000-000000000001'::UUID,
    'rent',
    '12700000-0000-4000-8000-000000000004'::UUID
  )$$,
  '%unsupported post kind%',
  'Chat linked-card lookup rejects the retired Rent kind'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
