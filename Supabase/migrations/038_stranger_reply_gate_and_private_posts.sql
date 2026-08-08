-- 038_stranger_reply_gate_and_private_posts.sql
-- 1) 陌生人私信改为「先发 1 条，需对方回复后才能继续发」
-- 2) 帖子新增私密开关，仅作者本人可见

BEGIN;

-- ============================================
-- 帖子私密字段
-- ============================================
ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS is_private BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.posts.is_private IS 'TRUE 表示帖子仅作者本人可见';

-- 活跃帖子公开可见策略：非作者仅可查看非私密帖子
DROP POLICY IF EXISTS "活跃帖子公开可见" ON public.posts;
CREATE POLICY "活跃帖子公开可见"
  ON public.posts
  FOR SELECT
  TO authenticated
  USING (
    status = 'active'
    AND (
      auth.uid() = user_id
      OR (
        is_private = FALSE
        AND NOT public.is_blocked_by(user_id, auth.uid())
      )
    )
  );

-- 图片可见性跟随 posts 的可见性（通过 posts RLS）
DROP POLICY IF EXISTS "帖子图片公开可见" ON public.post_images;
CREATE POLICY "帖子图片公开可见"
  ON public.post_images
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = post_images.post_id
    )
  );

-- 详情表可见性统一跟随 posts 的可见性（通过 posts RLS）
DROP POLICY IF EXISTS "租房帖子公开可见" ON public.rent_posts;
CREATE POLICY "租房帖子公开可见"
  ON public.rent_posts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = rent_posts.id
    )
  );

DROP POLICY IF EXISTS "二手帖子公开可见" ON public.secondhand_posts;
CREATE POLICY "二手帖子公开可见"
  ON public.secondhand_posts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = secondhand_posts.id
    )
  );

DROP POLICY IF EXISTS "拼车帖子公开可见" ON public.ride_posts;
CREATE POLICY "拼车帖子公开可见"
  ON public.ride_posts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = ride_posts.id
    )
  );

DROP POLICY IF EXISTS "组队帖子公开可见" ON public.team_posts;
CREATE POLICY "组队帖子公开可见"
  ON public.team_posts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = team_posts.id
    )
  );

DROP POLICY IF EXISTS "论坛帖子公开可见" ON public.forum_posts;
CREATE POLICY "论坛帖子公开可见"
  ON public.forum_posts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.posts p
      WHERE p.id = forum_posts.id
    )
  );

-- ============================================
-- 陌生人私信规则（需对方回复后才可继续发）
-- ============================================
CREATE OR REPLACE FUNCTION public.can_send_direct_message(
  p_conversation_id UUID,
  p_sender_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public, auth
AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
  v_other UUID;
  v_last_sender UUID;
BEGIN
  SELECT c.user1_id, c.user2_id
    INTO v_user1, v_user2
  FROM public.conversations c
  WHERE c.id = p_conversation_id;

  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_sender_id <> v_user1 AND p_sender_id <> v_user2 THEN
    RETURN FALSE;
  END IF;

  v_other := CASE WHEN p_sender_id = v_user1 THEN v_user2 ELSE v_user1 END;

  -- 任一方向被拉黑，均不可发送
  IF public.is_user_blocked(p_sender_id, v_other) THEN
    RETURN FALSE;
  END IF;

  -- 互关用户不受陌生人限制
  IF public.is_mutual_follow(p_sender_id, v_other) THEN
    RETURN TRUE;
  END IF;

  -- 陌生人规则：
  -- 1) 无历史消息：可发第一条
  -- 2) 最后一条是对方发的：可继续发
  -- 3) 最后一条是自己发的：不可继续发，直到对方回复
  SELECT m.sender_id
    INTO v_last_sender
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND COALESCE(m.is_deleted, FALSE) = FALSE
  ORDER BY m.created_at DESC
  LIMIT 1;

  IF v_last_sender IS NULL THEN
    RETURN TRUE;
  END IF;

  RETURN v_last_sender <> p_sender_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
