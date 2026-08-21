-- 175_group_nickname_display.sql
-- Make per-group nicknames the canonical sender display name inside that group.

BEGIN;

CREATE OR REPLACE VIEW public.group_messages_view AS
SELECT
  message.id,
  message.group_id,
  message.sender_id,
  message.content,
  message.message_type,
  message.metadata,
  message.is_deleted,
  message.created_at,
  COALESCE(
    NULLIF(btrim(membership.nickname), ''),
    NULLIF(btrim(profile.full_name), ''),
    '已注销'
  ) AS sender_name,
  profile.avatar_url AS sender_avatar
FROM public.group_messages message
LEFT JOIN public.chat_group_members membership
  ON membership.group_id = message.group_id
 AND membership.user_id = message.sender_id
LEFT JOIN public.profile_public_view profile ON profile.id = message.sender_id;

ALTER VIEW public.group_messages_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.group_messages_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.group_messages_view TO authenticated, service_role;

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
    message.id,
    message.group_id,
    message.sender_id,
    message.content,
    message.message_type,
    message.metadata,
    message.is_deleted,
    message.created_at,
    COALESCE(
      NULLIF(btrim(membership.nickname), ''),
      NULLIF(btrim(profile.full_name), ''),
      '已注销'
    ) AS sender_name,
    profile.avatar_url AS sender_avatar
  FROM public.group_messages message
  LEFT JOIN public.chat_group_members membership
    ON membership.group_id = message.group_id
   AND membership.user_id = message.sender_id
  LEFT JOIN public.profiles profile ON profile.id = message.sender_id
  WHERE message.group_id = p_group_id
    AND message.is_deleted = FALSE
    AND NOT EXISTS (
      SELECT 1 FROM public.hidden_chat_messages hidden
      WHERE hidden.user_id = v_user_id
        AND hidden.group_message_id = message.id
    )
    AND (
      p_before_created_at IS NULL
      OR (message.created_at, message.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT p_limit;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_group_members'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_group_members;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.get_group_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_group_messages_page(UUID, TIMESTAMPTZ, UUID, INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
