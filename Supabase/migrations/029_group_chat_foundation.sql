-- 029_group_chat_foundation.sql
-- Group chat foundation gated by mutual-follow requirement

CREATE TABLE IF NOT EXISTS public.chat_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.chat_group_members (
  group_id UUID NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.group_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  message_type TEXT NOT NULL DEFAULT 'text' CHECK (message_type IN ('text', 'image', 'post_share')),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS chat_group_members_user_idx
  ON public.chat_group_members(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS group_messages_group_created_idx
  ON public.group_messages(group_id, created_at DESC);

ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.touch_chat_groups_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_groups_updated_at ON public.chat_groups;
CREATE TRIGGER trg_chat_groups_updated_at
BEFORE UPDATE ON public.chat_groups
FOR EACH ROW
EXECUTE FUNCTION public.touch_chat_groups_updated_at();

DROP POLICY IF EXISTS "Members can view groups" ON public.chat_groups;
CREATE POLICY "Members can view groups"
  ON public.chat_groups
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_group_members gm
      WHERE gm.group_id = chat_groups.id
        AND gm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owner can update groups" ON public.chat_groups;
CREATE POLICY "Owner can update groups"
  ON public.chat_groups
  FOR UPDATE
  TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "Owner can delete groups" ON public.chat_groups;
CREATE POLICY "Owner can delete groups"
  ON public.chat_groups
  FOR DELETE
  TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS "Members can read group members" ON public.chat_group_members;
CREATE POLICY "Members can read group members"
  ON public.chat_group_members
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_group_members gm
      WHERE gm.group_id = chat_group_members.group_id
        AND gm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owner can manage members" ON public.chat_group_members;
CREATE POLICY "Owner can manage members"
  ON public.chat_group_members
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_group_members.group_id
        AND g.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_group_members.group_id
        AND g.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Members can read group messages" ON public.group_messages;
CREATE POLICY "Members can read group messages"
  ON public.group_messages
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_group_members gm
      WHERE gm.group_id = group_messages.group_id
        AND gm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Members can send group messages" ON public.group_messages;
CREATE POLICY "Members can send group messages"
  ON public.group_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.chat_group_members gm
      WHERE gm.group_id = group_messages.group_id
        AND gm.user_id = auth.uid()
    )
  );

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
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Group name is required';
  END IF;

  INSERT INTO public.chat_groups (owner_id, name)
  VALUES (v_owner_id, btrim(p_name))
  RETURNING id INTO v_group_id;

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  VALUES (v_group_id, v_owner_id, 'owner');

  FOREACH v_member_id IN ARRAY COALESCE(p_member_ids, ARRAY[]::UUID[])
  LOOP
    CONTINUE WHEN v_member_id IS NULL OR v_member_id = v_owner_id;

    IF NOT public.is_mutual_follow(v_owner_id, v_member_id) THEN
      RAISE EXCEPTION 'Only mutual followers can be invited to group chat';
    END IF;

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
