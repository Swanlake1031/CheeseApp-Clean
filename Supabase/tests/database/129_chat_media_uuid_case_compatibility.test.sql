BEGIN;

SELECT plan(3);

DELETE FROM public.conversations
WHERE (user1_id, user2_id) = (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.conversations (id, user1_id, user2_id)
VALUES (
  '129a0000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002'
);

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '129a0000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'UUID compatibility group'
)
ON CONFLICT DO NOTHING;

SELECT lives_ok(
  $$
    INSERT INTO public.messages (
      conversation_id, sender_id, content, message_type, metadata
    ) VALUES (
      '129a0000-0000-4000-8000-000000000001',
      '00000000-0000-0000-0000-000000000001',
      'private direct image',
      'image',
      '{
        "image_bucket":"chat-images",
        "image_object_path":"direct/129a0000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/129a0000-0000-4000-8000-000000000003.jpg",
        "image_scope":"direct",
        "image_scope_id":"129A0000-0000-4000-8000-000000000001"
      }'::JSONB
    )
  $$,
  'direct image metadata accepts the supported uppercase UUID representation'
);

SELECT lives_ok(
  $$
    INSERT INTO public.group_messages (
      group_id, sender_id, content, message_type, metadata
    ) VALUES (
      '129a0000-0000-4000-8000-000000000002',
      '00000000-0000-0000-0000-000000000001',
      'private group image',
      'image',
      '{
        "image_bucket":"chat-images",
        "image_object_path":"group/129a0000-0000-4000-8000-000000000002/00000000-0000-0000-0000-000000000001/129a0000-0000-4000-8000-000000000004.jpg",
        "image_scope":"group",
        "image_scope_id":"129A0000-0000-4000-8000-000000000002"
      }'::JSONB
    )
  $$,
  'group image metadata accepts the supported uppercase UUID representation'
);

SELECT throws_ok(
  $$
    INSERT INTO public.messages (
      conversation_id, sender_id, content, message_type, metadata
    ) VALUES (
      '129a0000-0000-4000-8000-000000000001',
      '00000000-0000-0000-0000-000000000001',
      'wrong conversation image',
      'image',
      '{
        "image_bucket":"chat-images",
        "image_object_path":"direct/129a0000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/129a0000-0000-4000-8000-000000000005.jpg",
        "image_scope":"direct",
        "image_scope_id":"129A0000-0000-4000-8000-000000000099"
      }'::JSONB
    )
  $$,
  '23514',
  NULL,
  'case compatibility does not weaken conversation scoping'
);

SELECT * FROM finish();
ROLLBACK;
