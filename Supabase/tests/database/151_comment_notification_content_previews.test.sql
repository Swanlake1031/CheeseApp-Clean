BEGIN;

SELECT plan(4);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '15100000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum',
  'Notification content preview test',
  'test',
  'active',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked
)
VALUES (
  '15100000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE, FALSE, FALSE
);

INSERT INTO public.comments (
  id, post_id, user_id, content, is_anonymous
)
VALUES (
  '15100000-0000-4000-8000-000000000010',
  '15100000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  E'top-level   comment\nwith spaces',
  FALSE
);

SELECT ok(
  (
    SELECT body LIKE '%：“top-level comment with spaces”'
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND comment_id =
        '15100000-0000-4000-8000-000000000010'
      AND kind = 'post_comment'
  ),
  'top-level comment notifications include normalized comment text'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '15100000-0000-4000-8000-000000000011',
  '15100000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '15100000-0000-4000-8000-000000000010',
  'reply content is visible',
  FALSE
);

SELECT ok(
  (
    SELECT body LIKE '%回复了你在%：“reply content is visible”'
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND comment_id =
        '15100000-0000-4000-8000-000000000011'
      AND kind = 'comment_reply'
  ),
  'reply notifications include the reply text'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '15100000-0000-4000-8000-000000000012',
  '15100000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '15100000-0000-4000-8000-000000000010',
  'anonymous reply content',
  TRUE
);

SELECT ok(
  (
    SELECT body LIKE '匿名用户%：“anonymous reply content”'
      AND actor_user_id IS NULL
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND comment_id =
        '15100000-0000-4000-8000-000000000012'
      AND kind = 'comment_reply'
  ),
  'anonymous reply previews retain actor privacy'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '15100000-0000-4000-8000-000000000013',
  '15100000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '15100000-0000-4000-8000-000000000010',
  repeat('x', 160),
  FALSE
);

SELECT ok(
  (
    SELECT body LIKE '%' || repeat('x', 119) || '…”'
      AND char_length(body) <= 500
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND comment_id =
        '15100000-0000-4000-8000-000000000013'
      AND kind = 'comment_reply'
  ),
  'long reply previews are bounded and visibly truncated'
);

SELECT * FROM finish();
ROLLBACK;
