-- 048_deactivate_account_email_reuse.sql
-- 目标：
-- 1) 注销后释放原邮箱（允许同邮箱重新注册）
-- 2) 保留聊天里“已注销”展示
-- 3) 清理 auth.identities，避免 OAuth 账号被旧用户占用

BEGIN;

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

  -- 先退出/离开所有群，保持群成员关系一致。
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

  DELETE FROM public.comments
  WHERE user_id = v_user_id;

  DELETE FROM public.likes
  WHERE user_id = v_user_id;

  DELETE FROM public.favorites
  WHERE user_id = v_user_id;

  DELETE FROM public.view_history
  WHERE user_id = v_user_id;

  IF to_regclass('public.ride_participants') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.ride_participants WHERE user_id = $1' USING v_user_id;
  END IF;

  IF to_regclass('public.team_members') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.team_members WHERE user_id = $1' USING v_user_id;
  END IF;

  -- 删除用户公开帖子及关联详情。
  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  -- 保留 profile 行用于聊天展示“已注销”，但脱敏并替换邮箱，释放原邮箱可重注册。
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

  -- 封禁旧 auth 用户，替换邮箱释放唯一约束，并记录原邮箱。
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

  -- 清理身份绑定，避免 Google/Apple 仍映射到已注销账号。
  IF to_regclass('auth.identities') IS NOT NULL THEN
    DELETE FROM auth.identities
    WHERE user_id = v_user_id;
  END IF;

  IF to_regclass('auth.refresh_tokens') IS NOT NULL THEN
    DELETE FROM auth.refresh_tokens
    WHERE user_id::text = v_user_id::text;
  END IF;

  DELETE FROM auth.sessions
  WHERE user_id::text = v_user_id::text;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.deactivate_my_account()
  TO authenticated, service_role;

-- 回填历史已注销账号：释放其占用邮箱并清理 OAuth identity。
DO $$
DECLARE
  r RECORD;
  v_tombstone_email TEXT;
BEGIN
  FOR r IN
    SELECT p.id AS user_id, u.email AS auth_email
    FROM public.profiles p
    LEFT JOIN auth.users u ON u.id = p.id
    WHERE p.deactivated_at IS NOT NULL
  LOOP
    v_tombstone_email := format(
      'deactivated+%s@deleted.cheeseapp.local',
      replace(r.user_id::text, '-', '')
    );

    UPDATE public.profiles
    SET email = v_tombstone_email, updated_at = NOW()
    WHERE id = r.user_id
      AND email IS DISTINCT FROM v_tombstone_email;

    UPDATE auth.users
    SET
      email = v_tombstone_email,
      phone = NULL,
      banned_until = COALESCE(banned_until, NOW() + INTERVAL '100 years'),
      updated_at = NOW(),
      raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object(
          'deactivated_backfill_at', NOW(),
          'original_email', COALESCE(raw_user_meta_data->>'original_email', r.auth_email)
        )
    WHERE id = r.user_id;

    IF to_regclass('auth.identities') IS NOT NULL THEN
      DELETE FROM auth.identities WHERE user_id::text = r.user_id::text;
    END IF;

    IF to_regclass('auth.refresh_tokens') IS NOT NULL THEN
      DELETE FROM auth.refresh_tokens WHERE user_id::text = r.user_id::text;
    END IF;

    DELETE FROM auth.sessions WHERE user_id::text = r.user_id::text;
  END LOOP;
END;
$$;

COMMIT;
