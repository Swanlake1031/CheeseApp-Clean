BEGIN;

SELECT plan(11);

DELETE FROM public.user_blocks
WHERE blocker_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID,
  '00000000-0000-0000-0000-000000000003'::UUID
)
OR blocked_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID,
  '00000000-0000-0000-0000-000000000003'::UUID
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '13000000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum',
  'Comment notification test post',
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
  '13000000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE, FALSE, FALSE
);

INSERT INTO public.comments (
  id, post_id, user_id, content, is_anonymous
)
VALUES (
  '13000000-0000-4000-8000-000000000010',
  '13000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'top-level comment',
  FALSE
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'post_comment'
      AND comment_id =
        '13000000-0000-4000-8000-000000000010'
  ),
  1::BIGINT,
  'a top-level forum comment notifies the post owner'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '13000000-0000-4000-8000-000000000011',
  '13000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '13000000-0000-4000-8000-000000000010',
  'reply to commenter',
  FALSE
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND kind = 'comment_reply'
      AND comment_id =
        '13000000-0000-4000-8000-000000000011'
  ),
  1::BIGINT,
  'a reply notifies the author of the parent comment'
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000001'
      AND kind = 'post_comment'
      AND comment_id =
        '13000000-0000-4000-8000-000000000011'
  ),
  1::BIGINT,
  'a reply also keeps the post owner informed when recipients differ'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '13000000-0000-4000-8000-000000000012',
  '13000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  '13000000-0000-4000-8000-000000000010',
  'anonymous reply',
  TRUE
);

SELECT is(
  (
    SELECT actor_user_id
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND kind = 'comment_reply'
      AND comment_id =
        '13000000-0000-4000-8000-000000000012'
  ),
  NULL::UUID,
  'anonymous replies do not expose the actor ID'
);

SELECT ok(
  (
    SELECT body LIKE '匿名用户%'
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND kind = 'comment_reply'
      AND comment_id =
        '13000000-0000-4000-8000-000000000012'
  ),
  'anonymous reply copy does not expose the profile name'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous
)
VALUES (
  '13000000-0000-4000-8000-000000000013',
  '13000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '13000000-0000-4000-8000-000000000010',
  'self reply',
  FALSE
);

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND comment_id =
        '13000000-0000-4000-8000-000000000013'
  ),
  0::BIGINT,
  'replying to your own comment does not notify yourself'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_trigger
    WHERE tgrelid = 'public.comments'::regclass
      AND tgname = 'trg_enqueue_forum_comment_push'
      AND NOT tgisinternal
  ),
  0::BIGINT,
  'the overlapping legacy direct comment push trigger is removed'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_trigger
    WHERE tgrelid = 'public.likes'::regclass
      AND tgname = 'trg_enqueue_forum_like_push'
      AND NOT tgisinternal
  ),
  0::BIGINT,
  'the overlapping legacy direct like push trigger is removed'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_trigger
    WHERE tgrelid = 'public.comments'::regclass
      AND tgname = 'trg_notify_system_message_for_comment'
      AND NOT tgisinternal
  ),
  1::BIGINT,
  'the feature-owned comment system-message trigger is installed'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.notify_system_message_for_comment()',
    'EXECUTE'
  ),
  'clients cannot invoke the comment notification trigger directly'
);

SELECT ok(
  NOT has_table_privilege(
    'authenticated',
    'public.system_messages',
    'INSERT'
  ),
  'clients still cannot forge system messages'
);

SELECT * FROM finish();
ROLLBACK;
