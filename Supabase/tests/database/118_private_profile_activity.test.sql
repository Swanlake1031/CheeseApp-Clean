BEGIN;

SELECT plan(14);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_my_profile_activity_page(text,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'authenticated users can read their private activity through the RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.get_my_profile_activity_page(text,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'anonymous users cannot read profile activity'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  fixture.id,
  fixture.user_id,
  profile.school_id,
  'forum',
  fixture.title,
  fixture.description,
  'active',
  FALSE,
  fixture.is_private,
  fixture.created_at
FROM (
  VALUES
    (
      '71800000-0000-4000-8000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'Alice published',
      'owned content',
      FALSE,
      '2026-07-20 12:00:00+00'::TIMESTAMPTZ
    ),
    (
      '71800000-0000-4000-8000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000002'::UUID,
      'Visible target',
      'visible content',
      FALSE,
      '2026-07-21 12:00:00+00'::TIMESTAMPTZ
    ),
    (
      '71800000-0000-4000-8000-000000000003'::UUID,
      '00000000-0000-0000-0000-000000000002'::UUID,
      'Private target',
      'must not leak',
      TRUE,
      '2026-07-22 12:00:00+00'::TIMESTAMPTZ
    )
) AS fixture(
  id, user_id, title, description, is_private, created_at
)
JOIN public.profiles profile ON profile.id = fixture.user_id;

INSERT INTO public.forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked
)
VALUES
  (
    '71800000-0000-4000-8000-000000000001',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  ),
  (
    '71800000-0000-4000-8000-000000000002',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  ),
  (
    '71800000-0000-4000-8000-000000000003',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  );

INSERT INTO public.likes (
  user_id, target_type, target_id, created_at
)
VALUES
  (
    '00000000-0000-0000-0000-000000000001',
    'post',
    '71800000-0000-4000-8000-000000000002',
    '2026-07-24 12:00:00+00'
  ),
  (
    '00000000-0000-0000-0000-000000000001',
    'post',
    '71800000-0000-4000-8000-000000000003',
    '2026-07-25 12:00:00+00'
  );

INSERT INTO public.favorites (
  user_id, post_id, created_at
)
VALUES
  (
    '00000000-0000-0000-0000-000000000001',
    '71800000-0000-4000-8000-000000000002',
    '2026-07-24 13:00:00+00'
  ),
  (
    '00000000-0000-0000-0000-000000000001',
    '71800000-0000-4000-8000-000000000003',
    '2026-07-25 13:00:00+00'
  );

INSERT INTO public.comments (
  id, post_id, user_id, content, is_anonymous, created_at
)
VALUES
  (
    '71810000-0000-4000-8000-000000000001',
    '71800000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    'my visible comment',
    FALSE,
    '2026-07-24 14:00:00+00'
  ),
  (
    '71810000-0000-4000-8000-000000000002',
    '71800000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000001',
    'must not leak',
    FALSE,
    '2026-07-25 14:00:00+00'
  );

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'published', NULL, NULL, 30
    )
    WHERE post_id = '71800000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'published activity is viewer relative'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'liked', NULL, NULL, 30
    )
  ),
  1::BIGINT,
  'liked activity hides private or inaccessible posts'
);
SELECT is(
  (
    SELECT post_id
    FROM public.get_my_profile_activity_page(
      'liked', NULL, NULL, 30
    )
  ),
  '71800000-0000-4000-8000-000000000002'::UUID,
  'liked activity returns the visible real post ID'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'favorited', NULL, NULL, 30
    )
  ),
  1::BIGINT,
  'favorite activity hides private or inaccessible posts'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'commented', NULL, NULL, 30
    )
    WHERE post_id IN (
      '71800000-0000-4000-8000-000000000002',
      '71800000-0000-4000-8000-000000000003'
    )
  ),
  1::BIGINT,
  'comment activity hides comments on inaccessible posts'
);
SELECT is(
  (
    SELECT activity_summary
    FROM public.get_my_profile_activity_page(
      'commented', NULL, NULL, 30
    )
    WHERE comment_id =
      '71810000-0000-4000-8000-000000000001'
  ),
  'my visible comment',
  'comment activity returns the current viewer comment summary'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'liked',
      '2026-07-24 12:00:00+00',
      '71800000-0000-4000-8000-000000000002',
      30
    )
  ),
  0::BIGINT,
  'keyset cursor does not repeat the boundary item'
);
SELECT throws_ok(
  $$
    SELECT *
    FROM public.get_my_profile_activity_page(
      'liked', now(), NULL, 30
    )
  $$,
  '22023',
  NULL,
  'partial cursors are rejected'
);
SELECT throws_ok(
  $$
    SELECT *
    FROM public.get_my_profile_activity_page(
      'unknown', NULL, NULL, 30
    )
  $$,
  '22023',
  NULL,
  'unsupported activity kinds are rejected'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"role":"anon"}',
  TRUE
);
SET LOCAL ROLE anon;

SELECT throws_ok(
  $$
    SELECT *
    FROM public.get_my_profile_activity_page(
      'liked', NULL, NULL, 30
    )
  $$,
  '42501',
  NULL,
  'anonymous callers cannot invoke the private activity RPC'
);

RESET ROLE;

SELECT is(
  (
    SELECT count(*)
    FROM public.likes
    WHERE user_id =
      '00000000-0000-0000-0000-000000000001'
      AND target_id =
        '71800000-0000-4000-8000-000000000003'
  ),
  1::BIGINT,
  'hidden source relationships remain intact'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.favorites
    WHERE user_id =
      '00000000-0000-0000-0000-000000000001'
      AND post_id =
        '71800000-0000-4000-8000-000000000003'
  ),
  1::BIGINT,
  'the RPC filters visibility without deleting private history'
);

SELECT * FROM finish();
ROLLBACK;
