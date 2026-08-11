-- Keep the follow relationship and database contract intact while presenting
-- incoming followers consistently as "粉丝" in user-facing notifications.

BEGIN;

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
    p_title := '你有新的粉丝',
    p_body := format('%s 成为了你的粉丝', COALESCE(v_actor_name, '有人')),
    p_actor_user_id := NEW.follower_id,
    p_content_kind := 'profile',
    p_cta_kind := 'view_profile'
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_system_message_for_follow()
  FROM PUBLIC, anon, authenticated, service_role;

UPDATE public.system_messages
SET
  title = '你有新的粉丝',
  body = regexp_replace(body, ' 关注了你$', ' 成为了你的粉丝')
WHERE kind = 'follow'
  AND (
    title = '你有新的关注者'
    OR body LIKE '% 关注了你'
  );

COMMIT;
