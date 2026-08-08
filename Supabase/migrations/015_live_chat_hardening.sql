-- ============================================
-- 015_live_chat_hardening.sql
-- Live chat stability hardening
-- ============================================

-- 1) More defensive get_or_create_conversation
CREATE OR REPLACE FUNCTION public.get_or_create_conversation(
  p_user_id UUID,
  p_other_user_id UUID,
  p_related_post_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_conversation_id UUID;
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  IF p_user_id IS NULL OR p_other_user_id IS NULL THEN
    RAISE EXCEPTION 'Both users are required.';
  END IF;

  IF p_user_id = p_other_user_id THEN
    RAISE EXCEPTION 'Cannot create conversation with self.';
  END IF;

  IF p_user_id < p_other_user_id THEN
    v_user1_id := p_user_id;
    v_user2_id := p_other_user_id;
  ELSE
    v_user1_id := p_other_user_id;
    v_user2_id := p_user_id;
  END IF;

  SELECT id
    INTO v_conversation_id
  FROM public.conversations
  WHERE user1_id = v_user1_id
    AND user2_id = v_user2_id
  LIMIT 1;

  IF v_conversation_id IS NULL THEN
    INSERT INTO public.conversations (user1_id, user2_id, related_post_id)
    VALUES (v_user1_id, v_user2_id, p_related_post_id)
    RETURNING id INTO v_conversation_id;
  ELSIF p_related_post_id IS NOT NULL THEN
    UPDATE public.conversations
    SET related_post_id = COALESCE(related_post_id, p_related_post_id),
        updated_at = NOW()
    WHERE id = v_conversation_id;
  END IF;

  RETURN v_conversation_id;
END;
$$;

-- 2) Deterministic conversation list payload for app
CREATE OR REPLACE FUNCTION public.get_user_conversations(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  related_post_id UUID,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  unread_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END AS other_user_id,
    CASE
      WHEN c.user1_id = p_user_id THEN COALESCE(NULLIF(p2.full_name, ''), split_part(p2.email, '@', 1), 'User')
      ELSE COALESCE(NULLIF(p1.full_name, ''), split_part(p1.email, '@', 1), 'User')
    END AS other_user_name,
    CASE WHEN c.user1_id = p_user_id THEN p2.avatar_url ELSE p1.avatar_url END AS other_user_avatar,
    c.related_post_id,
    c.last_message_at,
    c.last_message_preview,
    CASE WHEN c.user1_id = p_user_id THEN c.user1_unread_count ELSE c.user2_unread_count END AS unread_count
  FROM public.conversations c
  JOIN public.profiles p1 ON p1.id = c.user1_id
  JOIN public.profiles p2 ON p2.id = c.user2_id
  WHERE c.user1_id = p_user_id OR c.user2_id = p_user_id
  ORDER BY c.last_message_at DESC;
END;
$$;

-- 3) Safe mark-as-read behavior
CREATE OR REPLACE FUNCTION public.mark_messages_as_read(
  p_conversation_id UUID,
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  SELECT user1_id, user2_id
    INTO v_user1_id, v_user2_id
  FROM public.conversations
  WHERE id = p_conversation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF p_user_id != v_user1_id AND p_user_id != v_user2_id THEN
    RETURN;
  END IF;

  UPDATE public.messages
  SET is_read = TRUE,
      read_at = NOW()
  WHERE conversation_id = p_conversation_id
    AND sender_id != p_user_id
    AND is_read = FALSE;

  IF p_user_id = v_user1_id THEN
    UPDATE public.conversations
    SET user1_unread_count = 0, updated_at = NOW()
    WHERE id = p_conversation_id;
  ELSE
    UPDATE public.conversations
    SET user2_unread_count = 0, updated_at = NOW()
    WHERE id = p_conversation_id;
  END IF;
END;
$$;

-- 4) Performance indexes for list + room
CREATE INDEX IF NOT EXISTS conversations_related_post_idx
  ON public.conversations (related_post_id);

CREATE INDEX IF NOT EXISTS messages_conversation_created_asc_idx
  ON public.messages (conversation_id, created_at);

-- 5) Realtime publication safety (idempotent)
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END
$$;

-- 6) Grants for authenticated app calls
GRANT EXECUTE ON FUNCTION public.get_or_create_conversation(UUID, UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(UUID, UUID) TO authenticated, service_role;

-- 7) Keep mutable search_path warnings away for all public plpgsql functions
DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_catalog.pg_get_function_identity_arguments(p.oid) AS function_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname = 'public'
      AND l.lanname = 'plpgsql'
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path = public, auth, extensions;',
      fn.schema_name,
      fn.function_name,
      fn.function_args
    );
  END LOOP;
END
$$;

NOTIFY pgrst, 'reload schema';
