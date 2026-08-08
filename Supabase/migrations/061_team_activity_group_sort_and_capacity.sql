-- 061_team_activity_group_sort_and_capacity.sql
-- Align team-activity chat ordering to: event_time -> post_created_at, and expose team capacity in group previews.

BEGIN;

-- =========================================================
-- Auto create/sync team activity group: sort anchor = start time, else post creation.
-- =========================================================
CREATE OR REPLACE FUNCTION public.create_or_sync_team_chat_group(p_team_id UUID)
RETURNS TABLE (
  group_id UUID,
  created BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_owner_id UUID;
  v_team_title TEXT;
  v_sort_at TIMESTAMPTZ;
  v_group_id UUID;
  v_created BOOLEAN := FALSE;
  v_is_approved_member BOOLEAN := FALSE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required';
  END IF;

  SELECT
    p.user_id,
    p.title,
    COALESCE(t.event_time, p.created_at)
  INTO
    v_owner_id,
    v_team_title,
    v_sort_at
  FROM public.team_posts t
  JOIN public.posts p ON p.id = t.id
  WHERE t.id = p_team_id
    AND p.type = 'team'
  LIMIT 1;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Team post not found';
  END IF;

  IF v_me <> v_owner_id THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.team_members tm
      WHERE tm.team_id = p_team_id
        AND tm.user_id = v_me
        AND tm.status = 'approved'
    ) INTO v_is_approved_member;

    IF NOT v_is_approved_member THEN
      RAISE EXCEPTION 'Only organizer or approved members can sync team activity group';
    END IF;
  END IF;

  SELECT g.id
  INTO v_group_id
  FROM public.chat_groups g
  WHERE g.source_type = 'team'
    AND g.source_post_id = p_team_id
  ORDER BY g.created_at ASC
  LIMIT 1;

  IF v_group_id IS NULL THEN
    INSERT INTO public.chat_groups (
      owner_id,
      name,
      source_type,
      source_post_id,
      source_sort_at
    )
    VALUES (
      v_owner_id,
      COALESCE(NULLIF(btrim(v_team_title), ''), '组队活动') || ' · 活动群',
      'team',
      p_team_id,
      v_sort_at
    )
    RETURNING id INTO v_group_id;
    v_created := TRUE;
  ELSE
    UPDATE public.chat_groups g
    SET
      source_sort_at = v_sort_at,
      source_post_id = p_team_id,
      source_type = 'team'
    WHERE g.id = v_group_id;
  END IF;

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  VALUES (v_group_id, v_owner_id, 'owner')
  ON CONFLICT (group_id, user_id) DO UPDATE
    SET role = 'owner';

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  SELECT
    v_group_id,
    source_members.user_id,
    CASE WHEN source_members.user_id = v_owner_id THEN 'owner' ELSE 'member' END
  FROM (
    SELECT v_owner_id AS user_id
    UNION
    SELECT tm.user_id
    FROM public.team_members tm
    WHERE tm.team_id = p_team_id
      AND tm.status = 'approved'
  ) AS source_members
  ON CONFLICT (group_id, user_id) DO NOTHING;

  RETURN QUERY SELECT v_group_id, v_created;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_or_sync_team_chat_group(UUID)
  TO authenticated, service_role;

-- Backfill existing team activity groups to the new sort anchor semantics.
UPDATE public.chat_groups g
SET source_sort_at = COALESCE(tp.event_time, p.created_at)
FROM public.team_posts tp
JOIN public.posts p ON p.id = tp.id
WHERE g.source_type = 'team'
  AND g.source_post_id = tp.id;

-- =========================================================
-- Group list RPC: include team capacity + new source_sort_at fallback.
-- =========================================================
DROP FUNCTION IF EXISTS public.get_user_chat_groups(UUID);

CREATE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER,
  unread_count INTEGER,
  source_type TEXT,
  source_post_id UUID,
  source_sort_at TIMESTAMPTZ,
  team_title TEXT,
  team_event_time TIMESTAMPTZ,
  team_deadline DATE,
  team_location TEXT,
  team_capacity INTEGER
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    g.id,
    g.name,
    g.avatar_url,
    COALESCE(last_msg.created_at, g.updated_at) AS last_message_at,
    last_msg.preview AS last_message_preview,
    COALESCE(member_stats.member_count, 1) AS member_count,
    COALESCE(unread_stats.unread_count, 0) AS unread_count,
    g.source_type,
    g.source_post_id,
    COALESCE(g.source_sort_at, tp.event_time, post_ref.created_at, g.created_at) AS source_sort_at,
    post_ref.title AS team_title,
    tp.event_time AS team_event_time,
    tp.deadline AS team_deadline,
    tp.meeting_location AS team_location,
    tp.team_size AS team_capacity
  FROM public.chat_groups g
  JOIN public.chat_group_members me
    ON me.group_id = g.id
   AND me.user_id = p_user_id
  LEFT JOIN public.user_chat_group_settings ugs
    ON ugs.group_id = g.id
   AND ugs.user_id = p_user_id
  LEFT JOIN public.team_posts tp
    ON g.source_type = 'team'
   AND g.source_post_id = tp.id
  LEFT JOIN public.posts post_ref
    ON post_ref.id = tp.id
  LEFT JOIN LATERAL (
    SELECT
      gm.created_at,
      CASE
        WHEN gm.message_type = 'image' THEN '📷 Photo'
        ELSE LEFT(gm.content, 120)
      END AS preview
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
    ORDER BY gm.created_at DESC
    LIMIT 1
  ) last_msg ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS member_count
    FROM public.chat_group_members gm
    WHERE gm.group_id = g.id
  ) member_stats ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS unread_count
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
      AND gm.sender_id <> p_user_id
      AND gm.created_at > COALESCE(ugs.last_read_at, me.created_at, 'epoch'::timestamptz)
  ) unread_stats ON TRUE
  ORDER BY
    CASE WHEN g.source_type = 'team' THEN 0 ELSE 1 END,
    CASE
      WHEN g.source_type = 'team'
      THEN COALESCE(g.source_sort_at, tp.event_time, post_ref.created_at, g.created_at)
      ELSE NULL
    END ASC NULLS LAST,
    COALESCE(last_msg.created_at, g.updated_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
