BEGIN;

SELECT plan(20);

SELECT ok(
  NOT has_table_privilege('anon', 'public.system_messages', 'SELECT'),
  'anonymous users cannot read system messages'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.system_messages', 'INSERT'),
  'authenticated users cannot insert system messages directly'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.system_messages', 'UPDATE'),
  'authenticated users cannot alter system message content directly'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.enqueue_system_message(uuid,text,text,text,text,uuid,uuid,uuid,text,text,boolean)',
    'EXECUTE'
  ),
  'the system message insertion primitive is not client callable'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_system_messages_page(timestamptz,uuid,integer)',
    'EXECUTE'
  ),
  'authenticated clients can page their own system messages'
);

DELETE FROM public.user_blocks
WHERE blocker_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
)
OR blocked_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '71500000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum',
  'System notification test post',
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
  '71500000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE, FALSE, FALSE
);

INSERT INTO public.likes (user_id, target_type, target_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  'post',
  '71500000-0000-4000-8000-000000000001'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'post_like'
      AND post_id =
        '71500000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'a post like creates one in-app system message'
);

DELETE FROM public.likes
WHERE user_id = '00000000-0000-0000-0000-000000000002'
  AND target_type = 'post'
  AND target_id = '71500000-0000-4000-8000-000000000001';
INSERT INTO public.likes (user_id, target_type, target_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  'post',
  '71500000-0000-4000-8000-000000000001'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'post_like'
      AND post_id =
        '71500000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'unlike and re-like within the cooldown does not spam'
);

INSERT INTO public.likes (user_id, target_type, target_id)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'post',
  '71500000-0000-4000-8000-000000000001'
)
ON CONFLICT DO NOTHING;

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND actor_user_id =
        '00000000-0000-0000-0000-000000000001'
  ),
  0::BIGINT,
  'self likes do not notify'
);

DELETE FROM public.user_follows
WHERE follower_id = '00000000-0000-0000-0000-000000000002'
  AND following_id = '00000000-0000-0000-0000-000000000001';
INSERT INTO public.user_follows (follower_id, following_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'follow'
      AND actor_user_id =
        '00000000-0000-0000-0000-000000000002'
  ),
  1::BIGINT,
  'a follow creates one in-app system message'
);

DELETE FROM public.user_follows
WHERE follower_id = '00000000-0000-0000-0000-000000000002'
  AND following_id = '00000000-0000-0000-0000-000000000001';
INSERT INTO public.user_follows (follower_id, following_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'follow'
      AND actor_user_id =
        '00000000-0000-0000-0000-000000000002'
  ),
  1::BIGINT,
  'unfollow and refollow within the cooldown does not spam'
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
    FROM public.get_system_messages_page(NULL, NULL, 30)
  ),
  2::BIGINT,
  'the recipient can page only their two notifications'
);
SELECT is(
  public.get_system_message_unread_count(),
  2,
  'unread count is account scoped'
);
SELECT ok(
  public.mark_system_message_read(
    (
      SELECT id
      FROM public.get_system_messages_page(NULL, NULL, 30)
      ORDER BY created_at DESC, id DESC
      LIMIT 1
    )
  ),
  'recipient can mark one message read'
);
SELECT is(
  public.get_system_message_unread_count(),
  1,
  'single read updates unread count'
);
SELECT is(
  public.mark_all_system_messages_read(),
  1,
  'mark all read returns the number changed'
);
SELECT is(
  public.get_system_message_unread_count(),
  0,
  'all messages are read'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*)
    FROM public.get_system_messages_page(NULL, NULL, 30)
    WHERE post_id =
      '71500000-0000-4000-8000-000000000001'
  ),
  0::BIGINT,
  'another account cannot read the recipient timeline'
);
SELECT ok(
  NOT public.mark_system_message_read(
    (
      SELECT message.id
      FROM public.system_messages message
      WHERE message.recipient_user_id =
        '00000000-0000-0000-0000-000000000001'
      LIMIT 1
    )
  ),
  'another account cannot mark the recipient message read'
);

RESET ROLE;

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000003'
)
ON CONFLICT DO NOTHING;

INSERT INTO public.likes (user_id, target_type, target_id)
VALUES (
  '00000000-0000-0000-0000-000000000003',
  'post',
  '71500000-0000-4000-8000-000000000001'
)
ON CONFLICT DO NOTHING;

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND actor_user_id =
        '00000000-0000-0000-0000-000000000003'
  ),
  0::BIGINT,
  'blocked actors never create system messages'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id IS NULL
  ),
  0::BIGINT,
  'system messages always have an owning account'
);

SELECT * FROM finish();
ROLLBACK;
