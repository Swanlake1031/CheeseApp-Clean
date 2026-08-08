-- 035_chat_privacy_controls.sql
-- Direct-chat privacy controls:
-- - block/unblock users
-- - per-conversation mute + clear-before marker
-- - user reports for chat safety
-- - enforce block relation on direct messaging RPCs/policies

-- ============================================
-- Block list
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_blocks (
  blocker_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT user_blocks_not_self CHECK (blocker_id <> blocked_id)
);

CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx
  ON public.user_blocks(blocked_id, blocked_at DESC);

ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read block relations involving self" ON public.user_blocks;
CREATE POLICY "Users can read block relations involving self"
  ON public.user_blocks
  FOR SELECT
  TO authenticated
  USING (auth.uid() = blocker_id OR auth.uid() = blocked_id);

DROP POLICY IF EXISTS "Users can block as self" ON public.user_blocks;
CREATE POLICY "Users can block as self"
  ON public.user_blocks
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = blocker_id);

DROP POLICY IF EXISTS "Users can unblock as self" ON public.user_blocks;
CREATE POLICY "Users can unblock as self"
  ON public.user_blocks
  FOR DELETE
  TO authenticated
  USING (auth.uid() = blocker_id);

GRANT SELECT, INSERT, DELETE ON public.user_blocks TO authenticated, service_role;

-- ============================================
-- Per-user conversation settings
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_conversation_settings (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  is_muted BOOLEAN NOT NULL DEFAULT FALSE,
  clear_before_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, conversation_id)
);

CREATE INDEX IF NOT EXISTS user_conversation_settings_conversation_idx
  ON public.user_conversation_settings(conversation_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.touch_user_conversation_settings_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_conversation_settings_updated_at ON public.user_conversation_settings;
CREATE TRIGGER trg_user_conversation_settings_updated_at
BEFORE UPDATE ON public.user_conversation_settings
FOR EACH ROW
EXECUTE FUNCTION public.touch_user_conversation_settings_updated_at();

ALTER TABLE public.user_conversation_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own conversation settings" ON public.user_conversation_settings;
CREATE POLICY "Users can read own conversation settings"
  ON public.user_conversation_settings
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own conversation settings" ON public.user_conversation_settings;
CREATE POLICY "Users can insert own conversation settings"
  ON public.user_conversation_settings
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own conversation settings" ON public.user_conversation_settings;
CREATE POLICY "Users can update own conversation settings"
  ON public.user_conversation_settings
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own conversation settings" ON public.user_conversation_settings;
CREATE POLICY "Users can delete own conversation settings"
  ON public.user_conversation_settings
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_conversation_settings TO authenticated, service_role;

-- ============================================
-- User reports
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reported_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL,
  reason TEXT NOT NULL CHECK (btrim(reason) <> ''),
  details TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS user_reports_reported_idx
  ON public.user_reports(reported_user_id, created_at DESC);

ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can submit own reports" ON public.user_reports;
CREATE POLICY "Users can submit own reports"
  ON public.user_reports
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = reporter_id);

DROP POLICY IF EXISTS "Users can read own reports" ON public.user_reports;
CREATE POLICY "Users can read own reports"
  ON public.user_reports
  FOR SELECT
  TO authenticated
  USING (auth.uid() = reporter_id);

GRANT SELECT, INSERT ON public.user_reports TO authenticated, service_role;

-- ============================================
-- Block relation helpers
-- ============================================
CREATE OR REPLACE FUNCTION public.is_user_blocked(p_user_a UUID, p_user_b UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    CASE
      WHEN p_user_a IS NULL OR p_user_b IS NULL THEN FALSE
      ELSE EXISTS (
        SELECT 1
        FROM public.user_blocks b
        WHERE (b.blocker_id = p_user_a AND b.blocked_id = p_user_b)
           OR (b.blocker_id = p_user_b AND b.blocked_id = p_user_a)
      )
    END;
$$;

CREATE OR REPLACE FUNCTION public.get_blocked_users(p_user_id UUID)
RETURNS TABLE (
  blocked_user_id UUID,
  blocked_user_name TEXT,
  blocked_user_avatar TEXT,
  blocked_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR v_me <> p_user_id THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  RETURN QUERY
  SELECT
    b.blocked_id AS blocked_user_id,
    COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS blocked_user_name,
    p.avatar_url AS blocked_user_avatar,
    b.blocked_at
  FROM public.user_blocks b
  JOIN public.profiles p
    ON p.id = b.blocked_id
  WHERE b.blocker_id = p_user_id
  ORDER BY b.blocked_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_user_blocked(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_blocked_users(UUID) TO authenticated, service_role;

-- ============================================
-- Enforce block relation in direct messaging
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

  IF public.is_user_blocked(p_user_id, p_other_user_id) THEN
    RAISE EXCEPTION 'Cannot create conversation while either user is blocked.';
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

-- ============================================
-- Exclude blocked relations from inbox payloads
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
    AND NOT public.is_user_blocked(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    )
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
    AND NOT public.is_user_blocked(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    )
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
