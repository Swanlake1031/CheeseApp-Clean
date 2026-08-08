-- 077_real_push_notification_pipeline.sql
-- Real push notification queue + enqueue triggers for chat and forum engagement.

BEGIN;

-- ============================================
-- Table grants for existing push primitives
-- ============================================
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_push_tokens TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.user_notification_preferences TO authenticated, service_role;

-- ============================================
-- Push notification queue
-- ============================================
CREATE TABLE IF NOT EXISTS public.push_notification_jobs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recipient_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  source_type TEXT NOT NULL,
  source_key TEXT NOT NULL,
  thread_id TEXT,
  collapse_key TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'canceled')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  locked_at TIMESTAMPTZ,
  locked_by TEXT,
  sent_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS push_notification_jobs_recipient_source_unique
  ON public.push_notification_jobs(recipient_user_id, source_type, source_key);

CREATE INDEX IF NOT EXISTS push_notification_jobs_pending_idx
  ON public.push_notification_jobs(status, available_at, id);

CREATE INDEX IF NOT EXISTS push_notification_jobs_recipient_idx
  ON public.push_notification_jobs(recipient_user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.touch_push_notification_jobs_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_push_notification_jobs_updated_at ON public.push_notification_jobs;
CREATE TRIGGER trg_push_notification_jobs_updated_at
BEFORE UPDATE ON public.push_notification_jobs
FOR EACH ROW
EXECUTE FUNCTION public.touch_push_notification_jobs_updated_at();

ALTER TABLE public.push_notification_jobs DISABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_notification_jobs FROM anon, authenticated;
GRANT SELECT, UPDATE, DELETE ON public.push_notification_jobs TO service_role;

-- ============================================
-- Push preference/token helpers
-- ============================================
CREATE OR REPLACE FUNCTION public.upsert_user_notification_preferences(
  p_message_enabled BOOLEAN DEFAULT TRUE,
  p_forum_activity_enabled BOOLEAN DEFAULT TRUE,
  p_post_comment_enabled BOOLEAN DEFAULT TRUE,
  p_post_like_enabled BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO public.user_notification_preferences (
    user_id,
    message_enabled,
    forum_activity_enabled,
    post_comment_enabled,
    post_like_enabled
  )
  VALUES (
    v_user_id,
    COALESCE(p_message_enabled, TRUE),
    COALESCE(p_forum_activity_enabled, TRUE),
    COALESCE(p_post_comment_enabled, TRUE),
    COALESCE(p_post_like_enabled, TRUE)
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    message_enabled = EXCLUDED.message_enabled,
    forum_activity_enabled = EXCLUDED.forum_activity_enabled,
    post_comment_enabled = EXCLUDED.post_comment_enabled,
    post_like_enabled = EXCLUDED.post_like_enabled,
    updated_at = NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_user_notification_preferences(BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_user_push_token(p_token TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_token, '')), '') IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.user_push_tokens
  WHERE user_id = v_user_id
    AND token = BTRIM(p_token);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_user_push_token(TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.has_active_push_tokens(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_push_tokens upt
    WHERE upt.user_id = p_user_id
      AND NULLIF(BTRIM(COALESCE(upt.token, '')), '') IS NOT NULL
  );
$$;

GRANT EXECUTE ON FUNCTION public.has_active_push_tokens(UUID)
  TO authenticated, service_role;

-- ============================================
-- Push text helpers
-- ============================================
CREATE OR REPLACE FUNCTION public.push_message_preview(
  p_message_type TEXT,
  p_content TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_metadata JSONB := COALESCE(p_metadata, '{}'::jsonb);
  v_content TEXT;
BEGIN
  v_content := LEFT(
    REGEXP_REPLACE(
      COALESCE(NULLIF(BTRIM(COALESCE(p_content, '')), ''), '给你发来了一条消息'),
      '\s+',
      ' ',
      'g'
    ),
    120
  );

  IF LOWER(COALESCE(p_message_type, '')) = 'image' THEN
    RETURN '发来了一张图片';
  END IF;

  IF v_metadata ? 'team_join_card' THEN
    RETURN '发来了一张组队申请卡';
  END IF;

  IF v_metadata ? 'ride_invite_card' THEN
    RETURN '发来了一张拼车申请卡';
  END IF;

  IF v_metadata ? 'post_contact_card' THEN
    RETURN '发来了一张帖子联系卡';
  END IF;

  IF v_metadata ? 'shared_post_card' THEN
    RETURN '分享了一篇帖子';
  END IF;

  RETURN v_content;
END;
$$;

GRANT EXECUTE ON FUNCTION public.push_message_preview(TEXT, TEXT, JSONB)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_push_notification_job(
  p_recipient_user_id UUID,
  p_kind TEXT,
  p_title TEXT,
  p_body TEXT,
  p_payload JSONB DEFAULT '{}'::jsonb,
  p_source_type TEXT DEFAULT 'unknown',
  p_source_key TEXT DEFAULT '',
  p_thread_id TEXT DEFAULT NULL,
  p_collapse_key TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_title TEXT := LEFT(COALESCE(NULLIF(BTRIM(COALESCE(p_title, '')), ''), 'Cheese'), 120);
  v_body TEXT := LEFT(COALESCE(NULLIF(BTRIM(COALESCE(p_body, '')), ''), '你有一条新通知'), 240);
  v_source_type TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_source_type, '')), ''), 'unknown');
  v_source_key TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_source_key, '')), ''), 'unknown');
