-- 151_include_comment_content_in_notifications.sql
-- Show a bounded snapshot of the comment/reply text in system messages and
-- APNs payloads. This is a non-destructive notification-copy change: source
-- comments and product data are not rewritten.

BEGIN;

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
  v_comment_preview TEXT;
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

  v_comment_preview := regexp_replace(
    btrim(COALESCE(NEW.content, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  IF NULLIF(v_comment_preview, '') IS NULL THEN
    v_comment_preview := '查看内容';
  ELSIF char_length(v_comment_preview) > 120 THEN
    v_comment_preview := left(v_comment_preview, 119) || '…';
  END IF;

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
          '%s 回复了你在「%s」中的评论：“%s”',
          v_actor_label,
          COALESCE(
            NULLIF(left(btrim(v_post_title), 60), ''),
            '一则帖子'
          ),
          v_comment_preview
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
        '%s 评论了「%s」：“%s”',
        v_actor_label,
        COALESCE(
          NULLIF(left(btrim(v_post_title), 60), ''),
          '你的帖子'
        ),
        v_comment_preview
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

REVOKE ALL ON FUNCTION public.notify_system_message_for_comment()
  FROM PUBLIC, anon, authenticated, service_role;

-- Existing visible notifications gain the same comment snapshot when the
-- source comment still exists. Deleted comments retain their original copy.
WITH comment_previews AS (
  SELECT
    message.id,
    CASE
      WHEN char_length(normalized.preview) > 120
        THEN left(normalized.preview, 119) || '…'
      ELSE normalized.preview
    END AS preview
  FROM public.system_messages message
  JOIN public.comments comment_row ON comment_row.id = message.comment_id
  CROSS JOIN LATERAL (
    SELECT regexp_replace(
      btrim(COALESCE(comment_row.content, '')),
      '[[:space:]]+',
      ' ',
      'g'
    ) AS preview
  ) normalized
  WHERE message.kind IN ('post_comment', 'comment_reply')
    AND comment_row.is_deleted = FALSE
    AND NULLIF(normalized.preview, '') IS NOT NULL
    AND position('：“' IN message.body) = 0
)
UPDATE public.system_messages message
SET body = left(
  message.body || '：“' || comment_previews.preview || '”',
  500
)
FROM comment_previews
WHERE message.id = comment_previews.id;

COMMIT;
