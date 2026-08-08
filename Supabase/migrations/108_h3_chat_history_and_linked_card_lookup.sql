-- H3 Phase F: bounded chat history and indexed linked-card duplicate lookup.
--
-- Realtime remains responsible for messages inserted after room bootstrap. These
-- functions only provide stable, older-history pages.

CREATE INDEX IF NOT EXISTS messages_conversation_created_id_page_idx
  ON public.messages (conversation_id, created_at DESC, id DESC)
  WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS group_messages_group_created_id_page_idx
  ON public.group_messages (group_id, created_at DESC, id DESC)
  WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS messages_linked_card_lookup_idx
  ON public.messages (
    conversation_id,
    sender_id,
    ((metadata -> 'post_contact_card' ->> 'post_kind')),
    ((metadata -> 'post_contact_card' ->> 'post_id'))
  )
  WHERE is_deleted = FALSE
    AND metadata ? 'post_contact_card';

CREATE OR REPLACE FUNCTION public.get_direct_messages_page(
  p_conversation_id UUID,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 40
)
RETURNS TABLE (
  id UUID,
  conversation_id UUID,
  sender_id UUID,
  content TEXT,
  message_type TEXT,
  metadata JSONB,
  is_read BOOLEAN,
  created_at TIMESTAMPTZ,
  is_deleted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;

  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'direct message cursor must be complete' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversations c
    WHERE c.id = p_conversation_id
      AND v_user_id IN (c.user1_id, c.user2_id)
  ) THEN
    RAISE EXCEPTION 'conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.conversation_id,
    m.sender_id,
    m.content,
    m.message_type,
    m.metadata,
    m.is_read,
    m.created_at,
    m.is_deleted
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND m.is_deleted = FALSE
    AND (
      p_before_created_at IS NULL
      OR (m.created_at, m.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY m.created_at DESC, m.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_group_messages_page(
  p_group_id UUID,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 40
)
RETURNS TABLE (
  id UUID,
  group_id UUID,
  sender_id UUID,
  content TEXT,
  message_type TEXT,
  metadata JSONB,
  is_deleted BOOLEAN,
  created_at TIMESTAMPTZ,
  sender_name TEXT,
  sender_avatar TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;

  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'group message cursor must be complete' USING ERRCODE = '22023';
  END IF;

  IF NOT public.is_chat_group_member(p_group_id, v_user_id) THEN
    RAISE EXCEPTION 'group access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    gm.id,
    gm.group_id,
    gm.sender_id,
    gm.content,
    gm.message_type,
    gm.metadata,
    gm.is_deleted,
    gm.created_at,
    COALESCE(NULLIF(pr.full_name, ''), '已注销') AS sender_name,
    pr.avatar_url AS sender_avatar
  FROM public.group_messages gm
  LEFT JOIN public.profiles pr ON pr.id = gm.sender_id
  WHERE gm.group_id = p_group_id
    AND gm.is_deleted = FALSE
    AND (
      p_before_created_at IS NULL
      OR (gm.created_at, gm.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY gm.created_at DESC, gm.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.has_sent_post_linked_card(
  p_conversation_id UUID,
  p_post_kind TEXT,
  p_post_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_post_kind NOT IN ('forum', 'secondhand', 'rent') THEN
    RAISE EXCEPTION 'unsupported post kind' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversations c
    WHERE c.id = p_conversation_id
      AND v_user_id IN (c.user1_id, c.user2_id)
  ) THEN
    RAISE EXCEPTION 'conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.sender_id = v_user_id
      AND m.is_deleted = FALSE
      AND m.metadata -> 'post_contact_card' ->> 'post_kind' = p_post_kind
      AND m.metadata -> 'post_contact_card' ->> 'post_id' = p_post_id::TEXT
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_direct_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_group_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_direct_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
