-- 099_forum_boards_and_reset.sql
-- Replace the legacy Forum category/tag model with first-class boards.
--
-- DESTRUCTIVE DATA CHANGE
-- - Deletes every existing Forum post and its comments, reactions, favorites,
--   reports, featured placement, image rows, and chat share/contact references.
-- - Supabase forbids SQL deletion from storage.objects. After this transaction,
--   remove the exact Forum image paths captured in the pre-deploy backup through
--   the Storage API. Do not delete a user folder recursively.
-- - The deleted content cannot be reconstructed by this migration.
-- - Take a database backup before production deployment and verify the linked
--   Supabase project. Deploy migration 099 before shipping the board-based app.
-- - Rolling the schema back does not restore deleted content or storage files.

BEGIN;

-- Functions with parsed references to the old view must be replaced after the
-- view is rebuilt. The legacy convenience RPC is removed instead of kept as a
-- hidden second category-based creation path.
DROP FUNCTION IF EXISTS public.search_posts(TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS public.create_forum_post(UUID, TEXT, TEXT, TEXT, TEXT[], BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS public.get_hot_forum_posts(INTEGER);
DROP VIEW IF EXISTS public.forum_posts_view;

CREATE TABLE public.forum_boards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  rules TEXT NOT NULL DEFAULT '',
  icon TEXT NOT NULL DEFAULT 'bubble.left.and.bubble.right.fill',
  cover_image_url TEXT,
  school_id UUID REFERENCES public.schools(id) ON DELETE CASCADE,
  is_official BOOLEAN NOT NULL DEFAULT TRUE,
  allows_anonymous_posts BOOLEAN NOT NULL DEFAULT FALSE,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed', 'archived')),
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT forum_boards_slug_format
    CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,47}$'),
  CONSTRAINT forum_boards_name_length
    CHECK (char_length(btrim(name)) BETWEEN 1 AND 40)
);

