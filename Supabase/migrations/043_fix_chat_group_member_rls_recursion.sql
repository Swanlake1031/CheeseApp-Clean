-- 043_fix_chat_group_member_rls_recursion.sql
-- Fix RLS recursion on chat_group_members by using SECURITY DEFINER helpers.

BEGIN;

CREATE OR REPLACE FUNCTION public.is_chat_group_member(
  p_group_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_group_members gm
    WHERE gm.group_id = p_group_id
      AND gm.user_id = COALESCE(p_user_id, auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.is_chat_group_owner(
  p_group_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_groups g
    WHERE g.id = p_group_id
      AND g.owner_id = COALESCE(p_user_id, auth.uid())
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_chat_group_member(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_chat_group_owner(UUID, UUID)
  TO authenticated, service_role;

DROP POLICY IF EXISTS "Members can read group members" ON public.chat_group_members;
CREATE POLICY "Members can read group members"
  ON public.chat_group_members
  FOR SELECT
  TO authenticated
  USING (
    public.is_chat_group_member(chat_group_members.group_id, auth.uid())
  );

DROP POLICY IF EXISTS "Owner can manage members" ON public.chat_group_members;
CREATE POLICY "Owner can manage members"
  ON public.chat_group_members
  FOR ALL
  TO authenticated
  USING (
    public.is_chat_group_owner(chat_group_members.group_id, auth.uid())
  )
  WITH CHECK (
    public.is_chat_group_owner(chat_group_members.group_id, auth.uid())
  );

DROP POLICY IF EXISTS "Members can read group messages" ON public.group_messages;
CREATE POLICY "Members can read group messages"
  ON public.group_messages
  FOR SELECT
  TO authenticated
  USING (
    public.is_chat_group_member(group_messages.group_id, auth.uid())
  );

DROP POLICY IF EXISTS "Members can send group messages" ON public.group_messages;
CREATE POLICY "Members can send group messages"
  ON public.group_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    sender_id = auth.uid()
    AND public.is_chat_group_member(group_messages.group_id, auth.uid())
  );

NOTIFY pgrst, 'reload schema';

COMMIT;