BEGIN
  IF p_recipient_user_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.push_notification_jobs (
    recipient_user_id,
    kind,
    title,
    body,
    payload,
    source_type,
    source_key,
    thread_id,
    collapse_key
  )
  VALUES (
    p_recipient_user_id,
    COALESCE(NULLIF(BTRIM(COALESCE(p_kind, '')), ''), 'generic'),
    v_title,
    v_body,
    COALESCE(p_payload, '{}'::jsonb),
    v_source_type,
    v_source_key,
    NULLIF(BTRIM(COALESCE(p_thread_id, '')), ''),
    NULLIF(BTRIM(COALESCE(p_collapse_key, '')), '')
  )
  ON CONFLICT (recipient_user_id, source_type, source_key)
  DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.enqueue_push_notification_job(UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.claim_push_notification_jobs(
  p_limit INTEGER DEFAULT 25,
  p_worker_id TEXT DEFAULT NULL
)
RETURNS TABLE (
  id BIGINT,
  recipient_user_id UUID,
  kind TEXT,
  title TEXT,
  body TEXT,
  payload JSONB,
  thread_id TEXT,
  collapse_key TEXT,
  attempts INTEGER,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 25), 100));
  v_worker_id TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_worker_id, '')), ''), 'push-worker');
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT q.id
    FROM public.push_notification_jobs q
    WHERE q.attempts < 8
      AND (
        (q.status = 'pending' AND q.available_at <= NOW())
        OR (
          q.status = 'processing'
          AND q.locked_at IS NOT NULL
          AND q.locked_at < NOW() - INTERVAL '5 minutes'
        )
      )
    ORDER BY q.available_at ASC, q.id ASC
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ),
  updated AS (
    UPDATE public.push_notification_jobs q
    SET status = 'processing',
        attempts = q.attempts + 1,
        locked_at = NOW(),
        locked_by = v_worker_id,
        updated_at = NOW()
    FROM picked
    WHERE q.id = picked.id
    RETURNING
      q.id,
      q.recipient_user_id,
      q.kind,
      q.title,
      q.body,
      q.payload,
      q.thread_id,
      q.collapse_key,
      q.attempts,
      q.created_at
  )
  SELECT
    updated.id,
    updated.recipient_user_id,
    updated.kind,
    updated.title,
    updated.body,
    updated.payload,
    updated.thread_id,
    updated.collapse_key,
    updated.attempts,
    updated.created_at
  FROM updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_push_notification_jobs(INTEGER, TEXT)
  TO service_role;

-- ============================================
-- Direct-message push enqueue
-- ============================================
CREATE OR REPLACE FUNCTION public.enqueue_direct_message_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_recipient_user_id UUID;
  v_related_post_id UUID;
  v_sender_name TEXT;
  v_message_enabled BOOLEAN := TRUE;
  v_title TEXT;
  v_body TEXT;
