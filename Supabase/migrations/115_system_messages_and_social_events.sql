-- 115_system_messages_and_social_events.sql
-- Feature-owned in-app system messages.
--
-- This is intentionally separate from direct and group chat. End users may
-- read their own timeline and mark it read, but cannot create or edit message
-- content. Social triggers are idempotent and suppress self/blocked events.

BEGIN;

CREATE TABLE public.system_messages (
  id UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  recipient_user_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL CHECK (
    char_length(event_id) BETWEEN 1 AND 240
  ),
  kind TEXT NOT NULL CHECK (
    kind IN (
      'automatic',
      'mention',
      'post_like',
      'comment_like',
      'follow',
      'secondhand_availability'
    )
  ),
  title TEXT NOT NULL CHECK (
    char_length(title) BETWEEN 1 AND 120
  ),
  body TEXT NOT NULL CHECK (
    char_length(body) BETWEEN 1 AND 500
  ),
  actor_user_id UUID
    REFERENCES public.profiles(id) ON DELETE SET NULL,
  post_id UUID
    REFERENCES public.posts(id) ON DELETE SET NULL,
  comment_id UUID
    REFERENCES public.comments(id) ON DELETE SET NULL,
  content_kind TEXT CHECK (
    content_kind IS NULL
    OR content_kind IN ('forum', 'rent', 'secondhand', 'comment', 'profile')
  ),
  cta_kind TEXT NOT NULL DEFAULT 'none' CHECK (
    cta_kind IN (
      'none',
      'view_post',
      'view_profile',
      'secondhand_availability'
    )
  ),
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT system_messages_recipient_event_unique
    UNIQUE (recipient_user_id, event_id)
);

CREATE INDEX system_messages_recipient_page_idx
  ON public.system_messages (
    recipient_user_id,
    created_at DESC,
    id DESC
  );

CREATE INDEX system_messages_recipient_unread_idx
  ON public.system_messages (recipient_user_id, created_at DESC)
  WHERE read_at IS NULL;

ALTER TABLE public.system_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Recipients can read own system messages"
ON public.system_messages
FOR SELECT
TO authenticated
USING (recipient_user_id = auth.uid());

