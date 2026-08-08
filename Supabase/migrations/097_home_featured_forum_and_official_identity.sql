-- 097_home_featured_forum_and_official_identity.sql
-- Trusted official profile identity plus an ordered Home -> Forum recommendation feed.

BEGIN;

-- Official is a public identity attribute, not an administrator permission.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_official BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.guard_profile_official_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, auth
AS $$
DECLARE
  v_api_role TEXT := auth.role();
BEGIN
  IF v_api_role IS NOT NULL
     AND v_api_role <> 'service_role'
     AND (
       (TG_OP = 'INSERT' AND COALESCE(NEW.is_official, FALSE))
       OR (TG_OP = 'UPDATE' AND NEW.is_official IS DISTINCT FROM OLD.is_official)
     )
  THEN
    RAISE EXCEPTION 'Official identity can only be managed by trusted backend operations';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_profile_official_identity() FROM PUBLIC;

DROP TRIGGER IF EXISTS profiles_guard_official_identity ON public.profiles;
CREATE TRIGGER profiles_guard_official_identity
BEFORE INSERT OR UPDATE OF is_official ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.guard_profile_official_identity();

-- A recommendation only stores presentation configuration and a real Forum post ID.
CREATE TABLE IF NOT EXISTS public.home_featured_posts (
  post_id UUID PRIMARY KEY REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  badge TEXT,
  display_order INTEGER NOT NULL DEFAULT 0,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT home_featured_posts_badge_length
    CHECK (badge IS NULL OR char_length(btrim(badge)) BETWEEN 1 AND 24)
);

CREATE INDEX IF NOT EXISTS home_featured_posts_enabled_order_idx
  ON public.home_featured_posts(display_order, post_id)
  WHERE is_enabled = TRUE;

DROP TRIGGER IF EXISTS home_featured_posts_updated_at ON public.home_featured_posts;
CREATE TRIGGER home_featured_posts_updated_at
BEFORE UPDATE ON public.home_featured_posts
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.home_featured_posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can read Home featured posts"
  ON public.home_featured_posts;
CREATE POLICY "Authenticated users can read Home featured posts"
ON public.home_featured_posts
FOR SELECT
TO authenticated
USING (TRUE);

REVOKE ALL ON public.home_featured_posts FROM anon, authenticated;
GRANT SELECT ON public.home_featured_posts TO authenticated, service_role;

-- Keep the existing Forum model/view and append trusted author identity at the end.
CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id,
  f.category,
  f.tags,
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
    f.view_count,
    f.like_count,
    f.comment_count,
    f.save_count,
    p.created_at
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
      FROM public.post_images pi
      WHERE pi.post_id = f.id
    ),
    '[]'::json
  ) AS images,
  CASE
    WHEN p.is_anonymous THEN FALSE
    ELSE COALESCE(pr.is_official, FALSE)
  END AS user_official
FROM public.forum_posts f
JOIN public.posts p ON f.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND f.pinned_until IS NOT NULL
      AND f.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE f.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

ALTER VIEW public.forum_posts_view SET (security_invoker = true);
GRANT SELECT ON public.forum_posts_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.gender,
  p.occupation,
  p.verified,
  p.profile_completed,
  g.ip_masked,
  g.country_name,
  g.region,
  g.city,
  g.last_seen_at,
  p.created_at,
  p.updated_at,
  p.school_id,
  p.campus_id,
  p.is_official
FROM public.profiles p
LEFT JOIN public.public_user_geo_summary_rows() g
  ON g.user_id = p.id
WHERE p.deactivated_at IS NULL;

ALTER VIEW public.profile_public_view SET (security_invoker = true);
REVOKE ALL ON public.profile_public_view FROM anon;
GRANT SELECT ON public.profile_public_view TO authenticated, service_role;

-- Trusted, idempotent production bootstrap. It never grants administrator access.
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
  v_school_id UUID;
BEGIN
  SELECT school_id
  INTO v_school_id
  FROM public.profiles
  WHERE id = p_official_user_id
    AND deactivated_at IS NULL;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Official profile must exist, be active, and have a school_id';
  END IF;

  UPDATE public.profiles
  SET
    full_name = '奶酪官方',
    is_official = TRUE,
    updated_at = NOW()
  WHERE id = p_official_user_id;

  INSERT INTO public.posts (
    id,
    user_id,
    type,
    title,
    description,
    status,
    is_anonymous,
    view_count,
    school_id
  ) VALUES (
    v_post_id,
    p_official_user_id,
    'forum',
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

提交 MSAF 後，也記得儘快聯絡 Instructor，確認補交、延期或其他安排。MSAF 並不代表你可以完全直接忽略原本的課業，大部分情况下 MSAF的比重会转移到 期末考试

比如 我这两天不想做 assignment 并且我这学期没有msaf 过，那我可以msaf，assignment 就可以不做了，但是 assignment 的比重 会加到期末考试上

歡迎直接在下面留言。我會把大家提出的問題逐一整理並回覆。

也歡迎把這篇分享給可能需要的同學。

这是常见情况，以course outline 为准$content$,
    'active',
    FALSE,
    0,
    v_school_id
  )
  ON CONFLICT (id) DO UPDATE SET
    user_id = EXCLUDED.user_id,
    type = EXCLUDED.type,
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    status = EXCLUDED.status,
    is_anonymous = EXCLUDED.is_anonymous,
    school_id = EXCLUDED.school_id,
    updated_at = NOW();

  INSERT INTO public.forum_posts (
    id,
    category,
    tags,
    allow_comments,
    is_pinned,
    is_locked
  ) VALUES (
    v_post_id,
    'share',
    '["MSAF", "McMaster", "校园指南"]'::JSONB,
    TRUE,
    FALSE,
    FALSE
  )
  ON CONFLICT (id) DO UPDATE SET
    category = EXCLUDED.category,
    tags = EXCLUDED.tags,
    allow_comments = EXCLUDED.allow_comments,
    is_locked = FALSE;

  INSERT INTO public.home_featured_posts (
    post_id,
    badge,
    display_order,
    is_enabled
  ) VALUES (
    v_post_id,
    '奶酪官方',
    0,
    TRUE
  )
  ON CONFLICT (post_id) DO UPDATE SET
    badge = EXCLUDED.badge,
    display_order = EXCLUDED.display_order,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = NOW();

  RETURN v_post_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.configure_cheese_official_msaf_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  TO service_role;

-- Configure automatically when the trusted account already exists.
DO $$
DECLARE
  v_official_user_id UUID;
BEGIN
  SELECT id
  INTO v_official_user_id
  FROM public.profiles
  WHERE lower(email) = 'cheese_official@cheeseapp.org'
  LIMIT 1;

  IF v_official_user_id IS NOT NULL THEN
    PERFORM public.configure_cheese_official_msaf_post(v_official_user_id);
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
