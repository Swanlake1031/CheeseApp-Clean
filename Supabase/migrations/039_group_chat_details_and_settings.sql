-- 039_group_chat_details_and_settings.sql
-- Group-chat detail capabilities:
-- 1) per-user mute settings for groups
-- 2) group member list RPC
-- 3) leave/disband group RPC

BEGIN;

-- ============================================
-- Per-user group conversation settings
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_chat_group_settings (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  is_muted BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, group_id)
);

CREATE INDEX IF NOT EXISTS user_chat_group_settings_group_idx
  ON public.user_chat_group_settings(group_id, updated_at DESC);

CREATE OR REPLACE FUNCTION public.touch_user_chat_group_settings_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_chat_group_settings_updated_at ON public.user_chat_group_settings;
CREATE TRIGGER trg_user_chat_group_settings_updated_at
BEFORE UPDATE ON public.user_chat_group_settings
FOR EACH ROW
EXECUTE FUNCTION public.touch_user_chat_group_settings_updated_at();

ALTER TABLE public.user_chat_group_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own group settings" ON public.user_chat_group_settings;
CREATE POLICY "Users can read own group settings"
  ON public.user_chat_group_settings
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own group settings" ON public.user_chat_group_settings;
CREATE POLICY "Users can insert own group settings"
  ON public.user_chat_group_settings
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own group settings" ON public.user_chat_group_settings;
CREATE POLICY "Users can update own group settings"
  ON public.user_chat_group_settings
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own group settings" ON public.user_chat_group_settings;
CREATE POLICY "Users can delete own group settings"
  ON public.user_chat_group_settings
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_chat_group_settings TO authenticated, service_role;

-- ============================================
-- Group members payload for group detail page
-- ============================================
CREATE OR REPLACE FUNCTION public.get_chat_group_members(p_group_id UUID)
RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  avatar_url TEXT,
  role TEXT,
  joined_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Group id is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.chat_group_members gm
    WHERE gm.group_id = p_group_id
      AND gm.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Only group members can view group member list';
  END IF;

  RETURN QUERY
  SELECT
    gm.user_id,
    COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS full_name,
    p.avatar_url,
    gm.role,
    gm.created_at AS joined_at
  FROM public.chat_group_members gm
  JOIN public.profiles p
    ON p.id = gm.user_id
  WHERE gm.group_id = p_group_id
  ORDER BY
    CASE WHEN gm.role = 'owner' THEN 0 ELSE 1 END,
    gm.created_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_chat_group_members(UUID)
  TO authenticated, service_role;

-- ============================================
-- Leave/disband group chat
-- Returns TRUE when owner disbands the group,
-- FALSE when a member leaves.
-- ============================================
CREATE OR REPLACE FUNCTION public.leave_chat_group(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_owner_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Group id is required';
  END IF;

  SELECT g.owner_id
    INTO v_owner_id
  FROM public.chat_groups g
  WHERE g.id = p_group_id;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Group not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.chat_group_members gm
    WHERE gm.group_id = p_group_id
      AND gm.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'You are not a group member';
  END IF;

  IF v_owner_id = v_me THEN
    DELETE FROM public.chat_groups g
    WHERE g.id = p_group_id
      AND g.owner_id = v_me;
    RETURN TRUE;
  END IF;

  DELETE FROM public.chat_group_members gm
  WHERE gm.group_id = p_group_id
    AND gm.user_id = v_me;

  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.leave_chat_group(UUID)
  TO authenticated, service_role;

-- ============================================
-- Owner self-heal: restore missing owner membership
-- ============================================
CREATE OR REPLACE FUNCTION public.recover_owned_group_membership(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_owner_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_group_id IS NULL THEN
    RAISE EXCEPTION 'Group id is required';
  END IF;

  SELECT g.owner_id
    INTO v_owner_id
  FROM public.chat_groups g
  WHERE g.id = p_group_id;

  IF v_owner_id IS NULL OR v_owner_id <> v_me THEN
    RETURN FALSE;
  END IF;

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  VALUES (p_group_id, v_me, 'owner')
  ON CONFLICT (group_id, user_id) DO UPDATE
    SET role = 'owner';

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.recover_owned_group_membership(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
