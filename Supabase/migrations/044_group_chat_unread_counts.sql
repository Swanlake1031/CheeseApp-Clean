-- 044_group_chat_unread_counts.sql
-- Add per-user group last-read marker and expose unread_count in group list payload

BEGIN;

ALTER TABLE public.user_chat_group_settings
  ADD COLUMN IF NOT EXISTS last_read_at TIMESTAMPTZ;

DROP FUNCTION IF EXISTS public.get_user_chat_groups(UUID);

CREATE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER,
  unread_count INTEGER
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    g.id,
    g.name,
    g.avatar_url,
    COALESCE(last_msg.created_at, g.updated_at) AS last_message_at,
    last_msg.preview AS last_message_preview,
    COALESCE(member_stats.member_count, 1) AS member_count,
    COALESCE(unread_stats.unread_count, 0) AS unread_count
  FROM public.chat_groups g
  JOIN public.chat_group_members me
    ON me.group_id = g.id
   AND me.user_id = p_user_id
  LEFT JOIN public.user_chat_group_settings ugs
    ON ugs.group_id = g.id
   AND ugs.user_id = p_user_id
  LEFT JOIN LATERAL (
    SELECT
      gm.created_at,
      CASE
        WHEN gm.message_type = 'image' THEN '📷 Photo'
        ELSE LEFT(gm.content, 120)
      END AS preview
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
    ORDER BY gm.created_at DESC
    LIMIT 1
  ) last_msg ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS member_count
    FROM public.chat_group_members gm
    WHERE gm.group_id = g.id
  ) member_stats ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS unread_count
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
      AND gm.sender_id <> p_user_id
      AND gm.created_at > COALESCE(ugs.last_read_at, me.created_at, 'epoch'::timestamptz)
  ) unread_stats ON TRUE
  ORDER BY COALESCE(last_msg.created_at, g.updated_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
