-- 131_restore_directional_block_visibility.sql
--
-- Blocking prevents new direct messages and hides the blocker's public content
-- from the blocked account. It must not erase an existing conversation from
-- either participant's inbox, and the blocker must retain enough profile
-- visibility to identify and later unblock the account.

BEGIN;

CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  profile.gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::TEXT AS country_name,
  NULL::TEXT AS region,
  NULL::TEXT AS city
FROM public.profiles profile
WHERE profile.deactivated_at IS NULL
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks block_row
          WHERE block_row.blocker_id = profile.id
            AND block_row.blocked_id = auth.uid()
        )
      )
    )
  );

ALTER VIEW public.profile_public_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.profile_public_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.profile_public_view TO authenticated, service_role;

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
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    conversation.id,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user2_id
      ELSE conversation.user1_id
    END,
    CASE
      WHEN conversation.user1_id = v_me
      THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
      ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
    END,
    CASE
      WHEN conversation.user1_id = v_me THEN profile2.avatar_url
      ELSE profile1.avatar_url
    END,
    conversation.related_post_id,
    conversation.last_message_at,
    conversation.last_message_preview,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user1_unread_count
      ELSE conversation.user2_unread_count
    END,
    public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    ),
    public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
  FROM public.conversations conversation
  LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
  LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
  WHERE conversation.user1_id = v_me OR conversation.user2_id = v_me
  ORDER BY conversation.last_message_at DESC;
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
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    conversation.id,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user2_id
      ELSE conversation.user1_id
    END,
    CASE
      WHEN conversation.user1_id = v_me
      THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
      ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
    END,
    CASE
      WHEN conversation.user1_id = v_me THEN profile2.avatar_url
      ELSE profile1.avatar_url
    END,
    conversation.related_post_id,
    conversation.last_message_at,
    conversation.last_message_preview,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user1_unread_count
      ELSE conversation.user2_unread_count
    END,
    FALSE,
    FALSE
  FROM public.conversations conversation
  LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
  LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
  WHERE (conversation.user1_id = v_me OR conversation.user2_id = v_me)
    AND NOT public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
    AND EXISTS (
      SELECT 1
      FROM public.messages incoming
      WHERE incoming.conversation_id = conversation.id
        AND incoming.sender_id = CASE
          WHEN conversation.user1_id = v_me THEN conversation.user2_id
          ELSE conversation.user1_id
        END
        AND COALESCE(incoming.is_deleted, FALSE) = FALSE
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.messages outgoing
      WHERE outgoing.conversation_id = conversation.id
        AND outgoing.sender_id = v_me
        AND COALESCE(outgoing.is_deleted, FALSE) = FALSE
    )
  ORDER BY conversation.last_message_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_user_conversations(UUID)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_user_message_requests(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_message_requests(UUID)
  TO authenticated, service_role;

COMMIT;
