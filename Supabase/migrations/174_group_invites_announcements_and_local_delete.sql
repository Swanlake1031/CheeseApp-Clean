-- 174_group_invites_announcements_and_local_delete.sql
-- Allow every group member to invite their own mutual follows, add an
-- owner-managed announcement, and persist per-member inbox deletion state.

BEGIN;

ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS announcement TEXT;

ALTER TABLE public.chat_groups
  DROP CONSTRAINT IF EXISTS chat_groups_announcement_length;
ALTER TABLE public.chat_groups
  ADD CONSTRAINT chat_groups_announcement_length
  CHECK (
    announcement IS NULL
    OR char_length(btrim(announcement)) BETWEEN 1 AND 1000
  );

ALTER TABLE public.user_chat_group_settings
  ADD COLUMN IF NOT EXISTS hide_until_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.add_chat_group_members(
  p_group_id UUID,
  p_member_ids UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_member_id UUID;
  v_added INTEGER := 0;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.chat_group_members own_membership
    WHERE own_membership.group_id = p_group_id
      AND own_membership.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Only current group members can invite members'
      USING ERRCODE = '42501';
  END IF;

  FOREACH v_member_id IN ARRAY COALESCE(p_member_ids, ARRAY[]::UUID[])
  LOOP
    CONTINUE WHEN v_member_id IS NULL OR v_member_id = v_me;
    IF NOT public.is_mutual_follow(v_me, v_member_id) THEN
      RAISE EXCEPTION 'Only your mutual followers can be invited to group chat'
        USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.chat_group_members (group_id, user_id, role)
    VALUES (p_group_id, v_member_id, 'member')
    ON CONFLICT (group_id, user_id) DO NOTHING;
    IF FOUND THEN
      v_added := v_added + 1;
    END IF;
  END LOOP;

  RETURN v_added;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_chat_group_announcement(
  p_group_id UUID,
  p_announcement TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_announcement TEXT := NULLIF(btrim(COALESCE(p_announcement, '')), '');
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_announcement IS NOT NULL AND char_length(v_announcement) > 1000 THEN
    RAISE EXCEPTION 'Group announcement cannot exceed 1000 characters'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.chat_groups group_row
  SET announcement = v_announcement
  WHERE group_row.id = p_group_id
    AND group_row.owner_id = v_me;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only the group owner can update the announcement'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.add_chat_group_members(UUID, UUID[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_chat_group_announcement(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_chat_group_members(UUID, UUID[])
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_chat_group_announcement(UUID, TEXT)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
