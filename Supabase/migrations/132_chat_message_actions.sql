-- Message actions: per-user hiding, sender deletion, and moderation reports.
-- Sender deletion is a soft delete so existing chat-media cleanup triggers run.

CREATE TABLE public.hidden_chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  direct_message_id UUID REFERENCES public.messages(id) ON DELETE CASCADE,
  group_message_id UUID REFERENCES public.group_messages(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT hidden_chat_messages_one_subject CHECK (
    num_nonnulls(direct_message_id, group_message_id) = 1
  )
);

CREATE UNIQUE INDEX hidden_chat_messages_direct_unique
  ON public.hidden_chat_messages(user_id, direct_message_id)
  WHERE direct_message_id IS NOT NULL;

CREATE UNIQUE INDEX hidden_chat_messages_group_unique
  ON public.hidden_chat_messages(user_id, group_message_id)
  WHERE group_message_id IS NOT NULL;

ALTER TABLE public.hidden_chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own hidden chat messages"
  ON public.hidden_chat_messages FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Users can hide chat messages for themselves"
  ON public.hidden_chat_messages FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can restore own hidden chat messages"
  ON public.hidden_chat_messages FOR DELETE TO authenticated
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.hidden_chat_messages TO authenticated, service_role;

CREATE TABLE public.message_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  direct_message_id UUID REFERENCES public.messages(id) ON DELETE CASCADE,
  group_message_id UUID REFERENCES public.group_messages(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (reason IN (
    'spam', 'harassment', 'fraud', 'inappropriate', 'misleading', 'other'
  )),
  details TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'reviewing', 'resolved', 'dismissed'
  )),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT message_reports_one_subject CHECK (
    num_nonnulls(direct_message_id, group_message_id) = 1
  )
);

CREATE UNIQUE INDEX message_reports_direct_unique
  ON public.message_reports(reporter_id, direct_message_id)
  WHERE direct_message_id IS NOT NULL;

CREATE UNIQUE INDEX message_reports_group_unique
  ON public.message_reports(reporter_id, group_message_id)
  WHERE group_message_id IS NOT NULL;

CREATE INDEX message_reports_status_created_idx
  ON public.message_reports(status, created_at DESC);

ALTER TABLE public.message_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can submit visible message reports"
  ON public.message_reports FOR INSERT TO authenticated
  WITH CHECK (
    reporter_id = auth.uid()
    AND (
      (
        direct_message_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM public.messages message
          JOIN public.conversations conversation
            ON conversation.id = message.conversation_id
          WHERE message.id = direct_message_id
            AND message.sender_id IS DISTINCT FROM auth.uid()
            AND auth.uid() IN (conversation.user1_id, conversation.user2_id)
        )
      )
      OR
      (
        group_message_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM public.group_messages message
          WHERE message.id = group_message_id
            AND message.sender_id <> auth.uid()
            AND public.is_chat_group_member(message.group_id, auth.uid())
        )
      )
    )
  );

CREATE POLICY "Users can read own message reports"
  ON public.message_reports FOR SELECT TO authenticated
  USING (reporter_id = auth.uid());

GRANT SELECT, INSERT ON public.message_reports TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.hide_direct_message_for_me(p_message_id UUID)
RETURNS VOID
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.messages message
    JOIN public.conversations conversation ON conversation.id = message.conversation_id
    WHERE message.id = p_message_id
      AND message.is_deleted = FALSE
      AND v_user_id IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'message access denied' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.hidden_chat_messages(user_id, direct_message_id)
  VALUES (v_user_id, p_message_id)
  ON CONFLICT (user_id, direct_message_id)
    WHERE direct_message_id IS NOT NULL
  DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.hide_group_message_for_me(p_message_id UUID)
RETURNS VOID
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.group_messages message
    WHERE message.id = p_message_id
      AND message.is_deleted = FALSE
      AND public.is_chat_group_member(message.group_id, v_user_id)
  ) THEN
    RAISE EXCEPTION 'message access denied' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.hidden_chat_messages(user_id, group_message_id)
  VALUES (v_user_id, p_message_id)
  ON CONFLICT (user_id, group_message_id)
    WHERE group_message_id IS NOT NULL
  DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_own_direct_message(p_message_id UUID)
RETURNS VOID
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

  UPDATE public.messages
  SET is_deleted = TRUE
  WHERE id = p_message_id
    AND sender_id = v_user_id
    AND is_deleted = FALSE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'only the sender can delete this message' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_own_group_message(p_message_id UUID)
RETURNS VOID
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

  UPDATE public.group_messages
  SET is_deleted = TRUE
  WHERE id = p_message_id
    AND sender_id = v_user_id
    AND is_deleted = FALSE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'only the sender can delete this message' USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.hide_direct_message_for_me(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hide_group_message_for_me(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_own_direct_message(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_own_group_message(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hide_direct_message_for_me(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hide_group_message_for_me(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_own_direct_message(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_own_group_message(UUID) TO authenticated, service_role;

-- Replace the bounded page readers so locally hidden messages stay hidden after reload.
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
    SELECT 1 FROM public.conversations conversation
    WHERE conversation.id = p_conversation_id
      AND v_user_id IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    message.id,
    message.conversation_id,
    message.sender_id,
    message.content,
    message.message_type,
    message.metadata,
    message.is_read,
    message.created_at,
    message.is_deleted
  FROM public.messages message
  WHERE message.conversation_id = p_conversation_id
    AND message.is_deleted = FALSE
    AND NOT EXISTS (
      SELECT 1 FROM public.hidden_chat_messages hidden
      WHERE hidden.user_id = v_user_id
        AND hidden.direct_message_id = message.id
    )
    AND (
      p_before_created_at IS NULL
      OR (message.created_at, message.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY message.created_at DESC, message.id DESC
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
    message.id,
    message.group_id,
    message.sender_id,
    message.content,
    message.message_type,
    message.metadata,
    message.is_deleted,
    message.created_at,
    COALESCE(NULLIF(profile.full_name, ''), '已注销') AS sender_name,
    profile.avatar_url AS sender_avatar
  FROM public.group_messages message
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
