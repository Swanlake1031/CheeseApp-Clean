-- 041_group_create_require_mutual_member.sql
-- Group creator is always a member; at least one invited mutual-follow user is required.

BEGIN;

CREATE OR REPLACE FUNCTION public.create_chat_group(
  p_name TEXT,
  p_member_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_owner_id UUID := auth.uid();
  v_group_id UUID;
  v_member_id UUID;
  v_valid_member_count INTEGER := 0;
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Group name is required';
  END IF;

  -- Validate invitees before creating group row.
  FOREACH v_member_id IN ARRAY COALESCE(p_member_ids, ARRAY[]::UUID[])
  LOOP
    CONTINUE WHEN v_member_id IS NULL OR v_member_id = v_owner_id;

    IF NOT public.is_mutual_follow(v_owner_id, v_member_id) THEN
      RAISE EXCEPTION 'Only mutual followers can be invited to group chat';
    END IF;

    v_valid_member_count := v_valid_member_count + 1;
  END LOOP;

  IF v_valid_member_count < 1 THEN
    RAISE EXCEPTION 'At least one mutual follower is required';
  END IF;

  INSERT INTO public.chat_groups (owner_id, name)
  VALUES (v_owner_id, btrim(p_name))
  RETURNING id INTO v_group_id;

  -- Owner is always in the group by default.
  INSERT INTO public.chat_group_members (group_id, user_id, role)
  VALUES (v_group_id, v_owner_id, 'owner');

  FOREACH v_member_id IN ARRAY COALESCE(p_member_ids, ARRAY[]::UUID[])
  LOOP
    CONTINUE WHEN v_member_id IS NULL OR v_member_id = v_owner_id;

    INSERT INTO public.chat_group_members (group_id, user_id, role)
    VALUES (v_group_id, v_member_id, 'member')
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN v_group_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_chat_group(TEXT, UUID[])
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
