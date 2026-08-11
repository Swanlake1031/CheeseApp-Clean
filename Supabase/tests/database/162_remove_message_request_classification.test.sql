BEGIN;

SELECT plan(4);

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

DELETE FROM public.user_follows
WHERE (follower_id, following_id) IN (
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
  '162a0000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002'
);

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type
)
VALUES
  (
    '162a0000-0000-4000-8000-000000000002',
    '162a0000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'first direct message',
    'text'
  ),
  (
    '162a0000-0000-4000-8000-000000000003',
    '162a0000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'second direct message',
    'text'
  );

SELECT ok(
  to_regprocedure('public.get_user_message_requests(uuid)') IS NULL,
  'the separate request-list RPC is removed'
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
    FROM public.get_user_conversations(
      '00000000-0000-0000-0000-000000000001'::UUID
    )
    WHERE id = '162a0000-0000-4000-8000-000000000001'::UUID
  ),
  1::BIGINT,
  'every direct conversation remains in the unified inbox'
);

SELECT is(
  public.can_send_direct_message(
    '162a0000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID
  ),
  TRUE,
  'a participant can continue sending without a reciprocal follow or reply'
);

RESET ROLE;

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001'
);

SET LOCAL ROLE authenticated;

SELECT is(
  public.can_send_direct_message(
    '162a0000-0000-4000-8000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID
  ),
  FALSE,
  'blocking still prevents direct-message sends'
);

SELECT * FROM finish();
ROLLBACK;
