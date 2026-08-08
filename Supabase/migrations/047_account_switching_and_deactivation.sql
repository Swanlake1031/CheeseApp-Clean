-- 047_account_switching_and_deactivation.sql
-- 1) Account deactivation RPC with data cleanup
-- 2) Keep chat visibility for deactivated users ("已注销")

BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS deactivated_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_group_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Leave/disband all groups first to keep group ownership logic consistent.
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

  -- Remove all user-generated posts and linked details.
  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  -- Keep profile row for chat history visibility, but scrub public identity.
  UPDATE public.profiles
  SET
    full_name = '已注销',
    avatar_url = NULL,
    university = '已注销',
    bio = '此账号已注销',
    verified = FALSE,
    is_anonymous = FALSE,
    deactivated_at = NOW(),
    updated_at = NOW()
  WHERE id = v_user_id;

  -- Disable future sign-ins and revoke active sessions.
  UPDATE auth.users
  SET
    banned_until = NOW() + INTERVAL '100 years',
    updated_at = NOW(),
    raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
      || jsonb_build_object('deactivated_at', NOW())
  WHERE id = v_user_id;

  DELETE FROM auth.sessions
  WHERE user_id = v_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.deactivate_my_account()
  TO authenticated, service_role;

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
      WHEN c.user1_id = p_user_id THEN COALESCE(NULLIF(p2.full_name, ''), split_part(p2.email, '@', 1), '已注销')
      ELSE COALESCE(NULLIF(p1.full_name, ''), split_part(p1.email, '@', 1), '已注销')
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
  LEFT JOIN public.profiles p1 ON p1.id = c.user1_id
  LEFT JOIN public.profiles p2 ON p2.id = c.user2_id
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
      WHEN c.user1_id = p_user_id THEN COALESCE(NULLIF(p2.full_name, ''), split_part(p2.email, '@', 1), '已注销')
      ELSE COALESCE(NULLIF(p1.full_name, ''), split_part(p1.email, '@', 1), '已注销')
    END AS other_user_name,
    CASE WHEN c.user1_id = p_user_id THEN p2.avatar_url ELSE p1.avatar_url END AS other_user_avatar,
    c.related_post_id,
    c.last_message_at,
    c.last_message_preview,
    CASE WHEN c.user1_id = p_user_id THEN c.user1_unread_count ELSE c.user2_unread_count END AS unread_count,
    FALSE AS can_chat_freely,
    FALSE AS is_mutual_follow
  FROM public.conversations c
  LEFT JOIN public.profiles p1 ON p1.id = c.user1_id
  LEFT JOIN public.profiles p2 ON p2.id = c.user2_id
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

GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_message_requests(UUID)
  TO authenticated, service_role;

-- Hide deactivated accounts from profile discovery.
CREATE OR REPLACE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.birthday,
  p.gender,
  p.occupation,
  p.verified,
  p.profile_completed,
  g.ip_masked,
  g.country_name,
  g.region,
  g.city,
  g.last_seen_at,
  p.created_at,
  p.updated_at
FROM public.profiles p
LEFT JOIN public.user_geo_profiles g
  ON g.user_id = p.id
WHERE p.deactivated_at IS NULL;

CREATE OR REPLACE FUNCTION public.search_profiles(
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT,
  bio TEXT,
  ip_masked TEXT,
  region TEXT,
  country_name TEXT,
  is_following BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_query TEXT := COALESCE(NULLIF(btrim(p_query), ''), '');
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS full_name,
    p.avatar_url,
    p.university,
    p.bio,
    g.ip_masked,
    g.region,
    g.country_name,
    EXISTS (
      SELECT 1
      FROM public.user_follows uf
      WHERE uf.follower_id = v_user_id
        AND uf.following_id = p.id
    ) AS is_following,
    CASE
      WHEN v_user_id IS NULL THEN FALSE
      ELSE public.is_mutual_follow(v_user_id, p.id)
    END AS is_mutual_follow
  FROM public.profiles p
  LEFT JOIN public.user_geo_profiles g ON g.user_id = p.id
  WHERE p.deactivated_at IS NULL
    AND (
      v_query = ''
      OR COALESCE(p.full_name, '') ILIKE '%' || v_query || '%'
      OR COALESCE(p.university, '') ILIKE '%' || v_query || '%'
      OR split_part(p.email, '@', 1) ILIKE '%' || v_query || '%'
    )
  ORDER BY p.verified DESC, p.updated_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_profiles(TEXT, INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
