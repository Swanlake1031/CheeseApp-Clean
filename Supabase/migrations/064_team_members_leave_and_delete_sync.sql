-- 064_team_members_leave_and_delete_sync.sql
-- Allow approved team members to leave, allow organizers to remove members,
-- and keep team member counts in sync when rows are deleted.

CREATE OR REPLACE FUNCTION public.update_team_members_count()
RETURNS TRIGGER AS $$
DECLARE
  v_team_id UUID := COALESCE(NEW.team_id, OLD.team_id);
  v_approved_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO v_approved_count
  FROM public.team_members
  WHERE team_id = v_team_id
    AND status = 'approved';

  UPDATE public.team_posts
  SET
    current_members = 1 + v_approved_count,
    spots_available = CASE
      WHEN team_size IS NOT NULL THEN GREATEST(team_size - 1 - v_approved_count, 0)
      ELSE NULL
    END
  WHERE id = v_team_id;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS team_members_count_trigger ON public.team_members;

CREATE TRIGGER team_members_count_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.team_members
  FOR EACH ROW
  EXECUTE FUNCTION public.update_team_members_count();

DROP POLICY IF EXISTS "用户可以撤回团队申请" ON public.team_members;
DROP POLICY IF EXISTS "团队创建者或成员可以删除成员" ON public.team_members;

CREATE POLICY "团队创建者或成员可以删除成员"
  ON public.team_members
  FOR DELETE
  USING (
    NOT EXISTS (
      SELECT 1
      FROM public.posts owner_post
      WHERE owner_post.id = team_members.team_id
        AND owner_post.user_id = team_members.user_id
    )
    AND (
      auth.uid() = team_members.user_id
      OR EXISTS (
        SELECT 1
        FROM public.posts manager_post
        WHERE manager_post.id = team_members.team_id
          AND manager_post.user_id = auth.uid()
      )
    )
  );
