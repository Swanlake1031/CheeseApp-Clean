BEGIN;

SELECT plan(16);

DELETE FROM public.conversations
WHERE (user1_id, user2_id) = (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.conversations (id, user1_id, user2_id)
VALUES (
  '13200000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002'
);

INSERT INTO public.messages (id, conversation_id, sender_id, content, message_type)
VALUES
  (
    '13200000-0000-4000-8000-000000000002',
    '13200000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'sender one direct message',
    'text'
  ),
  (
    '13200000-0000-4000-8000-000000000003',
    '13200000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    'sender two direct message',
    'text'
  );

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '13200000-0000-4000-8000-000000000004',
  '00000000-0000-0000-0000-000000000001',
  'Message actions group'
);

INSERT INTO public.chat_group_members (group_id, user_id, role)
VALUES
  (
    '13200000-0000-4000-8000-000000000004',
    '00000000-0000-0000-0000-000000000001',
    'owner'
  ),
  (
    '13200000-0000-4000-8000-000000000004',
    '00000000-0000-0000-0000-000000000002',
    'member'
  );

INSERT INTO public.group_messages (id, group_id, sender_id, content, message_type)
VALUES (
  '13200000-0000-4000-8000-000000000005',
  '13200000-0000-4000-8000-000000000004',
  '00000000-0000-0000-0000-000000000001',
  'sender one group message',
  'text'
);

SELECT has_table('public', 'hidden_chat_messages', 'per-user hidden messages table exists');
SELECT has_table('public', 'message_reports', 'message moderation reports table exists');
SELECT function_privs_are(
  'public',
  'hide_direct_message_for_me',
  ARRAY['uuid'],
  'authenticated',
  ARRAY['EXECUTE'],
  'authenticated users can invoke direct-message hiding'
);
SELECT function_privs_are(
  'public',
  'delete_own_direct_message',
  ARRAY['uuid'],
  'anon',
  ARRAY[]::TEXT[],
  'anonymous users cannot invoke message deletion'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$SELECT public.hide_direct_message_for_me(
    '13200000-0000-4000-8000-000000000002'::UUID
  )$$,
  'a participant can hide another direct message for themselves'
);

SELECT is(
  (
    SELECT COUNT(*) FROM public.get_direct_messages_page(
      '13200000-0000-4000-8000-000000000001', NULL, NULL, 40
    )
    WHERE id = '13200000-0000-4000-8000-000000000002'
  ),
  0::BIGINT,
  'a locally hidden direct message is absent from that user history'
);

SELECT lives_ok(
  $$SELECT public.hide_group_message_for_me(
    '13200000-0000-4000-8000-000000000005'::UUID
  )$$,
  'a group member can hide another group message for themselves'
);

SELECT is(
  (
    SELECT COUNT(*) FROM public.get_group_messages_page(
      '13200000-0000-4000-8000-000000000004', NULL, NULL, 40
    )
    WHERE id = '13200000-0000-4000-8000-000000000005'
  ),
  0::BIGINT,
  'a locally hidden group message is absent from that user history'
);

SELECT throws_like(
  $$SELECT public.delete_own_direct_message(
    '13200000-0000-4000-8000-000000000002'::UUID
  )$$,
  '%only the sender can delete%',
  'a participant cannot delete another sender message for everyone'
);

SELECT lives_ok(
  $$INSERT INTO public.message_reports (
    reporter_id, direct_message_id, reason, details
  ) VALUES (
    '00000000-0000-0000-0000-000000000002',
    '13200000-0000-4000-8000-000000000002',
    'harassment',
    'message action test'
  )$$,
  'a participant can report another sender message'
);

SELECT throws_like(
  $$INSERT INTO public.message_reports (
    reporter_id, direct_message_id, reason
  ) VALUES (
    '00000000-0000-0000-0000-000000000002',
    '13200000-0000-4000-8000-000000000002',
    'spam'
  )$$,
  '%duplicate key%',
  'the same user cannot report the same message twice'
);

SELECT throws_like(
  $$INSERT INTO public.message_reports (
    reporter_id, direct_message_id, reason
  ) VALUES (
    '00000000-0000-0000-0000-000000000002',
    '13200000-0000-4000-8000-000000000003',
    'other'
  )$$,
  '%row-level security%',
  'a user cannot report their own message'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*) FROM public.get_direct_messages_page(
      '13200000-0000-4000-8000-000000000001', NULL, NULL, 40
    )
    WHERE id = '13200000-0000-4000-8000-000000000002'
  ),
  1::BIGINT,
  'hiding another message does not remove it for the sender'
);

SELECT lives_ok(
  $$SELECT public.delete_own_direct_message(
    '13200000-0000-4000-8000-000000000002'::UUID
  )$$,
  'the sender can delete their direct message for everyone'
);

SELECT lives_ok(
  $$SELECT public.delete_own_group_message(
    '13200000-0000-4000-8000-000000000005'::UUID
  )$$,
  'the sender can delete their group message for everyone'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.messages
    WHERE id = '13200000-0000-4000-8000-000000000002'
      AND is_deleted = TRUE
  ),
  1::BIGINT,
  'sender deletion uses the established soft-delete contract'
);

SELECT * FROM finish();
ROLLBACK;
