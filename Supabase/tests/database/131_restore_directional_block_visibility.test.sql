BEGIN;

SELECT plan(8);

DELETE FROM public.user_blocks
WHERE (blocker_id, blocked_id) IN (
  (
    '00000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID
  ),
  (
    '00000000-0000-0000-0000-000000000002'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID
  )
);

DELETE FROM public.conversations
WHERE (user1_id, user2_id) = (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.conversations (id, user1_id, user2_id)
VALUES (
  '131a0000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002'
);

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type
)
VALUES (
  '131a0000-0000-4000-8000-000000000002',
  '131a0000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'request created before block',
  'text'
);

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002'
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
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000002'::UUID
  ),
  1::BIGINT,
  'the blocker can still identify the blocked profile'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_user_conversations(
      '00000000-0000-0000-0000-000000000001'::UUID
    )
    WHERE id = '131a0000-0000-4000-8000-000000000001'::UUID
  ),
  1::BIGINT,
  'blocking does not remove an existing conversation from the blocker inbox'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_user_message_requests(
      '00000000-0000-0000-0000-000000000001'::UUID
    )
    WHERE id = '131a0000-0000-4000-8000-000000000001'::UUID
  ),
  1::BIGINT,
  'blocking does not erase an existing message request'
);

SELECT is(
  public.can_send_direct_message(
    '131a0000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID
  ),
  FALSE,
  'the blocker cannot send while the block relation exists'
);

SELECT throws_like(
  $$SELECT * FROM public.get_user_conversations(
    '00000000-0000-0000-0000-000000000002'::UUID
  )$$,
  '%identity mismatch%',
  'conversation retention does not weaken caller identity binding'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'the blocked account cannot read the blocker public profile'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_user_conversations(
      '00000000-0000-0000-0000-000000000002'::UUID
    )
    WHERE id = '131a0000-0000-4000-8000-000000000001'::UUID
  ),
  1::BIGINT,
  'blocking does not remove existing history from the blocked account inbox'
);

SELECT is(
  public.can_send_direct_message(
    '131a0000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID
  ),
  FALSE,
  'the blocked account cannot send while the block relation exists'
);

SELECT * FROM finish();
ROLLBACK;
