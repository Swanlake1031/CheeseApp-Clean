BEGIN;

SELECT plan(6);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_my_profile_activity_page(text,text,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'authenticated users can filter their published activity'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  fixture.id,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  fixture.post_type,
  fixture.title,
  fixture.title,
  'active',
  FALSE,
  FALSE,
  fixture.created_at
FROM (
  VALUES
    (
      '74200000-0000-4000-8000-000000000001'::UUID,
      'forum',
      'Filtered forum post',
      '2026-08-05 12:00:00+00'::TIMESTAMPTZ
    ),
    (
      '74200000-0000-4000-8000-000000000002'::UUID,
      'secondhand',
      'Filtered secondhand post',
      '2026-08-05 13:00:00+00'::TIMESTAMPTZ
    )
) AS fixture(id, post_type, title, created_at)
JOIN public.profiles profile
  ON profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked
)
VALUES (
  '74200000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE,
  FALSE,
  FALSE
);

INSERT INTO public.secondhand_posts (id, price, category, condition)
VALUES (
  '74200000-0000-4000-8000-000000000002',
  25,
  'other',
  'good'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_profile_activity_page(
      'published', 'forum', NULL, NULL, 30
    )
    WHERE post_id IN (
      '74200000-0000-4000-8000-000000000001'::UUID,
      '74200000-0000-4000-8000-000000000002'::UUID
    )
  ),
  1::BIGINT,
  'forum filtering returns only the forum fixture'
);

SELECT is(
  (
    SELECT post_type
    FROM public.get_my_profile_activity_page(
      'published', 'forum', NULL, NULL, 30
    )
    WHERE post_id = '74200000-0000-4000-8000-000000000001'::UUID
  ),
  'forum',
  'forum filtering preserves the canonical post type'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_profile_activity_page(
      'published', 'secondhand', NULL, NULL, 30
    )
    WHERE post_id IN (
      '74200000-0000-4000-8000-000000000001'::UUID,
      '74200000-0000-4000-8000-000000000002'::UUID
    )
  ),
  1::BIGINT,
  'secondhand filtering returns only the marketplace fixture'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_profile_activity_page(
      'published', NULL, NULL, NULL, 30
    )
    WHERE post_id IN (
      '74200000-0000-4000-8000-000000000001'::UUID,
      '74200000-0000-4000-8000-000000000002'::UUID
    )
  ),
  2::BIGINT,
  'the null filter remains the combined published feed'
);

SELECT throws_like(
  $$SELECT * FROM public.get_my_profile_activity_page(
    'published', 'rent', NULL, NULL, 30
  )$$,
  '%Unsupported published post type%',
  'retired post types cannot be requested through the filter'
);

SELECT * FROM finish();
ROLLBACK;