BEGIN
  IF NEW.sender_id IS NULL OR COALESCE(NEW.is_deleted, FALSE) = TRUE THEN
    RETURN NEW;
  END IF;

  SELECT
    CASE
      WHEN c.user1_id = NEW.sender_id THEN c.user2_id
      ELSE c.user1_id
    END,
    c.related_post_id
  INTO v_recipient_user_id, v_related_post_id
  FROM public.conversations c
  WHERE c.id = NEW.conversation_id
    AND (c.user1_id = NEW.sender_id OR c.user2_id = NEW.sender_id);

  IF v_recipient_user_id IS NULL OR v_recipient_user_id = NEW.sender_id THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_conversation_settings ucs
    WHERE ucs.user_id = v_recipient_user_id
      AND ucs.conversation_id = NEW.conversation_id
      AND ucs.is_muted = TRUE
  ) THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_active_push_tokens(v_recipient_user_id) THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(unp.message_enabled, TRUE)
    INTO v_message_enabled
  FROM public.user_notification_preferences unp
  WHERE unp.user_id = v_recipient_user_id;

  IF NOT FOUND THEN
    v_message_enabled := TRUE;
  END IF;

  IF v_message_enabled IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(p.full_name, ''), SPLIT_PART(p.email, '@', 1), '新消息')
    INTO v_sender_name
  FROM public.profiles p
  WHERE p.id = NEW.sender_id;

  v_title := COALESCE(NULLIF(BTRIM(COALESCE(v_sender_name, '')), ''), '新消息');
  v_body := public.push_message_preview(NEW.message_type, NEW.content, NEW.metadata);

  PERFORM public.enqueue_push_notification_job(
    p_recipient_user_id := v_recipient_user_id,
    p_kind := 'direct_message',
    p_title := v_title,
    p_body := v_body,
    p_payload := jsonb_strip_nulls(
      jsonb_build_object(
        'cheese_destination', 'direct_conversation',
        'notification_kind', 'direct_message',
        'conversation_id', NEW.conversation_id,
        'message_id', NEW.id,
        'sender_id', NEW.sender_id,
        'related_post_id', v_related_post_id
      )
    ),
    p_source_type := 'messages',
    p_source_key := NEW.id::text,
    p_thread_id := NEW.conversation_id::text,
    p_collapse_key := NEW.conversation_id::text
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_direct_message_push ON public.messages;
CREATE TRIGGER trg_enqueue_direct_message_push
AFTER INSERT ON public.messages
FOR EACH ROW
WHEN (COALESCE(NEW.is_deleted, FALSE) = FALSE)
EXECUTE FUNCTION public.enqueue_direct_message_push();

-- ============================================
-- Group-message push enqueue
-- ============================================
CREATE OR REPLACE FUNCTION public.enqueue_group_message_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_sender_name TEXT;
  v_group_name TEXT;
  v_source_type TEXT;
  v_source_post_id UUID;
  v_body_preview TEXT;
  v_body TEXT;
  v_member RECORD;
  v_message_enabled BOOLEAN;
BEGIN
  IF NEW.sender_id IS NULL OR COALESCE(NEW.is_deleted, FALSE) = TRUE THEN
    RETURN NEW;
  END IF;

  SELECT
    COALESCE(NULLIF(g.name, ''), '群聊新消息'),
    g.source_type,
    g.source_post_id
  INTO v_group_name, v_source_type, v_source_post_id
  FROM public.chat_groups g
  WHERE g.id = NEW.group_id;

  IF v_group_name IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(p.full_name, ''), SPLIT_PART(p.email, '@', 1), '有人')
    INTO v_sender_name
  FROM public.profiles p
  WHERE p.id = NEW.sender_id;

  v_body_preview := public.push_message_preview(NEW.message_type, NEW.content, NEW.metadata);
  v_body := LEFT(
    COALESCE(NULLIF(BTRIM(COALESCE(v_sender_name, '')), ''), '有人') || ': ' || v_body_preview,
    240
  );

  FOR v_member IN
    SELECT gm.user_id
    FROM public.chat_group_members gm
    WHERE gm.group_id = NEW.group_id
      AND gm.user_id <> NEW.sender_id
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.user_chat_group_settings ugs
      WHERE ugs.user_id = v_member.user_id
        AND ugs.group_id = NEW.group_id
        AND ugs.is_muted = TRUE
    ) THEN
      CONTINUE;
    END IF;

    IF NOT public.has_active_push_tokens(v_member.user_id) THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(unp.message_enabled, TRUE)
      INTO v_message_enabled
    FROM public.user_notification_preferences unp
    WHERE unp.user_id = v_member.user_id;

    IF NOT FOUND THEN
      v_message_enabled := TRUE;
    END IF;

    IF v_message_enabled IS NOT TRUE THEN
      CONTINUE;
    END IF;

    PERFORM public.enqueue_push_notification_job(
      p_recipient_user_id := v_member.user_id,
      p_kind := 'group_message',
      p_title := v_group_name,
      p_body := v_body,
      p_payload := jsonb_strip_nulls(
        jsonb_build_object(
          'cheese_destination', 'group_conversation',
          'notification_kind', 'group_message',
          'group_id', NEW.group_id,
          'message_id', NEW.id,
          'sender_id', NEW.sender_id,
          'source_type', v_source_type,
          'source_post_id', v_source_post_id
        )
      ),
      p_source_type := 'group_messages',
      p_source_key := NEW.id::text || ':' || v_member.user_id::text,
      p_thread_id := NEW.group_id::text,
      p_collapse_key := NEW.group_id::text
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_group_message_push ON public.group_messages;
CREATE TRIGGER trg_enqueue_group_message_push
AFTER INSERT ON public.group_messages
FOR EACH ROW
WHEN (COALESCE(NEW.is_deleted, FALSE) = FALSE)
EXECUTE FUNCTION public.enqueue_group_message_push();

-- ============================================
-- Forum comment push enqueue
-- ============================================
CREATE OR REPLACE FUNCTION public.enqueue_forum_comment_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_post_owner_id UUID;
  v_post_title TEXT;
  v_actor_name TEXT;
  v_activity_enabled BOOLEAN := TRUE;
  v_comment_enabled BOOLEAN := TRUE;
  v_title TEXT;
  v_body TEXT;
BEGIN
  IF COALESCE(NEW.is_deleted, FALSE) = TRUE THEN
    RETURN NEW;
  END IF;

  SELECT p.user_id, p.title
    INTO v_post_owner_id, v_post_title
  FROM public.posts p
  WHERE p.id = NEW.post_id
    AND p.type = 'forum'
    AND p.status = 'active';

  IF v_post_owner_id IS NULL OR v_post_owner_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_active_push_tokens(v_post_owner_id) THEN
    RETURN NEW;
  END IF;

  SELECT
    COALESCE(unp.forum_activity_enabled, TRUE),
    COALESCE(unp.post_comment_enabled, TRUE)
  INTO v_activity_enabled, v_comment_enabled
  FROM public.user_notification_preferences unp
  WHERE unp.user_id = v_post_owner_id;

  IF NOT FOUND THEN
    v_activity_enabled := TRUE;
    v_comment_enabled := TRUE;
  END IF;

  IF v_activity_enabled IS NOT TRUE AND v_comment_enabled IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.system_role, '') = 'zhizhi' THEN
    v_actor_name := '芝芝';
  ELSIF COALESCE(NEW.is_anonymous, FALSE) = TRUE THEN
    v_actor_name := '匿名用户';
  ELSE
    SELECT COALESCE(NULLIF(p.full_name, ''), SPLIT_PART(p.email, '@', 1), '有人')
      INTO v_actor_name
    FROM public.profiles p
    WHERE p.id = NEW.user_id;
  END IF;

  IF v_activity_enabled IS TRUE THEN
    v_title := '你的论坛有新互动';
    v_body := FORMAT(
      '「%s」收到了新评论',
      COALESCE(NULLIF(LEFT(BTRIM(COALESCE(v_post_title, '')), 40), ''), '你的帖子')
    );
  ELSE
    v_title := '你的帖子有新评论';
    v_body := FORMAT(
      '%s 评论了「%s」',
      COALESCE(NULLIF(BTRIM(COALESCE(v_actor_name, '')), ''), '有人'),
      COALESCE(NULLIF(LEFT(BTRIM(COALESCE(v_post_title, '')), 40), ''), '你的帖子')
    );
  END IF;

  PERFORM public.enqueue_push_notification_job(
    p_recipient_user_id := v_post_owner_id,
    p_kind := CASE
      WHEN v_activity_enabled IS TRUE THEN 'forum_activity'
      ELSE 'forum_comment'
    END,
    p_title := v_title,
    p_body := v_body,
    p_payload := jsonb_strip_nulls(
      jsonb_build_object(
        'cheese_destination', 'post',
        'notification_kind', CASE
          WHEN v_activity_enabled IS TRUE THEN 'forum_activity'
          ELSE 'forum_comment'
        END,
        'post_kind', 'forum',
        'post_id', NEW.post_id,
        'comment_id', NEW.id
      )
    ),
    p_source_type := 'comments',
    p_source_key := NEW.id::text,
    p_thread_id := NEW.post_id::text,
    p_collapse_key := NEW.post_id::text
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_forum_comment_push ON public.comments;
CREATE TRIGGER trg_enqueue_forum_comment_push
AFTER INSERT ON public.comments
FOR EACH ROW
WHEN (COALESCE(NEW.is_deleted, FALSE) = FALSE)
EXECUTE FUNCTION public.enqueue_forum_comment_push();

-- ============================================
-- Forum like push enqueue
-- ============================================
CREATE OR REPLACE FUNCTION public.enqueue_forum_like_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_post_owner_id UUID;
  v_post_title TEXT;
  v_actor_name TEXT;
  v_activity_enabled BOOLEAN := TRUE;
  v_like_enabled BOOLEAN := TRUE;
  v_title TEXT;
  v_body TEXT;
  v_source_key TEXT;
BEGIN
  IF COALESCE(NEW.target_type, '') <> 'post' THEN
    RETURN NEW;
  END IF;

  SELECT p.user_id, p.title
    INTO v_post_owner_id, v_post_title
  FROM public.posts p
  WHERE p.id = NEW.target_id
    AND p.type = 'forum'
    AND p.status = 'active';

  IF v_post_owner_id IS NULL OR v_post_owner_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_active_push_tokens(v_post_owner_id) THEN
    RETURN NEW;
  END IF;

  SELECT
    COALESCE(unp.forum_activity_enabled, TRUE),
    COALESCE(unp.post_like_enabled, TRUE)
  INTO v_activity_enabled, v_like_enabled
  FROM public.user_notification_preferences unp
  WHERE unp.user_id = v_post_owner_id;

  IF NOT FOUND THEN
    v_activity_enabled := TRUE;
    v_like_enabled := TRUE;
  END IF;

  IF v_activity_enabled IS NOT TRUE AND v_like_enabled IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(p.full_name, ''), SPLIT_PART(p.email, '@', 1), '有人')
    INTO v_actor_name
  FROM public.profiles p
  WHERE p.id = NEW.user_id;

  IF v_activity_enabled IS TRUE THEN
    v_title := '你的论坛有新互动';
    v_body := FORMAT(
      '「%s」收到了新点赞',
      COALESCE(NULLIF(LEFT(BTRIM(COALESCE(v_post_title, '')), 40), ''), '你的帖子')
    );
  ELSE
    v_title := '你的帖子有新点赞';
    v_body := FORMAT(
      '%s 点赞了「%s」',
      COALESCE(NULLIF(BTRIM(COALESCE(v_actor_name, '')), ''), '有人'),
      COALESCE(NULLIF(LEFT(BTRIM(COALESCE(v_post_title, '')), 40), ''), '你的帖子')
    );
  END IF;

  v_source_key := NEW.user_id::text
    || ':'
    || NEW.target_id::text
    || ':'
    || EXTRACT(EPOCH FROM COALESCE(NEW.created_at, NOW()))::bigint::text;

  PERFORM public.enqueue_push_notification_job(
    p_recipient_user_id := v_post_owner_id,
    p_kind := CASE
      WHEN v_activity_enabled IS TRUE THEN 'forum_activity'
      ELSE 'forum_like'
    END,
    p_title := v_title,
    p_body := v_body,
    p_payload := jsonb_strip_nulls(
      jsonb_build_object(
        'cheese_destination', 'post',
        'notification_kind', CASE
          WHEN v_activity_enabled IS TRUE THEN 'forum_activity'
          ELSE 'forum_like'
        END,
        'post_kind', 'forum',
        'post_id', NEW.target_id,
        'actor_user_id', NEW.user_id
      )
    ),
    p_source_type := 'likes',
    p_source_key := v_source_key,
    p_thread_id := NEW.target_id::text,
    p_collapse_key := NEW.target_id::text
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_forum_like_push ON public.likes;
CREATE TRIGGER trg_enqueue_forum_like_push
AFTER INSERT ON public.likes
FOR EACH ROW
WHEN (NEW.target_type = 'post')
EXECUTE FUNCTION public.enqueue_forum_like_push();

NOTIFY pgrst, 'reload schema';

COMMIT;
