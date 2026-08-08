-- 028_social_follow_and_direct_chat_rules.sql
-- Follow/friend graph + stranger direct-message limit

-- ============================================
-- Follow graph
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_follows (
  follower_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  following_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (follower_id, following_id),
  CONSTRAINT user_follows_not_self CHECK (follower_id <> following_id)
);

CREATE INDEX IF NOT EXISTS user_follows_following_idx
  ON public.user_follows(following_id, created_at DESC);

ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read follows" ON public.user_follows;
CREATE POLICY "Users can read follows"
  ON public.user_follows
  FOR SELECT
  TO authenticated
  USING (TRUE);

DROP POLICY IF EXISTS "Users can follow as self" ON public.user_follows;
CREATE POLICY "Users can follow as self"
  ON public.user_follows
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = follower_id);

DROP POLICY IF EXISTS "Users can unfollow as self" ON public.user_follows;
CREATE POLICY "Users can unfollow as self"
  ON public.user_follows
  FOR DELETE
  TO authenticated
  USING (auth.uid() = follower_id);

CREATE OR REPLACE FUNCTION public.is_mutual_follow(p_user_a UUID, p_user_b UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_follows f1
    JOIN public.user_follows f2
      ON f1.follower_id = f2.following_id
     AND f1.following_id = f2.follower_id
    WHERE f1.follower_id = p_user_a
      AND f1.following_id = p_user_b
  );
$$;

-- ============================================
-- Direct chat stranger limit helper
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

DROP POLICY IF EXISTS "用户可以在自己的会话中发消息" ON public.messages;
DROP POLICY IF EXISTS "Users can send message in own conversation" ON public.messages;

CREATE POLICY "Users can send message in own conversation with stranger limit"
  ON public.messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND (c.user1_id = auth.uid() OR c.user2_id = auth.uid())
    )
    AND public.can_send_direct_message(messages.conversation_id, auth.uid())
  );

-- Extend conversation payload with mutual-follow flags
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
  WHERE c.user1_id = p_user_id OR c.user2_id = p_user_id
  ORDER BY c.last_message_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_mutual_follow(UUID, UUID)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
