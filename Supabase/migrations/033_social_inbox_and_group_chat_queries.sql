-- 033_social_inbox_and_group_chat_queries.sql
-- Social summary + stranger inbox + group chat query helpers

-- ============================================
-- Profile social summary
-- ============================================
CREATE OR REPLACE FUNCTION public.get_profile_social_summary(p_target_user_id UUID)
RETURNS TABLE (
  follower_count INTEGER,
  following_count INTEGER,
  am_following BOOLEAN,
  follows_me BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT
    COALESCE((SELECT COUNT(*)::INT FROM public.user_follows uf WHERE uf.following_id = p_target_user_id), 0) AS follower_count,
    COALESCE((SELECT COUNT(*)::INT FROM public.user_follows uf WHERE uf.follower_id = p_target_user_id), 0) AS following_count,
    CASE
      WHEN v_me IS NULL THEN FALSE
      ELSE EXISTS (
        SELECT 1
        FROM public.user_follows uf
        WHERE uf.follower_id = v_me
          AND uf.following_id = p_target_user_id
      )
    END AS am_following,
    CASE
      WHEN v_me IS NULL THEN FALSE
      ELSE EXISTS (
        SELECT 1
        FROM public.user_follows uf
        WHERE uf.follower_id = p_target_user_id
          AND uf.following_id = v_me
      )
    END AS follows_me,
    CASE
      WHEN v_me IS NULL THEN FALSE
      ELSE public.is_mutual_follow(v_me, p_target_user_id)
    END AS is_mutual_follow;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_social_summary(UUID)
  TO authenticated, service_role;

-- ============================================
-- Stranger message requests (direct chats only)
-- ============================================
CREATE OR REPLACE FUNCTION public.get_user_message_requests(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  related_post_id UUID,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  unread_count INTEGER,
  can_chat_freely BOOLEAN,
  is_mutual_follow BOOLEAN
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
      WHEN c.user1_id = p_user_id THEN COALESCE(NULLIF(p2.full_name, ''), split_part(p2.email, '@', 1), '用户')
      ELSE COALESCE(NULLIF(p1.full_name, ''), split_part(p1.email, '@', 1), '用户')
    END AS other_user_name,
    CASE WHEN c.user1_id = p_user_id THEN p2.avatar_url ELSE p1.avatar_url END AS other_user_avatar,
    c.related_post_id,
    c.last_message_at,
    c.last_message_preview,
    CASE WHEN c.user1_id = p_user_id THEN c.user1_unread_count ELSE c.user2_unread_count END AS unread_count,
    FALSE AS can_chat_freely,
    FALSE AS is_mutual_follow
  FROM public.conversations c
  JOIN public.profiles p1 ON p1.id = c.user1_id
  JOIN public.profiles p2 ON p2.id = c.user2_id
  WHERE (c.user1_id = p_user_id OR c.user2_id = p_user_id)
    AND NOT public.is_mutual_follow(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    )
    AND EXISTS (
      SELECT 1
      FROM public.messages m_in
      WHERE m_in.conversation_id = c.id
        AND m_in.sender_id = CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
        AND COALESCE(m_in.is_deleted, FALSE) = FALSE
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.messages m_out
      WHERE m_out.conversation_id = c.id
        AND m_out.sender_id = p_user_id
        AND COALESCE(m_out.is_deleted, FALSE) = FALSE
    )
  ORDER BY c.last_message_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_message_requests(UUID)
  TO authenticated, service_role;

-- ============================================
-- Mutual follow candidates for group creation
-- ============================================
CREATE OR REPLACE FUNCTION public.get_mutual_follow_profiles(
  p_user_id UUID,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    p.id,
    COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS full_name,
    p.avatar_url,
    p.university
  FROM public.user_follows f_out
  JOIN public.user_follows f_back
    ON f_out.following_id = f_back.follower_id
   AND f_out.follower_id = f_back.following_id
  JOIN public.profiles p
    ON p.id = f_out.following_id
  WHERE f_out.follower_id = p_user_id
    AND p.id <> p_user_id
  ORDER BY p.verified DESC, p.updated_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
$$;

GRANT EXECUTE ON FUNCTION public.get_mutual_follow_profiles(UUID, INTEGER)
  TO authenticated, service_role;

-- ============================================
-- Group chat list payload
-- ============================================
CREATE OR REPLACE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER
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
    COALESCE(member_stats.member_count, 1) AS member_count
  FROM public.chat_groups g
  JOIN public.chat_group_members me
    ON me.group_id = g.id
   AND me.user_id = p_user_id
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
  ORDER BY COALESCE(last_msg.created_at, g.updated_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID)
  TO authenticated, service_role;

-- ============================================
-- Group message view with sender profile
-- ============================================
CREATE OR REPLACE VIEW public.group_messages_view AS
SELECT
  gm.id,
  gm.group_id,
  gm.sender_id,
  gm.content,
  gm.message_type,
  gm.metadata,
  gm.is_deleted,
  gm.created_at,
  COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS sender_name,
  p.avatar_url AS sender_avatar
FROM public.group_messages gm
JOIN public.profiles p
  ON p.id = gm.sender_id;

GRANT SELECT ON public.group_messages_view TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
