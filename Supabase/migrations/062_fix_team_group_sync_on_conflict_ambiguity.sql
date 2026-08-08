-- 062_fix_team_group_sync_on_conflict_ambiguity.sql
-- Fix runtime ambiguity inside create_or_sync_team_chat_group ON CONFLICT clause.

BEGIN;

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

  INSERT INTO public.chat_group_members AS cgm (group_id, user_id, role)
  VALUES (v_group_id, v_owner_id, 'owner')
  ON CONFLICT ON CONSTRAINT chat_group_members_pkey DO UPDATE
    SET role = 'owner';

  INSERT INTO public.chat_group_members AS cgm (group_id, user_id, role)
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
  ON CONFLICT ON CONSTRAINT chat_group_members_pkey DO NOTHING;

  RETURN QUERY SELECT v_group_id, v_created;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_or_sync_team_chat_group(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
