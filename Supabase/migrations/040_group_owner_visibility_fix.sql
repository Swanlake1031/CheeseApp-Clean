-- 040_group_owner_visibility_fix.sql
-- Ensure group owners can still see their own groups even if membership row is missing.
-- This allows owner self-heal flows to reinsert owner membership.

BEGIN;

DROP POLICY IF EXISTS "Owner can view owned groups" ON public.chat_groups;
CREATE POLICY "Owner can view owned groups"
  ON public.chat_groups
  FOR SELECT
  TO authenticated
  USING (owner_id = auth.uid());

NOTIFY pgrst, 'reload schema';

COMMIT;