CREATE TABLE public.forum_admins (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  granted_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.forum_board_memberships (
  board_id UUID NOT NULL REFERENCES public.forum_boards(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member'
    CHECK (role IN ('member', 'moderator', 'admin')),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (board_id, user_id)
);

CREATE INDEX forum_boards_school_status_idx
  ON public.forum_boards(school_id, status, name);
CREATE INDEX forum_board_memberships_user_idx
  ON public.forum_board_memberships(user_id, board_id);
CREATE INDEX forum_board_memberships_admin_idx
  ON public.forum_board_memberships(board_id, role)
  WHERE role IN ('moderator', 'admin');

CREATE TRIGGER forum_boards_updated_at
BEFORE UPDATE ON public.forum_boards
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.forum_boards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_board_memberships ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_forum_admin(
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT p_user_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.forum_admins fa WHERE fa.user_id = p_user_id
    );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_forum_board(
  p_board_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.is_forum_admin(p_user_id)
    OR EXISTS (
      SELECT 1
      FROM public.forum_board_memberships fbm
      WHERE fbm.board_id = p_board_id
        AND fbm.user_id = p_user_id
        AND fbm.role IN ('moderator', 'admin')
    );
$$;

CREATE OR REPLACE FUNCTION public.can_administer_forum_board(
  p_board_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.is_forum_admin(p_user_id)
    OR EXISTS (
      SELECT 1
      FROM public.forum_board_memberships fbm
      WHERE fbm.board_id = p_board_id
        AND fbm.user_id = p_user_id
        AND fbm.role = 'admin'
    );
$$;

REVOKE ALL ON FUNCTION public.is_forum_admin(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_manage_forum_board(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_administer_forum_board(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_forum_admin(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_manage_forum_board(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_administer_forum_board(UUID, UUID) TO authenticated, service_role;

CREATE POLICY "Authenticated users can read visible Forum boards"
ON public.forum_boards FOR SELECT TO authenticated
USING (status <> 'archived' OR public.can_manage_forum_board(id));

CREATE POLICY "Forum admins can create boards"
ON public.forum_boards FOR INSERT TO authenticated
WITH CHECK (public.is_forum_admin() AND created_by = auth.uid());

CREATE POLICY "Forum managers can update boards"
ON public.forum_boards FOR UPDATE TO authenticated
USING (public.can_administer_forum_board(id))
WITH CHECK (public.can_administer_forum_board(id));

CREATE POLICY "Forum admins can delete boards"
ON public.forum_boards FOR DELETE TO authenticated
USING (public.is_forum_admin());

CREATE POLICY "Users can read board memberships"
ON public.forum_board_memberships FOR SELECT TO authenticated
USING (TRUE);

CREATE POLICY "Users can join active boards"
ON public.forum_board_memberships FOR INSERT TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND role = 'member'
  AND EXISTS (
    SELECT 1 FROM public.forum_boards b
    WHERE b.id = board_id AND b.status = 'active'
  )
);

CREATE POLICY "Board admins can add memberships"
ON public.forum_board_memberships FOR INSERT TO authenticated
WITH CHECK (public.can_administer_forum_board(board_id));

CREATE POLICY "Users and managers can leave or remove memberships"
ON public.forum_board_memberships FOR DELETE TO authenticated
USING (user_id = auth.uid() OR public.can_administer_forum_board(board_id));

CREATE POLICY "Forum managers can assign board roles"
ON public.forum_board_memberships FOR UPDATE TO authenticated
USING (public.can_administer_forum_board(board_id))
WITH CHECK (public.can_administer_forum_board(board_id));

CREATE POLICY "Users can read their Forum admin record"
ON public.forum_admins FOR SELECT TO authenticated
USING (user_id = auth.uid());

REVOKE ALL ON public.forum_admins FROM anon, authenticated;
GRANT SELECT ON public.forum_admins TO authenticated;
GRANT ALL ON public.forum_admins TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.forum_boards TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.forum_board_memberships TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_forum_board_member_role(
  p_board_id UUID,
  p_user_id UUID,
  p_role TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF p_role NOT IN ('member', 'moderator', 'admin') THEN
    RAISE EXCEPTION 'Invalid Forum board role';
  END IF;

  INSERT INTO public.forum_board_memberships (board_id, user_id, role)
  VALUES (p_board_id, p_user_id, p_role)
  ON CONFLICT (board_id, user_id) DO UPDATE SET role = EXCLUDED.role;
END;
$$;

REVOKE ALL ON FUNCTION public.set_forum_board_member_role(UUID, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_forum_board_member_role(UUID, UUID, TEXT)
  TO authenticated, service_role;

-- Seed exactly five real global boards. "All" remains a client aggregate and
-- is intentionally absent from this table.
INSERT INTO public.forum_boards (
  id, slug, name, description, rules, icon, is_official,
  allows_anonymous_posts, status
) VALUES
  (
    'f0000000-0000-0000-0000-000000000001', 'confessions', '表白区',
    '用于校园表白、寻找同学、感谢、偶遇和情感表达。',
    '请尊重他人隐私；不得公开未经同意的个人信息；禁止骚扰与人身攻击。',
    'heart.fill', TRUE, TRUE, 'active'
  ),
  (
    'f0000000-0000-0000-0000-000000000002', 'academics', '学术',
    '课程、考试、作业、学习方法及校园学术信息交流。',
    '请遵守学校学术诚信要求；不得交换考试答案或代写；信息请尽量注明课程与学期。',
    'graduationcap.fill', TRUE, FALSE, 'active'
  ),
  (
    'f0000000-0000-0000-0000-000000000003', 'sports', '运动',
    '篮球、羽毛球、健身、跑步、约球和校园体育活动讨论。',
    '活动信息请写明时间地点；请勿发布危险、欺诈或未经许可的商业活动。',
    'figure.run', TRUE, FALSE, 'active'
  ),
  (
    'f0000000-0000-0000-0000-000000000004', 'campus-talk', '八卦',
    '校园趣事、热点讨论、吐槽和轻松话题。',
    '禁止曝光个人敏感信息、造谣、人肉搜索及针对个人的恶意攻击。',
    'bubble.left.and.text.bubble.right.fill', TRUE, TRUE, 'active'
  ),
  (
    'f0000000-0000-0000-0000-000000000005', 'tree-hole', '树洞',
    '倾诉、情绪表达、个人烦恼和不便公开身份的话题。',
    '请保护自己与他人的隐私；危机内容会按安全规则处理；禁止骚扰与仇恨内容。',
    'moon.stars.fill', TRUE, TRUE, 'active'
  )
ON CONFLICT (id) DO UPDATE SET
  slug = EXCLUDED.slug,
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  rules = EXCLUDED.rules,
  icon = EXCLUDED.icon,
  is_official = EXCLUDED.is_official,
  allows_anonymous_posts = EXCLUDED.allows_anonymous_posts,
  status = EXCLUDED.status,
  updated_at = NOW();

-- Capture non-cascading relationships and storage paths before deleting posts.
CREATE TEMP TABLE forum_reset_post_ids ON COMMIT DROP AS
SELECT p.id
FROM public.posts p
WHERE p.type = 'forum';

CREATE TEMP TABLE forum_reset_comment_ids ON COMMIT DROP AS
SELECT c.id
FROM public.comments c
JOIN forum_reset_post_ids p ON p.id = c.post_id;

-- Legacy aggregate counters are not reliable enough to decrement safely during
-- a bulk reset. Temporarily disable only application triggers, delete exact
-- Forum dependencies, then restore triggers before continuing.
ALTER TABLE public.likes DISABLE TRIGGER USER;
ALTER TABLE public.comments DISABLE TRIGGER USER;
ALTER TABLE public.favorites DISABLE TRIGGER USER;

-- Legacy aggregate counters are not reliable enough to decrement safely during
-- a bulk reset. Temporarily disable only application triggers, delete exact
-- Forum dependencies, then restore triggers before continuing.
ALTER TABLE public.likes DISABLE TRIGGER USER;
ALTER TABLE public.comments DISABLE TRIGGER USER;
ALTER TABLE public.favorites DISABLE TRIGGER USER;

DELETE FROM public.likes l
WHERE (l.target_type = 'post' AND l.target_id IN (SELECT id FROM forum_reset_post_ids))
   OR (l.target_type = 'comment' AND l.target_id IN (SELECT id FROM forum_reset_comment_ids));

DELETE FROM public.comments c
WHERE c.id IN (SELECT id FROM forum_reset_comment_ids);

DELETE FROM public.favorites f
WHERE f.post_id IN (SELECT id FROM forum_reset_post_ids);

ALTER TABLE public.likes ENABLE TRIGGER USER;
ALTER TABLE public.comments ENABLE TRIGGER USER;
ALTER TABLE public.favorites ENABLE TRIGGER USER;

DELETE FROM public.comments c
WHERE c.id IN (SELECT id FROM forum_reset_comment_ids);

DELETE FROM public.favorites f
WHERE f.post_id IN (SELECT id FROM forum_reset_post_ids);

ALTER TABLE public.likes ENABLE TRIGGER USER;
ALTER TABLE public.comments ENABLE TRIGGER USER;
ALTER TABLE public.favorites ENABLE TRIGGER USER;

-- A chat share is a denormalized card, not a foreign-key relation. Remove only
-- card keys that point at deleted Forum posts and keep unrelated message data.
UPDATE public.messages m
SET metadata = m.metadata - 'shared_post_card'
WHERE m.metadata->'shared_post_card'->>'post_id'
  IN (SELECT id::TEXT FROM forum_reset_post_ids);

UPDATE public.messages m
SET metadata = m.metadata - 'post_contact_card'
WHERE m.metadata->'post_contact_card'->>'post_id'
  IN (SELECT id::TEXT FROM forum_reset_post_ids);

-- comments, favorites, post_images, reports, view history, Forum details and
-- Home featured rows cascade from posts. conversations.related_post_id becomes
-- NULL through its existing foreign key.
DELETE FROM public.posts p
WHERE p.id IN (SELECT id FROM forum_reset_post_ids);

DROP INDEX IF EXISTS public.forum_posts_category_idx;
DROP INDEX IF EXISTS public.forum_posts_tags_idx;

ALTER TABLE public.forum_posts
  DROP COLUMN IF EXISTS category,
  DROP COLUMN IF EXISTS tags,
  ADD COLUMN board_id UUID NOT NULL
    REFERENCES public.forum_boards(id) ON DELETE RESTRICT;

CREATE INDEX forum_posts_board_created_idx
  ON public.forum_posts(board_id, is_pinned DESC, id DESC);
CREATE INDEX forum_posts_board_hot_idx
  ON public.forum_posts(board_id, hot_score DESC, id DESC);

CREATE OR REPLACE FUNCTION public.enforce_forum_board_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_status TEXT;
  v_allows_anonymous BOOLEAN;
  v_is_anonymous BOOLEAN;
  v_post_type TEXT;
BEGIN
  SELECT status, allows_anonymous_posts
  INTO v_status, v_allows_anonymous
  FROM public.forum_boards
  WHERE id = NEW.board_id;

  IF v_status IS NULL OR v_status <> 'active' THEN
    RAISE EXCEPTION 'Posts can only be published to an active Forum board';
  END IF;

  SELECT type, is_anonymous INTO v_post_type, v_is_anonymous
  FROM public.posts WHERE id = NEW.id;

  IF v_post_type IS DISTINCT FROM 'forum' THEN
    RAISE EXCEPTION 'Forum details must reference a Forum base post';
  END IF;

  IF COALESCE(v_is_anonymous, FALSE) AND NOT v_allows_anonymous THEN
    RAISE EXCEPTION 'This Forum board does not allow anonymous posts';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER forum_posts_enforce_board_rules
BEFORE INSERT OR UPDATE OF board_id ON public.forum_posts
FOR EACH ROW EXECUTE FUNCTION public.enforce_forum_board_rules();

CREATE OR REPLACE FUNCTION public.enforce_forum_anonymous_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  IF NEW.type = 'forum' AND COALESCE(NEW.is_anonymous, FALSE) THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.forum_posts f
      JOIN public.forum_boards b ON b.id = f.board_id
      WHERE f.id = NEW.id
        AND b.status = 'active'
        AND b.allows_anonymous_posts
    ) THEN
      RAISE EXCEPTION 'This Forum board does not allow anonymous posts';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER posts_enforce_forum_anonymous_update
BEFORE UPDATE OF is_anonymous ON public.posts
FOR EACH ROW
WHEN (NEW.is_anonymous IS DISTINCT FROM OLD.is_anonymous)
EXECUTE FUNCTION public.enforce_forum_anonymous_update();

-- Editing spans the base row and Forum detail row. Keep both updates in one
-- transaction and order them around the anonymous-board trigger so a valid
-- board move cannot leave a partially edited post.
CREATE OR REPLACE FUNCTION public.update_forum_post(
  p_post_id UUID,
  p_board_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_allow_comments BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Forum post title cannot be empty';
  END IF;

  IF p_is_anonymous THEN
    UPDATE public.forum_posts
    SET board_id = p_board_id,
        allow_comments = p_allow_comments
    WHERE id = p_post_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Forum post not found or not editable';
    END IF;

    UPDATE public.posts
    SET title = BTRIM(p_title),
        description = NULLIF(BTRIM(p_description), ''),
        is_anonymous = TRUE,
        is_private = p_is_private
    WHERE id = p_post_id AND type = 'forum';
  ELSE
    UPDATE public.posts
    SET title = BTRIM(p_title),
        description = NULLIF(BTRIM(p_description), ''),
        is_anonymous = FALSE,
        is_private = p_is_private
    WHERE id = p_post_id AND type = 'forum';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Forum post not found or not editable';
    END IF;

    UPDATE public.forum_posts
    SET board_id = p_board_id,
        allow_comments = p_allow_comments
    WHERE id = p_post_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Forum post not found or not editable';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_forum_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_forum_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN
) TO authenticated, service_role;

CREATE POLICY "Forum managers can update Forum post details"
ON public.forum_posts FOR UPDATE TO authenticated
USING (public.can_manage_forum_board(board_id))
WITH CHECK (public.can_manage_forum_board(board_id));

CREATE POLICY "Forum managers can delete Forum post details"
ON public.forum_posts FOR DELETE TO authenticated
USING (public.can_manage_forum_board(board_id));

CREATE POLICY "Forum managers can update Forum base posts"
ON public.posts FOR UPDATE TO authenticated
USING (
  type = 'forum' AND EXISTS (
    SELECT 1 FROM public.forum_posts f
    WHERE f.id = posts.id AND public.can_manage_forum_board(f.board_id)
  )
)
WITH CHECK (type = 'forum');

CREATE POLICY "Forum managers can delete Forum base posts"
ON public.posts FOR DELETE TO authenticated
USING (
  type = 'forum' AND EXISTS (
    SELECT 1 FROM public.forum_posts f
    WHERE f.id = posts.id AND public.can_manage_forum_board(f.board_id)
  )
);

CREATE POLICY "Forum managers can review board reports"
ON public.post_reports FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.forum_posts f
    WHERE f.id = post_reports.post_id
      AND public.can_manage_forum_board(f.board_id)
  )
);

CREATE POLICY "Forum managers can resolve board reports"
ON public.post_reports FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.forum_posts f
    WHERE f.id = post_reports.post_id
      AND public.can_manage_forum_board(f.board_id)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.forum_posts f
    WHERE f.id = post_reports.post_id
      AND public.can_manage_forum_board(f.board_id)
  )
);

CREATE OR REPLACE VIEW public.forum_boards_view AS
SELECT
  b.*,
  COUNT(m.user_id)::INTEGER AS member_count,
  EXISTS (
    SELECT 1 FROM public.forum_board_memberships own
    WHERE own.board_id = b.id AND own.user_id = auth.uid()
  ) AS is_joined,
  (
    SELECT own.role FROM public.forum_board_memberships own
    WHERE own.board_id = b.id AND own.user_id = auth.uid()
  ) AS viewer_role,
  public.can_manage_forum_board(b.id) AS can_manage,
  public.can_administer_forum_board(b.id) AS can_administer
FROM public.forum_boards b
LEFT JOIN public.forum_board_memberships m ON m.board_id = b.id
GROUP BY b.id;

ALTER VIEW public.forum_boards_view SET (security_invoker = true);
GRANT SELECT ON public.forum_boards_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id,
  f.board_id,
  b.slug AS board_slug,
  b.name AS board_name,
  b.icon AS board_icon,
  b.allows_anonymous_posts AS board_allows_anonymous,
  f.allow_comments,
  f.is_pinned,
  f.is_locked,
  f.like_count,
  f.comment_count,
  tier.effective_highlight_type AS highlight_type,
  f.pinned_until,
  f.view_count,
  f.save_count,
  public.calculate_hot_score(
    f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
  CASE WHEN p.is_anonymous THEN NULL ELSE pr.full_name END AS user_name,
  CASE WHEN p.is_anonymous THEN NULL ELSE pr.avatar_url END AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi WHERE pi.post_id = f.id
    ),
    '[]'::JSON
  ) AS images,
  CASE WHEN p.is_anonymous THEN FALSE ELSE COALESCE(pr.is_official, FALSE) END
    AS user_official
FROM public.forum_posts f
JOIN public.posts p ON p.id = f.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.forum_boards b ON b.id = f.board_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    ) AND f.pinned_until IS NOT NULL AND f.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE f.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active' AND b.status <> 'archived';

ALTER VIEW public.forum_posts_view SET (security_invoker = true);
GRANT SELECT ON public.forum_posts_view TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_hot_forum_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.forum_posts_view
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT *
  FROM public.forum_posts_view
  ORDER BY highlight_rank, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

GRANT EXECUTE ON FUNCTION public.get_hot_forum_posts(INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_hot_forum_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.forum_posts_view
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT *
  FROM public.forum_posts_view
  ORDER BY highlight_rank, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

GRANT EXECUTE ON FUNCTION public.get_hot_forum_posts(INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.search_posts(
  p_query TEXT DEFAULT '',
  p_category TEXT DEFAULT 'all',
  p_limit INTEGER DEFAULT 80
)
RETURNS TABLE (
  id UUID,
  category TEXT,
  title TEXT,
  subtitle TEXT,
  preview_image_url TEXT,
  created_at TIMESTAMPTZ,
  hot_score DOUBLE PRECISION,
  highlight_type TEXT,
  highlight_rank INTEGER
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = public
AS $$
  WITH input AS (
    SELECT
      LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text,
      LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all')) AS category_key,
      GREATEST(1, LEAST(COALESCE(p_limit, 80), 200)) AS result_limit
  ),
  rent_results AS (
    SELECT r.id, 'rent'::TEXT AS category, r.title,
      ('$' || TRIM(TO_CHAR(r.price, 'FM999999990.00')) || '/mo - ' || COALESCE(r.location, ''))::TEXT AS subtitle,
      (SELECT pi.url FROM public.post_images pi WHERE pi.post_id = r.id ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC LIMIT 1) AS preview_image_url,
      r.created_at, COALESCE(r.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(r.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(r.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.rent_posts_view r CROSS JOIN input i
    WHERE i.category_key IN ('all', 'rent')
      AND (i.query_text = '' OR (COALESCE(r.title, '') || ' ' || COALESCE(r.location, '')) ILIKE '%' || i.query_text || '%')
  ),
  secondhand_results AS (
    SELECT s.id, 'market'::TEXT AS category, s.title,
      ('$' || TRIM(TO_CHAR(s.price, 'FM999999990.00')) || ' - ' || COALESCE(s.condition, ''))::TEXT AS subtitle,
      (SELECT pi.url FROM public.post_images pi WHERE pi.post_id = s.id ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC LIMIT 1) AS preview_image_url,
      s.created_at, COALESCE(s.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(s.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(s.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.secondhand_posts_view s CROSS JOIN input i
    WHERE i.category_key IN ('all', 'market')
      AND (i.query_text = '' OR (COALESCE(s.title, '') || ' ' || COALESCE(s.category, '') || ' ' || COALESCE(s.condition, '')) ILIKE '%' || i.query_text || '%')
  ),
  forum_results AS (
    SELECT f.id, 'forum'::TEXT AS category, f.title,
      COALESCE(NULLIF(f.description, ''), f.board_name)::TEXT AS subtitle,
      (SELECT pi.url FROM public.post_images pi WHERE pi.post_id = f.id ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC LIMIT 1) AS preview_image_url,
      f.created_at, COALESCE(f.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(f.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(f.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.forum_posts_view f CROSS JOIN input i
    WHERE i.category_key IN ('all', 'forum')
      AND (i.query_text = '' OR (COALESCE(f.title, '') || ' ' || COALESCE(f.description, '') || ' ' || f.board_name) ILIKE '%' || i.query_text || '%')
  ),
  combined AS (
    SELECT * FROM rent_results
    UNION ALL SELECT * FROM secondhand_results
    UNION ALL SELECT * FROM forum_results
  )
  SELECT c.id, c.category, c.title, c.subtitle, c.preview_image_url,
    c.created_at, c.hot_score, c.highlight_type, c.highlight_rank
  FROM combined c CROSS JOIN input i
  ORDER BY c.highlight_rank, c.hot_score DESC, c.created_at DESC NULLS LAST
  LIMIT (SELECT result_limit FROM input);
$$;

GRANT EXECUTE ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  TO authenticated, service_role;

-- Keep the trusted official bootstrap compatible with boards. It remains a
-- content identity helper and does not grant Forum administration.
CREATE OR REPLACE FUNCTION public.configure_cheese_official_msaf_post(
  p_official_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_post_id CONSTANT UUID := 'c0ffee00-0000-0000-0000-000000000101'::UUID;
  v_board_id CONSTANT UUID := 'f0000000-0000-0000-0000-000000000002'::UUID;
  v_school_id UUID;
BEGIN
  SELECT school_id INTO v_school_id FROM public.profiles
  WHERE id = p_official_user_id AND deactivated_at IS NULL;
  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Official profile must exist, be active, and have a school_id';
  END IF;

  UPDATE public.profiles SET full_name = '奶酪官方', is_official = TRUE, updated_at = NOW()
  WHERE id = p_official_user_id;

  INSERT INTO public.posts (
    id, user_id, type, title, description, status, is_anonymous, view_count, school_id
  ) VALUES (
    v_post_id, p_official_user_id, 'forum',
    '生病、不想做作業？你可能可以使用 MSAF',
    $content$功課、Quiz 或 Midterm 突然來不及完成？如果你因為生病或臨時的個人狀況缺席，MSAF 可能可以幫到你。

MSAF 全名是 McMaster Student Absence Form，是 McMaster 提供的缺席申報方式。符合條件的學生，可以透過它為未完成的課業申請相應安排。

如何找到 MSAF：

1. 登入 Mosaic
2. 進入 Student Center
3. 找到 Academics 區域
4. 在選單中選擇 MSAF
5. 按照頁面提示填寫並提交

一般的 MSAF Self-Report，基本无理由申请（它的目的就是给你一个三天的豁免期）主要適用於短期缺席，以及佔課程總成績比例低于 25% 都可以使用（Midterm 也可以哦）

提交 MSAF 後，也記得儘快聯絡 Instructor，確認補交、延期或其他安排。MSAF 並不代表你可以完全直接忽略原本的課業，大部分情况下 MSAF的比重会转移到期末考试。

比如我这两天不想做 assignment 并且我这学期没有 MSAF 过，那我可以 MSAF，assignment 就可以不做了，但是 assignment 的比重会加到期末考试上。

歡迎直接在下面留言。我會把大家提出的問題逐一整理並回覆。

也歡迎把這篇分享給可能需要的同學。

这是常见情况，以 course outline 为准。$content$,
    'active', FALSE, 0, v_school_id
  )
  ON CONFLICT (id) DO UPDATE SET
    user_id = EXCLUDED.user_id, type = EXCLUDED.type, title = EXCLUDED.title,
    description = EXCLUDED.description, status = EXCLUDED.status,
    is_anonymous = EXCLUDED.is_anonymous, school_id = EXCLUDED.school_id,
    updated_at = NOW();

  INSERT INTO public.forum_posts (id, board_id, allow_comments, is_pinned, is_locked)
  VALUES (v_post_id, v_board_id, TRUE, FALSE, FALSE)
  ON CONFLICT (id) DO UPDATE SET
    board_id = EXCLUDED.board_id, allow_comments = TRUE, is_locked = FALSE;

  INSERT INTO public.home_featured_posts (post_id, badge, display_order, is_enabled)
  VALUES (v_post_id, '奶酪官方', 0, TRUE)
  ON CONFLICT (post_id) DO UPDATE SET
    badge = EXCLUDED.badge, display_order = EXCLUDED.display_order,
    is_enabled = EXCLUDED.is_enabled, updated_at = NOW();

  RETURN v_post_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  TO service_role;

-- Recreate the official post only when the trusted profile already exists.
DO $$
DECLARE
  v_official_user_id UUID;
BEGIN
  SELECT id INTO v_official_user_id FROM public.profiles
  WHERE lower(email) = 'cheese_official@cheeseapp.org' LIMIT 1;
  IF v_official_user_id IS NOT NULL THEN
    PERFORM public.configure_cheese_official_msaf_post(v_official_user_id);
  END IF;
END
$$;

-- Deterministic local seed accounts and the verified current development admin
-- receive backend-owned records. No client-side name or email grants permission.
INSERT INTO public.forum_admins (user_id)
SELECT id FROM public.profiles
WHERE id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000004'::UUID,
  'c69a7175-6733-4f5e-a872-5e175dd7bc0d'::UUID
)
ON CONFLICT (user_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
