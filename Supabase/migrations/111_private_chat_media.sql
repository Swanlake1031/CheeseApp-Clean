-- Chat media is private and scoped to an active direct conversation or group.
-- New clients store exact bucket/object_path metadata and request short-lived
-- signed URLs; legacy URL-only rows remain untouched but are no longer public.

UPDATE storage.buckets
SET public = FALSE
WHERE id = 'chat-images';

DROP POLICY IF EXISTS "Public can view chat images" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated can upload chat images" ON storage.objects;
DROP POLICY IF EXISTS "Users can update own chat images" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete own chat images" ON storage.objects;

CREATE OR REPLACE FUNCTION public.can_access_chat_media_object(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_parts TEXT[];
  v_scope_id UUID;
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL OR p_name IS NULL THEN
    RETURN FALSE;
  END IF;

  v_parts := string_to_array(p_name, '/');
  IF array_length(v_parts, 1) <> 4
     OR v_parts[1] NOT IN ('direct', 'group')
     OR v_parts[2] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_parts[3] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_parts[4] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  THEN
    RETURN FALSE;
  END IF;

  v_scope_id := v_parts[2]::UUID;
  IF v_parts[1] = 'direct' THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.conversations conversation
      WHERE conversation.id = v_scope_id
        AND v_user_id IN (conversation.user1_id, conversation.user2_id)
    );
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.chat_group_members member
    WHERE member.group_id = v_scope_id
      AND member.user_id = v_user_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_write_chat_media_object(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_parts TEXT[];
BEGIN
  IF NOT public.can_access_chat_media_object(p_name) THEN
    RETURN FALSE;
  END IF;

  v_parts := string_to_array(p_name, '/');
  RETURN v_parts[3] = auth.uid()::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.can_access_chat_media_object(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_write_chat_media_object(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_access_chat_media_object(TEXT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_write_chat_media_object(TEXT)
  TO authenticated, service_role;

CREATE POLICY "Participants can read scoped chat images"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'chat-images'
  AND public.can_access_chat_media_object(name)
);

CREATE POLICY "Participants can upload scoped chat images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'chat-images'
  AND public.can_write_chat_media_object(name)
);

CREATE POLICY "Uploaders can update scoped chat images"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'chat-images'
  AND owner = auth.uid()
  AND public.can_write_chat_media_object(name)
)
WITH CHECK (
  bucket_id = 'chat-images'
  AND owner = auth.uid()
  AND public.can_write_chat_media_object(name)
);

CREATE POLICY "Uploaders can delete scoped chat images"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'chat-images'
  AND owner = auth.uid()
  AND public.can_write_chat_media_object(name)
);

ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_private_chat_media_contract;
ALTER TABLE public.messages
  ADD CONSTRAINT messages_private_chat_media_contract CHECK (
    message_type <> 'image'
    OR (
      sender_id IS NOT NULL
      AND metadata->>'image_bucket' = 'chat-images'
      AND metadata->>'image_scope' = 'direct'
      AND metadata->>'image_scope_id' = conversation_id::TEXT
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
      AND metadata->>'image_scope_id' = group_id::TEXT
      AND metadata->>'image_object_path' LIKE
        'group/' || group_id::TEXT || '/' || sender_id::TEXT || '/%.jpg'
      AND COALESCE(metadata->>'image_url', '') = ''
    )
  ) NOT VALID;

NOTIFY pgrst, 'reload schema';
