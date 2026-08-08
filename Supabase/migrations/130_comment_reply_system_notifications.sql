-- Add feature-owned system messages for forum comments and replies.
--
-- The older forum comment/like triggers wrote push jobs directly, while the
-- newer social-event path writes system_messages and lets one trigger enqueue
-- the matching push. Remove the overlapping direct triggers so each event has
-- one durable timeline record and at most one push job.

BEGIN;

ALTER TABLE public.system_messages
  DROP CONSTRAINT IF EXISTS system_messages_kind_check;
ALTER TABLE public.system_messages
  ADD CONSTRAINT system_messages_kind_check CHECK (
    kind IN (
      'automatic',
      'mention',
      'post_like',
      'comment_like',
      'post_comment',
      'comment_reply',
      'follow',
      'secondhand_availability'
    )
  );

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
    WHEN NEW.kind IN ('post_comment', 'comment_reply')
      THEN COALESCE(preference.post_comment_enabled, TRUE)
    WHEN NEW.kind IN ('post_like', 'comment_like')
      THEN COALESCE(preference.post_like_enabled, TRUE)
    WHEN NEW.kind IN ('mention', 'follow')
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

REVOKE ALL ON FUNCTION public.enqueue_system_message_push()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.notify_system_message_for_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_owner_id UUID;
  v_post_title TEXT;
  v_parent_owner_id UUID;
  v_actor_name TEXT;
  v_actor_label TEXT;
BEGIN
  IF COALESCE(NEW.is_deleted, FALSE) THEN
    RETURN NEW;
  END IF;

  SELECT post_row.user_id, post_row.title
  INTO v_post_owner_id, v_post_title
  FROM public.posts post_row
  JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
  WHERE post_row.id = NEW.post_id
    AND post_row.type = 'forum'
    AND post_row.status = 'active'
    AND COALESCE(forum_row.allow_comments, TRUE)
    AND NOT COALESCE(forum_row.is_locked, FALSE);

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(btrim(profile.full_name), ''), '有人')
  INTO v_actor_name
  FROM public.profiles profile
  WHERE profile.id = NEW.user_id;

  v_actor_label := CASE
    WHEN COALESCE(NEW.is_anonymous, FALSE) THEN '匿名用户'
    ELSE COALESCE(v_actor_name, '有人')
  END;

  IF NEW.parent_id IS NOT NULL THEN
    SELECT parent.user_id
    INTO v_parent_owner_id
    FROM public.comments parent
    WHERE parent.id = NEW.parent_id
      AND parent.post_id = NEW.post_id
      AND parent.is_deleted = FALSE;

    IF v_parent_owner_id IS NOT NULL
       AND v_parent_owner_id <> NEW.user_id
    THEN
      PERFORM public.enqueue_system_message(
        p_recipient_user_id := v_parent_owner_id,
        p_event_id := format(
          'comment_reply:%s:%s',
          NEW.id,
          v_parent_owner_id
        ),
        p_kind := 'comment_reply',
        p_title := '有人回复了你的评论',
        p_body := format(
          '%s 回复了你在「%s」中的评论',
          v_actor_label,
          COALESCE(
            NULLIF(left(btrim(v_post_title), 60), ''),
            '一则帖子'
          )
        ),
        p_actor_user_id := NEW.user_id,
        p_post_id := NEW.post_id,
        p_comment_id := NEW.id,
        p_content_kind := 'comment',
        p_cta_kind := 'view_post',
        p_hide_actor := COALESCE(NEW.is_anonymous, FALSE)
      );
    END IF;
  END IF;

  -- The post owner still receives a comment event when the conversation is
  -- happening under their post, unless that owner already received the more
  -- specific reply event above.
  IF v_post_owner_id IS NOT NULL
     AND v_post_owner_id <> NEW.user_id
     AND v_post_owner_id IS DISTINCT FROM v_parent_owner_id
  THEN
    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_post_owner_id,
      p_event_id := format(
        'post_comment:%s:%s',
        NEW.id,
        v_post_owner_id
      ),
      p_kind := 'post_comment',
      p_title := '你的帖子收到了评论',
      p_body := format(
        '%s 评论了「%s」',
        v_actor_label,
        COALESCE(
          NULLIF(left(btrim(v_post_title), 60), ''),
          '你的帖子'
        )
      ),
      p_actor_user_id := NEW.user_id,
      p_post_id := NEW.post_id,
      p_comment_id := NEW.id,
      p_content_kind := 'comment',
      p_cta_kind := 'view_post',
      p_hide_actor := COALESCE(NEW.is_anonymous, FALSE)
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_system_message_for_comment
  ON public.comments;
CREATE TRIGGER trg_notify_system_message_for_comment
AFTER INSERT ON public.comments
FOR EACH ROW
WHEN (COALESCE(NEW.is_deleted, FALSE) = FALSE)
EXECUTE FUNCTION public.notify_system_message_for_comment();

REVOKE ALL ON FUNCTION public.notify_system_message_for_comment()
  FROM PUBLIC, anon, authenticated, service_role;

-- These legacy triggers bypassed the system-message timeline and overlap with
-- the feature-owned social notification path.
DROP TRIGGER IF EXISTS trg_enqueue_forum_comment_push ON public.comments;
DROP FUNCTION IF EXISTS public.enqueue_forum_comment_push();
DROP TRIGGER IF EXISTS trg_enqueue_forum_like_push ON public.likes;
DROP FUNCTION IF EXISTS public.enqueue_forum_like_push();

NOTIFY pgrst, 'reload schema';

COMMIT;
