-- 176_preserve_deactivated_user_comments.sql
--
-- From this migration forward, account deactivation keeps comments written on
-- other users' surviving Forum posts. The author identity is tombstoned in the
-- comment row so clients can render a stable "已注销" label without exposing
-- the deactivated profile through profile discovery.
--
-- Existing deactivated accounts are intentionally not backfilled. Comments
-- deleted by earlier deactivations cannot be reconstructed.

BEGIN;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS author_is_deactivated BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.comments.author_is_deactivated IS
  'True when the comment author deactivated after migration 176; retained comments render with a tombstoned identity.';

CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_group_id UUID;
  v_now TIMESTAMPTZ := NOW();
  v_old_email TEXT;
  v_tombstone_email TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT email
  INTO v_old_email
  FROM auth.users
  WHERE id = v_user_id;

  v_tombstone_email := format(
    'deactivated+%s@deleted.cheeseapp.local',
    replace(v_user_id::text, '-', '')
  );

  FOR v_group_id IN
    SELECT gm.group_id
    FROM public.chat_group_members gm
    WHERE gm.user_id = v_user_id
  LOOP
    BEGIN
      PERFORM public.leave_chat_group(v_group_id);
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.chat_group_members
      WHERE group_id = v_group_id
        AND user_id = v_user_id;
    END;
  END LOOP;

  DELETE FROM public.user_chat_group_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_conversation_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_blocks
  WHERE blocker_id = v_user_id
     OR blocked_id = v_user_id;

  DELETE FROM public.user_reports
  WHERE reporter_id = v_user_id
     OR reported_user_id = v_user_id;

  DELETE FROM public.user_follows
  WHERE follower_id = v_user_id
     OR following_id = v_user_id;

  -- Keep authored comments on posts that remain after deactivation. The later
  -- post deletion still cascades comments belonging to the user's own posts.
  UPDATE public.comments
  SET
    author_is_deactivated = TRUE,
    updated_at = v_now
  WHERE user_id = v_user_id;

  DELETE FROM public.likes
  WHERE user_id = v_user_id;

  DELETE FROM public.favorites
  WHERE user_id = v_user_id;

  DELETE FROM public.view_history
  WHERE user_id = v_user_id;

  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  UPDATE public.profiles
  SET
    email = v_tombstone_email,
    full_name = '已注销',
    avatar_url = NULL,
    university = '已注销',
    bio = '此账号已注销',
    verified = FALSE,
    is_anonymous = FALSE,
    deactivated_at = v_now,
    updated_at = v_now
  WHERE id = v_user_id;

  UPDATE auth.users
  SET
    email = v_tombstone_email,
    phone = NULL,
    banned_until = v_now + INTERVAL '100 years',
    updated_at = v_now,
    raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
      || jsonb_build_object(
        'deactivated_at', v_now,
        'original_email', v_old_email
      )
  WHERE id = v_user_id;

  DELETE FROM auth.sessions
  WHERE user_id = v_user_id;

  DELETE FROM auth.identities
  WHERE user_id = v_user_id;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.deactivate_my_account()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deactivate_my_account()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.deactivate_my_account() IS
  'Deactivates the current account while retaining comments on surviving Forum posts with a tombstoned author identity.';

NOTIFY pgrst, 'reload schema';

COMMIT;
