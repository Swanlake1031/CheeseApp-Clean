-- 037_block_visibility_and_chatbox_retention.sql
-- Keep blocked chatboxes visible, disable direct-message sending under block relation,
-- and enforce one-way profile/post visibility:
-- - blocker can still view blocked user's profile/posts
-- - blocked user cannot view blocker's profile/posts

-- ============================================
-- Directional helper
-- ============================================
CREATE OR REPLACE FUNCTION public.is_blocked_by(
  p_blocker_id UUID,
  p_viewer_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    CASE
      WHEN p_blocker_id IS NULL OR p_viewer_id IS NULL THEN FALSE
      ELSE EXISTS (
        SELECT 1
        FROM public.user_blocks b
        WHERE b.blocker_id = p_blocker_id
          AND b.blocked_id = p_viewer_id
      )
    END;
$$;

GRANT EXECUTE ON FUNCTION public.is_blocked_by(UUID, UUID) TO authenticated, service_role;

-- ============================================
-- Profile visibility: blocked users cannot read blocker's profile.
-- ============================================
DROP POLICY IF EXISTS "公开资料可以被所有人读取" ON public.profiles;
CREATE POLICY "公开资料可以被所有人读取"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() = id
    OR NOT public.is_blocked_by(id, auth.uid())
  );

-- ============================================
-- Post visibility: blocked users cannot read blocker's active posts.
-- ============================================
DROP POLICY IF EXISTS "活跃帖子公开可见" ON public.posts;
CREATE POLICY "活跃帖子公开可见"
  ON public.posts
  FOR SELECT
  TO authenticated
  USING (
    status = 'active'
    AND (
      auth.uid() = user_id
      OR NOT public.is_blocked_by(user_id, auth.uid())
    )
  );

-- ============================================
-- Keep direct-message send disabled under block relation.
-- ============================================
CREATE OR REPLACE FUNCTION public.can_send_direct_message(
  p_conversation_id UUID,
  p_sender_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public, auth
AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
  v_other UUID;
  v_sent_count INTEGER;
BEGIN
  SELECT c.user1_id, c.user2_id
    INTO v_user1, v_user2
  FROM public.conversations c
  WHERE c.id = p_conversation_id;

  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_sender_id <> v_user1 AND p_sender_id <> v_user2 THEN
    RETURN FALSE;
  END IF;

  v_other := CASE WHEN p_sender_id = v_user1 THEN v_user2 ELSE v_user1 END;

  IF public.is_user_blocked(p_sender_id, v_other) THEN
    RETURN FALSE;
  END IF;

  IF public.is_mutual_follow(p_sender_id, v_other) THEN
    RETURN TRUE;
  END IF;

  SELECT COUNT(*)
    INTO v_sent_count
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND m.sender_id = p_sender_id
    AND COALESCE(m.is_deleted, FALSE) = FALSE;

  RETURN v_sent_count < 1;
END;
$$;

-- ============================================
-- Keep existing conversation retrievable while blocked.
-- A blocked relation only prevents creating brand-new conversations.
-- ============================================
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

  IF v_conversation_id IS NOT NULL THEN
    IF p_related_post_id IS NOT NULL THEN
      UPDATE public.conversations
      SET related_post_id = COALESCE(related_post_id, p_related_post_id),
          updated_at = NOW()
      WHERE id = v_conversation_id;
    END IF;
    RETURN v_conversation_id;
  END IF;

  IF public.is_user_blocked(p_user_id, p_other_user_id) THEN
    RAISE EXCEPTION 'Cannot create conversation while either user is blocked.';
  END IF;

  INSERT INTO public.conversations (user1_id, user2_id, related_post_id)
  VALUES (v_user1_id, v_user2_id, p_related_post_id)
  RETURNING id INTO v_conversation_id;

  RETURN v_conversation_id;
END;
$$;

-- ============================================
-- Keep blocked conversations visible in inbox payloads.
-- ============================================
DROP FUNCTION IF EXISTS public.get_user_conversations(UUID);

CREATE OR REPLACE FUNCTION public.get_user_conversations(p_user_id UUID)
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
    public.is_mutual_follow(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    ) AS can_chat_freely,
    public.is_mutual_follow(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    ) AS is_mutual_follow
  FROM public.conversations c
  JOIN public.profiles p1 ON p1.id = c.user1_id
  JOIN public.profiles p2 ON p2.id = c.user2_id
  WHERE (c.user1_id = p_user_id OR c.user2_id = p_user_id)
  ORDER BY c.last_message_at DESC;
END;
$$;

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

GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_or_create_conversation(UUID, UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_message_requests(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
