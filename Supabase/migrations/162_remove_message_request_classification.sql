-- 162_remove_message_request_classification.sql
--
-- Direct conversations now share one inbox and one send policy. This removes
-- the derived "message request" category and its one-message reply gate while
-- retaining participant validation and bidirectional blocking.

BEGIN;

DROP FUNCTION IF EXISTS public.get_user_message_requests(UUID);
DROP FUNCTION IF EXISTS public.get_user_conversations(UUID);

CREATE FUNCTION public.get_user_conversations(p_user_id UUID)
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
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    conversation.id,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user2_id
      ELSE conversation.user1_id
    END,
    CASE
      WHEN conversation.user1_id = v_me
      THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
      ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
    END,
    CASE
      WHEN conversation.user1_id = v_me THEN profile2.avatar_url
      ELSE profile1.avatar_url
    END,
    conversation.related_post_id,
    conversation.last_message_at,
    conversation.last_message_preview,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user1_unread_count
      ELSE conversation.user2_unread_count
    END
  FROM public.conversations conversation
  LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
  LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
  WHERE conversation.user1_id = v_me OR conversation.user2_id = v_me
  ORDER BY conversation.last_message_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_user_conversations(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.can_send_direct_message(
  p_conversation_id UUID,
  p_sender_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
  v_other UUID;
BEGIN
  SELECT conversation.user1_id, conversation.user2_id
    INTO v_user1, v_user2
  FROM public.conversations conversation
  WHERE conversation.id = p_conversation_id;

  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_sender_id <> v_user1 AND p_sender_id <> v_user2 THEN
    RETURN FALSE;
  END IF;

  v_other := CASE WHEN p_sender_id = v_user1 THEN v_user2 ELSE v_user1 END;
  RETURN NOT public.is_user_blocked(p_sender_id, v_other);
END;
$$;

REVOKE ALL ON FUNCTION public.can_send_direct_message(UUID, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.can_send_direct_message(UUID, UUID) IS
  'Allows either conversation participant to send unless either account blocks the other.';

NOTIFY pgrst, 'reload schema';

COMMIT;
