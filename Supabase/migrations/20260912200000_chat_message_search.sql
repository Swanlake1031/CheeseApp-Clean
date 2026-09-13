-- Inbox search across historical direct and group messages.
-- Results are restricted to rooms visible to auth.uid() and respect each
-- user's hidden-message records, so the client never receives inaccessible
-- history while searching.

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE INDEX IF NOT EXISTS messages_content_search_idx
  ON public.messages USING gin (content extensions.gin_trgm_ops)
  WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS group_messages_content_search_idx
  ON public.group_messages USING gin (content extensions.gin_trgm_ops)
  WHERE is_deleted = FALSE;

CREATE OR REPLACE FUNCTION public.search_chat_messages(
  p_query TEXT,
  p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
  message_id UUID,
  conversation_id UUID,
  group_id UUID,
  content TEXT,
  message_type TEXT,
  created_at TIMESTAMPTZ,
  sender_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_query TEXT := btrim(COALESCE(p_query, ''));
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF v_query = '' THEN
    RETURN;
  END IF;

  IF length(v_query) > 120 THEN
    RAISE EXCEPTION 'search query is too long' USING ERRCODE = '22023';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;

  -- Escape wildcard characters so a search for "%" or "_" remains a
  -- literal text search rather than turning into a full-table match.
  v_query := replace(
    replace(
      replace(v_query, chr(92), chr(92) || chr(92)),
      '%',
      chr(92) || '%'
    ),
    '_',
    chr(92) || '_'
  );

  RETURN QUERY
  WITH matching_messages AS (
    SELECT
      message.id AS message_id,
      message.conversation_id,
      NULL::UUID AS group_id,
      message.content,
      message.message_type,
      message.created_at,
      CASE
        WHEN conversation.user1_id = v_user_id
        THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
        ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
      END AS sender_name
    FROM public.messages message
    JOIN public.conversations conversation
      ON conversation.id = message.conversation_id
    LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
    LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
    WHERE v_user_id IN (conversation.user1_id, conversation.user2_id)
      AND message.is_deleted = FALSE
      AND message.created_at >= COALESCE(
        (
          SELECT settings.clear_before_at
          FROM public.user_conversation_settings settings
          WHERE settings.user_id = v_user_id
            AND settings.conversation_id = message.conversation_id
        ),
        '-infinity'::TIMESTAMPTZ
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.hidden_chat_messages hidden
        WHERE hidden.user_id = v_user_id
          AND hidden.direct_message_id = message.id
      )
      AND message.content ILIKE '%' || v_query || '%' ESCAPE chr(92)

    UNION ALL

    SELECT
      message.id AS message_id,
      NULL::UUID AS conversation_id,
      message.group_id,
      message.content,
      message.message_type,
      message.created_at,
      COALESCE(NULLIF(profile.full_name, ''), '已注销') AS sender_name
    FROM public.group_messages message
    JOIN public.chat_group_members membership
      ON membership.group_id = message.group_id
     AND membership.user_id = v_user_id
    LEFT JOIN public.profiles profile ON profile.id = message.sender_id
    WHERE message.is_deleted = FALSE
      AND message.created_at >= COALESCE(
        (
          SELECT settings.clear_before_at
          FROM public.user_chat_group_settings settings
          WHERE settings.user_id = v_user_id
            AND settings.group_id = message.group_id
        ),
        '-infinity'::TIMESTAMPTZ
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.hidden_chat_messages hidden
        WHERE hidden.user_id = v_user_id
          AND hidden.group_message_id = message.id
      )
      AND message.content ILIKE '%' || v_query || '%' ESCAPE chr(92)
  )
  SELECT *
  FROM matching_messages AS result_row
  ORDER BY result_row.created_at DESC, result_row.message_id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.search_chat_messages(TEXT, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_chat_messages(TEXT, INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
