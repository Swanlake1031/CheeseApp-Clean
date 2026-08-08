BEGIN;

SELECT plan(22);

SELECT ok(
  NOT has_table_privilege(
    'authenticated',
    'public.content_mentions',
    'INSERT'
  ),
  'clients cannot insert mention rows directly'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.sync_content_mentions(text,uuid,uuid,uuid[])',
    'EXECUTE'
  ),
  'authenticated clients can use the author-bound mention RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_content_mentions(uuid,uuid)',
    'EXECUTE'
  ),
  'visible mention targets are available through a narrow read RPC'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_forum_comment_with_mentions(uuid,uuid,text,boolean,uuid,uuid[])',
    'EXECUTE'
  ),
  'authenticated clients can create comments and stable mentions atomically'
);

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
  fixture.id,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum',
  fixture.title,
  'mentions',
  'active',
  fixture.is_anonymous,
  fixture.is_private
FROM (
  VALUES
    (
      '71700000-0000-4000-8000-000000000001'::UUID,
      'Public mention post',
      FALSE,
      FALSE
    ),
    (
      '71700000-0000-4000-8000-000000000002'::UUID,
      'Private mention post',
      FALSE,
      TRUE
    ),
    (
      '71700000-0000-4000-8000-000000000003'::UUID,
      'Anonymous mention post',
      TRUE,
      FALSE
    )
) AS fixture(id, title, is_anonymous, is_private)
JOIN public.profiles profile
  ON profile.id = '00000000-0000-0000-0000-000000000001';

INSERT INTO public.forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked
)
VALUES
  (
    '71700000-0000-4000-8000-000000000001',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  ),
  (
    '71700000-0000-4000-8000-000000000002',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  ),
  (
    '71700000-0000-4000-8000-000000000003',
    'f0000000-0000-0000-0000-000000000001',
    TRUE, FALSE, FALSE
  );

INSERT INTO public.comments (
  id, post_id, user_id, content, is_anonymous
)
VALUES (
  '71710000-0000-4000-8000-000000000001',
  '71700000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '@Carol hello',
  FALSE
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
  public.sync_content_mentions(
    'forum',
    '71700000-0000-4000-8000-000000000001',
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID
    ]
  ),
  1,
  'stable IDs are deduplicated and self mentions are suppressed'
);
SELECT is(
  public.sync_content_mentions(
    'forum',
    '71700000-0000-4000-8000-000000000001',
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000002'::UUID
    ]
  ),
  0,
  'repeating the same content mention is idempotent'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_content_mentions(
      '71700000-0000-4000-8000-000000000001',
      NULL
    )
  ),
  1::BIGINT,
  'visible content exposes one stable profile destination'
);

RESET ROLE;
SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND kind = 'mention'
      AND post_id =
        '71700000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'a public mention creates one system message'
);

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

SELECT throws_ok(
  $$
    SELECT public.sync_content_mentions(
      'forum',
      '71700000-0000-4000-8000-000000000001',
      NULL,
      ARRAY[
        '00000000-0000-0000-0000-000000000003'::UUID
      ]
    )
  $$,
  '42501',
  NULL,
  'a non-author cannot set post mentions'
);

SELECT is(
  public.create_forum_comment_with_mentions(
    '71710000-0000-4000-8000-000000000002',
    '71700000-0000-4000-8000-000000000001',
    '@Carol atomic hello',
    FALSE,
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000003'::UUID
    ]
  ),
  '71710000-0000-4000-8000-000000000002'::UUID,
  'comment creation returns the client request ID'
);
SELECT is(
  public.create_forum_comment_with_mentions(
    '71710000-0000-4000-8000-000000000002',
    '71700000-0000-4000-8000-000000000001',
    '@Carol atomic hello',
    FALSE,
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000003'::UUID
    ]
  ),
  '71710000-0000-4000-8000-000000000002'::UUID,
  'comment creation is idempotent for the same request payload'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.comments
    WHERE id = '71710000-0000-4000-8000-000000000002'
  ),
  1::BIGINT,
  'an idempotent retry does not duplicate the comment'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_content_mentions(
      '71700000-0000-4000-8000-000000000001',
      '71710000-0000-4000-8000-000000000002'
    )
  ),
  1::BIGINT,
  'comment and mention metadata commit together'
);

SELECT is(
  public.sync_content_mentions(
    'comment',
    '71700000-0000-4000-8000-000000000001',
    '71710000-0000-4000-8000-000000000001',
    ARRAY[
      '00000000-0000-0000-0000-000000000003'::UUID
    ]
  ),
  1,
  'a comment author can mention by stable user ID'
);

RESET ROLE;
SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000003'
      AND kind = 'mention'
      AND comment_id =
        '71710000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'comment mentions enter the same protected timeline'
);

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000001'
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
  public.sync_content_mentions(
    'forum',
    '71700000-0000-4000-8000-000000000001',
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000003'::UUID
    ]
  ),
  0,
  'blocked and already-delivered recipients do not create new mentions'
);
SELECT is(
  public.sync_content_mentions(
    'forum',
    '71700000-0000-4000-8000-000000000002',
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000002'::UUID
    ]
  ),
  0,
  'private posts never deliver mentions'
);
SELECT is(
  public.sync_content_mentions(
    'forum',
    '71700000-0000-4000-8000-000000000003',
    NULL,
    ARRAY[
      '00000000-0000-0000-0000-000000000002'::UUID
    ]
  ),
  1,
  'anonymous public content may mention without exposing its author'
);

RESET ROLE;
SELECT is(
  (
    SELECT actor_user_id
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND post_id =
        '71700000-0000-4000-8000-000000000003'
      AND kind = 'mention'
  ),
  NULL::UUID,
  'anonymous mention notification hides the actor identity'
);
SELECT is(
  (
    SELECT left(body, 4)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'
      AND post_id =
        '71700000-0000-4000-8000-000000000003'
      AND kind = 'mention'
  ),
  '匿名用户',
  'anonymous mention uses an explicit privacy-safe label'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.content_mentions
    WHERE post_id =
      '71700000-0000-4000-8000-000000000002'
  ),
  0::BIGINT,
  'private mention relations are not retained'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.content_mentions
    WHERE actor_user_id = mentioned_user_id
  ),
  0::BIGINT,
  'self mention rows never exist'
);

SELECT * FROM finish();
ROLLBACK;
