-- 057_team_members_cancel_request_policy.sql
-- 允许用户撤回自己的组队申请（pending）

DROP POLICY IF EXISTS "用户可以撤回团队申请" ON public.team_members;

CREATE POLICY "用户可以撤回团队申请"
  ON public.team_members
  FOR DELETE
  USING (
    auth.uid() = user_id
    AND status = 'pending'
  );