REVOKE ALL ON TABLE public.system_messages
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.system_messages TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.system_messages
  TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_system_message(
  p_recipient_user_id UUID,
  p_event_id TEXT,
  p_kind TEXT,
  p_title TEXT,
  p_body TEXT,
  p_actor_user_id UUID DEFAULT NULL,
  p_post_id UUID DEFAULT NULL,
  p_comment_id UUID DEFAULT NULL,
  p_content_kind TEXT DEFAULT NULL,
  p_cta_kind TEXT DEFAULT 'none',
  p_hide_actor BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_message_id UUID;
  v_post public.posts%ROWTYPE;
BEGIN
  IF p_recipient_user_id IS NULL
     OR NULLIF(btrim(COALESCE(p_event_id, '')), '') IS NULL
  THEN
    RETURN NULL;
  END IF;

  IF p_actor_user_id IS NOT NULL THEN
    IF p_actor_user_id = p_recipient_user_id
       OR EXISTS (
         SELECT 1
         FROM public.user_blocks block_row
         WHERE (
           block_row.blocker_id = p_actor_user_id
           AND block_row.blocked_id = p_recipient_user_id
         )
         OR (
           block_row.blocker_id = p_recipient_user_id
           AND block_row.blocked_id = p_actor_user_id
         )
       )
    THEN
      RETURN NULL;
    END IF;
  END IF;

  IF p_post_id IS NOT NULL THEN
    SELECT post_row.*
    INTO v_post
    FROM public.posts post_row
    WHERE post_row.id = p_post_id;

    IF NOT FOUND
       OR v_post.status <> 'active'
       OR (
         v_post.is_private
         AND v_post.user_id <> p_recipient_user_id
       )
    THEN
      RETURN NULL;
    END IF;
  END IF;

  INSERT INTO public.system_messages (
    recipient_user_id,
    event_id,
    kind,
    title,
    body,
    actor_user_id,
    post_id,
    comment_id,
    content_kind,
    cta_kind
  )
  VALUES (
    p_recipient_user_id,
    left(btrim(p_event_id), 240),
    p_kind,
    left(btrim(p_title), 120),
    left(btrim(p_body), 500),
    CASE WHEN p_hide_actor THEN NULL ELSE p_actor_user_id END,
    p_post_id,
    p_comment_id,
    p_content_kind,
    p_cta_kind
  )
  ON CONFLICT (recipient_user_id, event_id) DO NOTHING
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_system_message(
  UUID, TEXT, TEXT, TEXT, TEXT, UUID, UUID, UUID, TEXT, TEXT, BOOLEAN
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_system_message_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_enabled BOOLEAN := TRUE;
BEGIN
  IF NOT public.has_active_push_tokens(NEW.recipient_user_id) THEN
    RETURN NEW;
  END IF;

  SELECT CASE
    WHEN NEW.kind IN ('post_like', 'comment_like', 'mention', 'follow')
      THEN COALESCE(preference.forum_activity_enabled, TRUE)
    ELSE COALESCE(preference.message_enabled, TRUE)
  END
  INTO v_enabled
  FROM public.user_notification_preferences preference
  WHERE preference.user_id = NEW.recipient_user_id;

  IF NOT FOUND THEN
    v_enabled := TRUE;
  END IF;

  IF v_enabled IS NOT TRUE THEN
    RETURN NEW;
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
    NEW.recipient_user_id,
    NEW.kind,
    NEW.title,
    NEW.body,
    jsonb_strip_nulls(
      jsonb_build_object(
        'cheese_destination', 'system_messages',
        'notification_kind', NEW.kind,
        'system_message_id', NEW.id,
        'post_kind', NEW.content_kind,
        'post_id', NEW.post_id,
        'actor_user_id', NEW.actor_user_id
      )
    ),
    'system_messages',
    NEW.id::TEXT,
    COALESCE(NEW.post_id::TEXT, NEW.actor_user_id::TEXT),
    COALESCE(NEW.post_id::TEXT, NEW.actor_user_id::TEXT)
  )
  ON CONFLICT (recipient_user_id, source_type, source_key)
  DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enqueue_system_message_push
AFTER INSERT ON public.system_messages
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_system_message_push();

REVOKE ALL ON FUNCTION public.enqueue_system_message_push()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_system_messages_page(
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 30
)
RETURNS TABLE (
  id UUID,
  event_id TEXT,
  kind TEXT,
  title TEXT,
  body TEXT,
  actor_user_id UUID,
  actor_name TEXT,
  actor_avatar_url TEXT,
  post_id UUID,
  comment_id UUID,
  content_kind TEXT,
  cta_kind TEXT,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
  SELECT
    message.id,
    message.event_id,
    message.kind,
    message.title,
    message.body,
    message.actor_user_id,
    CASE
      WHEN message.actor_user_id IS NULL THEN NULL
      ELSE COALESCE(
        NULLIF(btrim(actor.full_name), ''),
        '用户'
      )
    END,
    actor.avatar_url,
    message.post_id,
    message.comment_id,
    message.content_kind,
    message.cta_kind,
    message.read_at,
    message.created_at
  FROM public.system_messages message
  LEFT JOIN public.profiles actor
    ON actor.id = message.actor_user_id
   AND NOT public.is_user_blocked(auth.uid(), actor.id)
  WHERE auth.uid() IS NOT NULL
    AND message.recipient_user_id = auth.uid()
    AND (
      p_before_created_at IS NULL
      OR (
        p_before_id IS NOT NULL
        AND (message.created_at, message.id)
          < (p_before_created_at, p_before_id)
      )
    )
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
$$;

CREATE OR REPLACE FUNCTION public.get_system_message_unread_count()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN 0
    ELSE (
      SELECT COUNT(*)::INTEGER
      FROM public.system_messages message
      WHERE message.recipient_user_id = auth.uid()
        AND message.read_at IS NULL
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.mark_system_message_read(
  p_message_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.system_messages message
  SET read_at = COALESCE(message.read_at, clock_timestamp())
  WHERE message.id = p_message_id
    AND message.recipient_user_id = auth.uid();

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_all_system_messages_read()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.system_messages message
  SET read_at = clock_timestamp()
  WHERE message.recipient_user_id = auth.uid()
    AND message.read_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.get_system_messages_page(
  TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_system_message_unread_count()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_system_message_read(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_all_system_messages_read()
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_system_messages_page(
  TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_system_message_unread_count()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_system_message_read(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_system_messages_read()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.notify_system_message_for_like()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_recipient UUID;
  v_post_id UUID;
  v_post_type TEXT;
  v_post_title TEXT;
  v_actor_name TEXT;
  v_kind TEXT;
  v_comment_id UUID;
  v_event_id TEXT;
BEGIN
  IF NEW.target_type = 'post' THEN
    SELECT post_row.user_id, post_row.id, post_row.type, post_row.title
    INTO v_recipient, v_post_id, v_post_type, v_post_title
    FROM public.posts post_row
    WHERE post_row.id = NEW.target_id
      AND post_row.status = 'active';
    v_kind := 'post_like';
  ELSIF NEW.target_type = 'comment' THEN
    SELECT
      comment_row.user_id,
      post_row.id,
      post_row.type,
      post_row.title,
      comment_row.id
    INTO
      v_recipient,
      v_post_id,
      v_post_type,
      v_post_title,
      v_comment_id
    FROM public.comments comment_row
    JOIN public.posts post_row
      ON post_row.id = comment_row.post_id
    WHERE comment_row.id = NEW.target_id
      AND comment_row.is_deleted = FALSE
      AND post_row.status = 'active';
    v_kind := 'comment_like';
  ELSE
    RETURN NEW;
  END IF;

  IF v_recipient IS NULL OR v_recipient = NEW.user_id THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(btrim(profile.full_name), ''), '有人')
  INTO v_actor_name
  FROM public.profiles profile
  WHERE profile.id = NEW.user_id;

  -- One notification per actor/target in a UTC day. Unlike/re-like loops do
  -- not spam, while a genuinely later interaction may notify again.
  v_event_id := format(
    '%s:%s:%s:%s',
    v_kind,
    NEW.user_id,
    NEW.target_id,
    to_char(
      COALESCE(NEW.created_at, clock_timestamp()) AT TIME ZONE 'UTC',
      'YYYY-MM-DD'
    )
  );

  PERFORM public.enqueue_system_message(
    p_recipient_user_id := v_recipient,
    p_event_id := v_event_id,
    p_kind := v_kind,
    p_title := CASE
      WHEN v_kind = 'comment_like' THEN '你的评论收到了点赞'
      ELSE '你的帖子收到了点赞'
    END,
    p_body := format(
      '%s 点赞了「%s」',
      COALESCE(v_actor_name, '有人'),
      COALESCE(NULLIF(left(btrim(v_post_title), 60), ''), '你的内容')
    ),
    p_actor_user_id := NEW.user_id,
    p_post_id := v_post_id,
    p_comment_id := v_comment_id,
    p_content_kind := CASE
      WHEN v_kind = 'comment_like' THEN 'comment'
      ELSE v_post_type
    END,
    p_cta_kind := 'view_post'
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_system_message_for_like
  ON public.likes;
CREATE TRIGGER trg_notify_system_message_for_like
AFTER INSERT ON public.likes
FOR EACH ROW
EXECUTE FUNCTION public.notify_system_message_for_like();

REVOKE ALL ON FUNCTION public.notify_system_message_for_like()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.notify_system_message_for_follow()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_name TEXT;
  v_event_id TEXT;
BEGIN
  IF NEW.follower_id = NEW.following_id
     OR EXISTS (
       SELECT 1
       FROM public.user_blocks block_row
       WHERE (
         block_row.blocker_id = NEW.follower_id
         AND block_row.blocked_id = NEW.following_id
       )
       OR (
         block_row.blocker_id = NEW.following_id
         AND block_row.blocked_id = NEW.follower_id
       )
     )
  THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(btrim(profile.full_name), ''), '有人')
  INTO v_actor_name
  FROM public.profiles profile
  WHERE profile.id = NEW.follower_id;

  v_event_id := format(
    'follow:%s:%s:%s',
    NEW.follower_id,
    NEW.following_id,
    to_char(
      COALESCE(NEW.created_at, clock_timestamp()) AT TIME ZONE 'UTC',
      'YYYY-MM-DD'
    )
  );

  PERFORM public.enqueue_system_message(
    p_recipient_user_id := NEW.following_id,
    p_event_id := v_event_id,
    p_kind := 'follow',
    p_title := '你有新的关注者',
    p_body := format('%s 关注了你', COALESCE(v_actor_name, '有人')),
    p_actor_user_id := NEW.follower_id,
    p_content_kind := 'profile',
    p_cta_kind := 'view_profile'
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_system_message_for_follow
  ON public.user_follows;
CREATE TRIGGER trg_notify_system_message_for_follow
AFTER INSERT ON public.user_follows
FOR EACH ROW
EXECUTE FUNCTION public.notify_system_message_for_follow();

REVOKE ALL ON FUNCTION public.notify_system_message_for_follow()
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
