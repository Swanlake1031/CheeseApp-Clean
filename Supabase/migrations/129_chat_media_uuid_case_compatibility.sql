-- Keep the private chat-media contract strict while accepting the UUID text
-- representation emitted by supported clients. Foundation's synthesized UUID
-- encoding uses uppercase hexadecimal digits; PostgreSQL uuid::text and the
-- canonical Storage object path use lowercase digits.

BEGIN;

ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_private_chat_media_contract;
ALTER TABLE public.messages
  ADD CONSTRAINT messages_private_chat_media_contract CHECK (
    message_type <> 'image'
    OR (
      sender_id IS NOT NULL
      AND metadata->>'image_bucket' = 'chat-images'
      AND metadata->>'image_scope' = 'direct'
      AND lower(metadata->>'image_scope_id') = conversation_id::TEXT
      AND metadata->>'image_object_path' LIKE
        'direct/' || conversation_id::TEXT || '/' || sender_id::TEXT || '/%.jpg'
      AND COALESCE(metadata->>'image_url', '') = ''
    )
  ) NOT VALID;

ALTER TABLE public.group_messages
  DROP CONSTRAINT IF EXISTS group_messages_private_chat_media_contract;
ALTER TABLE public.group_messages
  ADD CONSTRAINT group_messages_private_chat_media_contract CHECK (
    message_type <> 'image'
    OR (
      metadata->>'image_bucket' = 'chat-images'
      AND metadata->>'image_scope' = 'group'
      AND lower(metadata->>'image_scope_id') = group_id::TEXT
      AND metadata->>'image_object_path' LIKE
        'group/' || group_id::TEXT || '/' || sender_id::TEXT || '/%.jpg'
      AND COALESCE(metadata->>'image_url', '') = ''
    )
  ) NOT VALID;

NOTIFY pgrst, 'reload schema';

COMMIT;
