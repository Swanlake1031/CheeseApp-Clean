-- ============================================
-- 010_reports_and_feedback.sql
-- 舉報與使用者反饋
-- ============================================

-- ============================================
-- 帖子舉報表
-- ============================================
CREATE TABLE IF NOT EXISTS post_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE NOT NULL,
  reporter_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  reason TEXT NOT NULL CHECK (reason IN ('spam', 'harassment', 'fraud', 'inappropriate', 'misleading', 'other')),
  details TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewing', 'resolved', 'dismissed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(reporter_id, post_id)
);

CREATE INDEX IF NOT EXISTS post_reports_post_idx ON post_reports (post_id);
CREATE INDEX IF NOT EXISTS post_reports_reporter_idx ON post_reports (reporter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS post_reports_status_idx ON post_reports (status, created_at DESC);

-- ============================================
-- 使用者反饋表
-- ============================================
CREATE TABLE IF NOT EXISTS user_feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
  category TEXT NOT NULL DEFAULT 'other' CHECK (category IN ('bug', 'feature', 'ui', 'performance', 'account', 'other')),
  message TEXT NOT NULL,
  contact_email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS user_feedback_user_idx ON user_feedback (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS user_feedback_category_idx ON user_feedback (category, created_at DESC);

-- ============================================
-- RLS
-- ============================================
ALTER TABLE post_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_feedback ENABLE ROW LEVEL SECURITY;

-- post_reports policies
DROP POLICY IF EXISTS "用户可以提交帖子举报" ON post_reports;
CREATE POLICY "用户可以提交帖子举报" ON post_reports
  FOR INSERT
  WITH CHECK (auth.uid() = reporter_id);

DROP POLICY IF EXISTS "用户仅可查看自己提交的举报" ON post_reports;
CREATE POLICY "用户仅可查看自己提交的举报" ON post_reports
  FOR SELECT
  USING (auth.uid() = reporter_id);

-- user_feedback policies
DROP POLICY IF EXISTS "用户可以提交反馈" ON user_feedback;
CREATE POLICY "用户可以提交反馈" ON user_feedback
  FOR INSERT
  WITH CHECK (user_id IS NULL OR auth.uid() = user_id);

DROP POLICY IF EXISTS "用户仅可查看自己的反馈" ON user_feedback;
CREATE POLICY "用户仅可查看自己的反馈" ON user_feedback
  FOR SELECT
  USING (user_id IS NULL OR auth.uid() = user_id);

NOTIFY pgrst, 'reload schema';
