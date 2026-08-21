BEGIN;

SELECT plan(8);

SELECT ok(
  has_function_privilege(
    'anon',
    'public.get_public_secondhand_share_post(uuid)',
    'EXECUTE'
  ),
  'anonymous share clients can execute the narrow listing RPC'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.secondhand_posts', 'SELECT'),
  'anonymous share clients still cannot read the Marketplace table'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  fixture.id,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'secondhand',
  fixture.title,
  fixture.description,
  fixture.status,
  FALSE,
  fixture.is_private
FROM (
  VALUES
    (
      '77700000-0000-4000-8000-000000000001'::UUID,
      'Public share listing'::TEXT,
      'Visible listing body'::TEXT,
      'active'::TEXT,
      FALSE
    ),
    (
      '77700000-0000-4000-8000-000000000002'::UUID,
      'Private listing'::TEXT,
      'Must not leak'::TEXT,
      'active'::TEXT,
      TRUE
    ),
    (
      '77700000-0000-4000-8000-000000000003'::UUID,
      'Completed listing'::TEXT,
      'Must not leak'::TEXT,
      'completed'::TEXT,
      FALSE
    )
) AS fixture(id, title, description, status, is_private)
JOIN public.profiles profile
  ON profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, quantity
)
VALUES
  ('77700000-0000-4000-8000-000000000001', 40, 'appliances', 'good', 1),
  ('77700000-0000-4000-8000-000000000002', 50, 'furniture', 'good', 1),
  ('77700000-0000-4000-8000-000000000003', 60, 'other', 'fair', 1);

SELECT set_config('request.jwt.claim.role', 'anon', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
SET LOCAL ROLE anon;

SELECT is(
  (
    SELECT count(*)
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000001'
    )
  ),
  1::BIGINT,
  'an active public listing is shareable'
);
SELECT is(
  (
    SELECT title
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000001'
    )
  ),
  'Public share listing',
  'the share RPC returns real listing metadata'
);
SELECT is(
  (
    SELECT price
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000001'
    )
  ),
  40::NUMERIC,
  'the share RPC returns the listing price'
);
SELECT is(
  (
    SELECT images
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000001'
    )
  ),
  '[]'::JSON,
  'a listing without media returns an empty image list'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000002'
    )
  ),
  0::BIGINT,
  'a private listing is never exposed'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_public_secondhand_share_post(
      '77700000-0000-4000-8000-000000000003'
    )
  ),
  0::BIGINT,
  'a completed listing is never exposed'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
