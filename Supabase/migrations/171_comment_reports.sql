-- Add first-class comment reporting without overloading post reports.

BEGIN;

CREATE TABLE IF NOT EXISTS public.comment_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id UUID NOT NULL REFERENCES public.comments(id) ON DELETE CASCADE,
  reporter_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (
    reason IN ('spam', 'harassment', 'fraud', 'inappropriate', 'misleading', 'other')
  ),
  details TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'reviewing', 'resolved', 'dismissed')
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reporter_id, comment_id)
);

CREATE INDEX IF NOT EXISTS comment_reports_comment_idx
  ON public.comment_reports (comment_id);
CREATE INDEX IF NOT EXISTS comment_reports_reporter_idx
  ON public.comment_reports (reporter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS comment_reports_status_idx
  ON public.comment_reports (status, created_at DESC);

ALTER TABLE public.comment_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can submit comment reports" ON public.comment_reports;
CREATE POLICY "Users can submit comment reports"
ON public.comment_reports FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = reporter_id
  AND EXISTS (
    SELECT 1
    FROM public.comments comment_row
    JOIN public.posts post_row ON post_row.id = comment_row.post_id
    WHERE comment_row.id = comment_reports.comment_id
      AND comment_row.user_id <> auth.uid()
      AND comment_row.is_deleted = FALSE
      AND post_row.status <> 'deleted'
  )
);

DROP POLICY IF EXISTS "Users can view their comment reports" ON public.comment_reports;
CREATE POLICY "Users can view their comment reports"
ON public.comment_reports FOR SELECT TO authenticated
USING (auth.uid() = reporter_id);

DROP POLICY IF EXISTS "Forum managers can review comment reports" ON public.comment_reports;
CREATE POLICY "Forum managers can review comment reports"
ON public.comment_reports FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.comments comment_row
    JOIN public.forum_posts forum_post ON forum_post.id = comment_row.post_id
    WHERE comment_row.id = comment_reports.comment_id
      AND public.can_manage_forum_board(forum_post.board_id)
  )
);

DROP POLICY IF EXISTS "Forum managers can resolve comment reports" ON public.comment_reports;
CREATE POLICY "Forum managers can resolve comment reports"
ON public.comment_reports FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.comments comment_row
    JOIN public.forum_posts forum_post ON forum_post.id = comment_row.post_id
    WHERE comment_row.id = comment_reports.comment_id
      AND public.can_manage_forum_board(forum_post.board_id)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.comments comment_row
    JOIN public.forum_posts forum_post ON forum_post.id = comment_row.post_id
    WHERE comment_row.id = comment_reports.comment_id
      AND public.can_manage_forum_board(forum_post.board_id)
  )
);

REVOKE ALL ON TABLE public.comment_reports FROM PUBLIC, anon;
GRANT INSERT, SELECT ON TABLE public.comment_reports TO authenticated;
GRANT UPDATE ON TABLE public.comment_reports TO authenticated;
GRANT ALL ON TABLE public.comment_reports TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
