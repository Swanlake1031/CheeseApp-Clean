BEGIN;

SELECT plan(3);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '17600000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID,
  profile.school_id,
  'forum',
  'Retained comment test post',
  'test',
  'active',
  FALSE,
  FALSE
FROM public.profiles AS profile
WHERE profile.id = '00000000-0000-0000-0000-000000000002'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments, is_pinned, is_locked)
VALUES (
  '17600000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE,
  FALSE,
  FALSE
);

INSERT INTO public.comments (
  id, post_id, user_id, content, is_anonymous
)
VALUES (
  '17600000-0000-4000-8000-000000000010',
  '17600000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'This comment must survive deactivation',
  FALSE
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.deactivate_my_account(),
  'the user can deactivate the account'
);

RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT author_is_deactivated
    FROM public.comments
    WHERE id = '17600000-0000-4000-8000-000000000010'::UUID
  ),
  TRUE,
  'a comment on another user surviving post is retained and tombstoned'
);

SELECT is(
  (
    SELECT full_name
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  '已注销'::TEXT,
  'the retained comment author profile is anonymized'
);

SELECT * FROM finish();
ROLLBACK;
