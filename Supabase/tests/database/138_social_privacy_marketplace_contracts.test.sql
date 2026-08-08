BEGIN;

SELECT plan(16);

SELECT ok(
  has_function_privilege('authenticated', 'public.remove_my_follower(uuid)', 'EXECUTE'),
  'authenticated users can remove their own followers'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.set_my_post_hidden(uuid,boolean)', 'EXECUTE'),
  'authenticated owners can hide their posts'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.get_profile_posts(uuid)', 'EXECUTE'),
  'authenticated users can load privacy-aware profile posts'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.publish_secondhand_post_with_mentions(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,timestamptz,uuid[])',
    'EXECUTE'
  ),
  'legacy clients retain publish compatibility while the trigger fixes expiry'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.publish_secondhand_post_with_mentions(uuid,uuid,text,text,boolean,boolean,numeric,numeric,text,text,boolean,uuid[])',
    'EXECUTE'
  ),
  'clients can publish with original price and server expiry'
);

DELETE FROM public.user_follows
WHERE follower_id = '00000000-0000-0000-0000-000000000002'
  AND following_id = '00000000-0000-0000-0000-000000000001';
INSERT INTO public.user_follows (follower_id, following_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT fixture.id, fixture.user_id, profile.school_id, 'forum', fixture.title,
       'privacy contract', 'active', fixture.is_anonymous, fixture.is_private
FROM (
  VALUES
    ('73800000-0000-4000-8000-000000000001'::UUID, '00000000-0000-0000-0000-000000000001'::UUID, 'Hide me', FALSE, FALSE),
    ('73800000-0000-4000-8000-000000000002'::UUID, '00000000-0000-0000-0000-000000000001'::UUID, 'Private', FALSE, TRUE),
    ('73800000-0000-4000-8000-000000000003'::UUID, '00000000-0000-0000-0000-000000000001'::UUID, 'Anonymous', TRUE, FALSE),
    ('73800000-0000-4000-8000-000000000004'::UUID, '00000000-0000-0000-0000-000000000001'::UUID, 'Visible', FALSE, FALSE),
    ('73800000-0000-4000-8000-000000000005'::UUID, '00000000-0000-0000-0000-000000000002'::UUID, 'Other owner', FALSE, FALSE)
) AS fixture(id, user_id, title, is_anonymous, is_private)
JOIN public.profiles profile ON profile.id = fixture.user_id;

INSERT INTO public.forum_posts (id, board_id, allow_comments)
SELECT fixture.id, board.id, TRUE
FROM (
  VALUES
    ('73800000-0000-4000-8000-000000000001'::UUID),
    ('73800000-0000-4000-8000-000000000002'::UUID),
    ('73800000-0000-4000-8000-000000000003'::UUID),
    ('73800000-0000-4000-8000-000000000004'::UUID),
    ('73800000-0000-4000-8000-000000000005'::UUID)
) AS fixture(id)
CROSS JOIN LATERAL (
  SELECT id FROM public.forum_boards ORDER BY id LIMIT 1
) AS board;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '73800000-0000-4000-8000-000000000006'::UUID,
  profile.id,
  profile.school_id,
  'secondhand',
  'Fixed expiry listing',
  'marketplace contract',
  'active',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001';

INSERT INTO public.secondhand_posts (
  id, price, original_price, category, condition, quantity
)
VALUES (
  '73800000-0000-4000-8000-000000000006',
  50, 100, 'digital_electronics', 'good', 1
);

SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.remove_my_follower('00000000-0000-0000-0000-000000000002'),
  TRUE,
  'profile owner can remove a follower'
);
SELECT is(
  (
    SELECT count(*) FROM public.user_follows
    WHERE follower_id = '00000000-0000-0000-0000-000000000002'
      AND following_id = '00000000-0000-0000-0000-000000000001'
  ),
  0::BIGINT,
  'removed follower relationship no longer exists'
);
SELECT is(
  public.remove_my_follower('00000000-0000-0000-0000-000000000002'),
  FALSE,
  'removing the same follower is idempotent'
);
SELECT is(
  (SELECT count(*) FROM public.get_profile_posts('00000000-0000-0000-0000-000000000001')),
  5::BIGINT,
  'owner sees public, hidden, anonymous, and Marketplace profile posts'
);
SELECT is(
  public.set_my_post_hidden('73800000-0000-4000-8000-000000000001', TRUE),
  TRUE,
  'owner can hide a published post without deleting it'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*) FROM public.get_profile_posts('00000000-0000-0000-0000-000000000001')),
  2::BIGINT,
  'other users only see public non-anonymous profile posts'
);
SELECT throws_ok(
  $$ SELECT public.set_my_post_hidden('73800000-0000-4000-8000-000000000004', TRUE) $$,
  '42501',
  NULL,
  'another user cannot hide the owner post'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT gender
    FROM public.complete_profile(NULL, 'McMaster University', NULL, NULL, NULL, NULL)
  ),
  NULL::TEXT,
  'profile completion accepts optional gender'
);

RESET ROLE;
SELECT ok(
  (
    SELECT expires_at BETWEEN clock_timestamp() + INTERVAL '27 days'
                          AND clock_timestamp() + INTERVAL '32 days'
    FROM public.secondhand_posts
    WHERE id = '73800000-0000-4000-8000-000000000006'
  ),
  'Marketplace expiry defaults to approximately one month'
);
SELECT is(
  (
    SELECT original_price FROM public.secondhand_posts
    WHERE id = '73800000-0000-4000-8000-000000000006'
  ),
  100::NUMERIC,
  'Marketplace stores original price separately from selling price'
);
SELECT throws_ok(
  $$
    UPDATE public.posts
    SET title = repeat('x', 81)
    WHERE id = '73800000-0000-4000-8000-000000000004'
  $$,
  '22023',
  NULL,
  'database rejects forum titles over 80 characters'
);

SELECT * FROM finish();
ROLLBACK;
