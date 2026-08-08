-- Retire the Zhizhi prompt/companion system.
--
-- Destructive effects:
-- - Deletes comments created with system_role = 'zhizhi'.
-- - Deletes all zhizhi_event_progress data.
-- - Removes the system_role and sticker_id comment metadata introduced for this feature.
--
-- Production order: back up comments and zhizhi_event_progress, deploy an app build
-- without Zhizhi reads/writes, then apply this migration. Rollback requires restoring
-- the deleted rows from backup; recreating the schema alone cannot recover data.

BEGIN;

DELETE FROM public.comments
WHERE system_role = 'zhizhi';

DROP FUNCTION IF EXISTS public.increment_zhizhi_event_tap(TEXT, INTEGER);
DROP TABLE IF EXISTS public.zhizhi_event_progress;
DROP FUNCTION IF EXISTS public.touch_zhizhi_event_updated_at();

ALTER TABLE public.comments
  DROP COLUMN IF EXISTS system_role,
  DROP COLUMN IF EXISTS sticker_id;

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

  IF COALESCE(NEW.is_anonymous, FALSE) = TRUE THEN
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

COMMIT;
