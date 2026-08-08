BEGIN;

SELECT no_plan();

INSERT INTO public.conversations (
  id, user1_id, user2_id, created_at, updated_at
)
VALUES (
  '10800000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000004'::UUID,
  '2029-04-01T12:00:00Z'::TIMESTAMPTZ,
  '2029-04-01T12:00:00Z'::TIMESTAMPTZ
);

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type, metadata,
  is_read, is_deleted, created_at
)
SELECT
  ('10810000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  '10800000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  'Direct page fixture ' || n,
  'text',
  '{}'::JSONB,
  TRUE,
  FALSE,
  '2029-04-02T12:00:00Z'::TIMESTAMPTZ
FROM generate_series(1, 31) n;

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type, metadata,
  is_read, is_deleted, created_at
)
VALUES
(
  '10810000-0000-4000-8000-000000000090'::UUID,
  '10800000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  'own card',
  'post_share',
  '{"post_contact_card":{"post_kind":"secondhand","post_id":"10890000-0000-4000-8000-000000000001"}}',
  TRUE,
  FALSE,
  '2029-04-03T12:00:00Z'::TIMESTAMPTZ
),
(
  '10810000-0000-4000-8000-000000000091'::UUID,
  '10800000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000004'::UUID,
  'other sender card',
  'post_share',
  '{"post_contact_card":{"post_kind":"forum","post_id":"10890000-0000-4000-8000-000000000002"}}',
  TRUE,
  FALSE,
  '2029-04-03T12:01:00Z'::TIMESTAMPTZ
),
(
  '10810000-0000-4000-8000-000000000092'::UUID,
  '10800000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  'deleted card',
  'post_share',
  '{"post_contact_card":{"post_kind":"secondhand","post_id":"10890000-0000-4000-8000-000000000003"}}',
  TRUE,
  TRUE,
  '2029-04-03T12:02:00Z'::TIMESTAMPTZ
);

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '10820000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  'H3 pagination group'
);

INSERT INTO public.chat_group_members (group_id, user_id, role)
VALUES
  (
    '10820000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    'owner'
  ),
  (
    '10820000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID,
    'member'
  );

INSERT INTO public.group_messages (
  id, group_id, sender_id, content, message_type, metadata, is_deleted, created_at
)
SELECT
  ('10830000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  '10820000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  'Group page fixture ' || n,
  'text',
  '{}'::JSONB,
  FALSE,
  '2029-04-04T12:00:00Z'::TIMESTAMPTZ
FROM generate_series(1, 31) n;

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

CREATE TEMP TABLE direct_page_one AS
SELECT id, created_at
FROM public.get_direct_messages_page(
  '10800000-0000-4000-8000-000000000001'::UUID,
  NULL,
  NULL,
  10
);

CREATE TEMP TABLE direct_page_two AS
SELECT page.id, page.created_at
FROM (
  SELECT *
  FROM direct_page_one
  ORDER BY created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.get_direct_messages_page(
  '10800000-0000-4000-8000-000000000001'::UUID,
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is((SELECT COUNT(*) FROM direct_page_one), 10::BIGINT, 'Direct first page is bounded');
SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM direct_page_one
      UNION ALL
      SELECT id FROM direct_page_two
    ) pages
  ),
  20::BIGINT,
  'Direct timestamp ties use UUID without duplicate or skip'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM direct_page_one
    WHERE id = '10810000-0000-4000-8000-000000000092'::UUID
  ),
  'Direct history excludes deleted messages'
);

CREATE TEMP TABLE group_page_one AS
SELECT id, created_at
FROM public.get_group_messages_page(
  '10820000-0000-4000-8000-000000000001'::UUID,
  NULL,
  NULL,
  10
);

CREATE TEMP TABLE group_page_two AS
SELECT page.id, page.created_at
FROM (
  SELECT *
  FROM group_page_one
  ORDER BY created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.get_group_messages_page(
  '10820000-0000-4000-8000-000000000001'::UUID,
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is((SELECT COUNT(*) FROM group_page_one), 10::BIGINT, 'Group first page is bounded');
SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM group_page_one
      UNION ALL
      SELECT id FROM group_page_two
    ) pages
  ),
  20::BIGINT,
  'Group timestamp ties use UUID without duplicate or skip'
);

SELECT ok(
  public.has_sent_post_linked_card(
    '10800000-0000-4000-8000-000000000001'::UUID,
    'secondhand',
    '10890000-0000-4000-8000-000000000001'::UUID
  ),
  'Linked-card lookup finds the authenticated sender exact card'
);
SELECT ok(
  NOT public.has_sent_post_linked_card(
    '10800000-0000-4000-8000-000000000001'::UUID,
    'forum',
    '10890000-0000-4000-8000-000000000002'::UUID
  ),
  'Linked-card lookup does not treat another sender card as own'
);
SELECT ok(
  NOT public.has_sent_post_linked_card(
    '10800000-0000-4000-8000-000000000001'::UUID,
    'secondhand',
    '10890000-0000-4000-8000-000000000003'::UUID
  ),
  'Linked-card lookup ignores deleted messages'
);

SELECT throws_like(
  $$SELECT * FROM public.get_direct_messages_page(
    '10800000-0000-4000-8000-000000000001'::UUID,
    NOW(), NULL, 10
  )$$,
  '%cursor must be complete%',
  'Direct history rejects a partial cursor'
);

SELECT throws_like(
  $$SELECT * FROM public.get_group_messages_page(
    '10820000-0000-4000-8000-000000000001'::UUID,
    NULL, NULL, 101
  )$$,
  '%p_limit must be between 1 and 100%',
  'Group history rejects an unbounded limit'
);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000003',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  TRUE
);

SELECT throws_like(
  $$SELECT * FROM public.get_direct_messages_page(
    '10800000-0000-4000-8000-000000000001'::UUID,
    NULL, NULL, 10
  )$$,
  '%access denied%',
  'Non-participant cannot read direct history'
);
SELECT throws_like(
  $$SELECT * FROM public.get_group_messages_page(
    '10820000-0000-4000-8000-000000000001'::UUID,
    NULL, NULL, 10
  )$$,
  '%access denied%',
  'Non-member cannot read group history'
);
SELECT throws_like(
  $$SELECT public.has_sent_post_linked_card(
    '10800000-0000-4000-8000-000000000001'::UUID,
    'secondhand',
    '10890000-0000-4000-8000-000000000001'::UUID
  )$$,
  '%access denied%',
  'Non-participant cannot probe linked-card presence'
);

RESET ROLE;

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.get_direct_messages_page(uuid,timestamptz,uuid,integer)',
    'EXECUTE'
  ),
  'Anonymous role cannot execute direct history API'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.has_sent_post_linked_card(uuid,text,uuid)',
    'EXECUTE'
  ),
  'Anonymous role cannot execute linked-card lookup'
);

SELECT * FROM finish();
ROLLBACK;
