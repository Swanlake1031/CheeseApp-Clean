-- ============================================
-- 013_hot_ranking_and_highlight.sql
-- 热门榜 + 视觉等级（URGENT / PINNED）
-- ============================================

-- 1) 视觉等级枚举
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'post_highlight_type'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.post_highlight_type AS ENUM (
      'normal',
      'urgent',
      'pinned',
      'breaking'
    );
  END IF;
END $$;

-- 2) 各分类详情表增加字段
-- rent_posts
ALTER TABLE public.rent_posts
  ADD COLUMN IF NOT EXISTS highlight_type public.post_highlight_type NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  ADD COLUMN IF NOT EXISTS like_count INTEGER NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  ADD COLUMN IF NOT EXISTS comment_count INTEGER NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  ADD COLUMN IF NOT EXISTS save_count INTEGER NOT NULL DEFAULT 0 CHECK (save_count >= 0),
  ADD COLUMN IF NOT EXISTS hot_score DOUBLE PRECISION NOT NULL DEFAULT 0;

-- secondhand_posts
ALTER TABLE public.secondhand_posts
  ADD COLUMN IF NOT EXISTS highlight_type public.post_highlight_type NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  ADD COLUMN IF NOT EXISTS like_count INTEGER NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  ADD COLUMN IF NOT EXISTS comment_count INTEGER NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  ADD COLUMN IF NOT EXISTS save_count INTEGER NOT NULL DEFAULT 0 CHECK (save_count >= 0),
  ADD COLUMN IF NOT EXISTS hot_score DOUBLE PRECISION NOT NULL DEFAULT 0;

-- ride_posts
ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS highlight_type public.post_highlight_type NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  ADD COLUMN IF NOT EXISTS like_count INTEGER NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  ADD COLUMN IF NOT EXISTS comment_count INTEGER NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  ADD COLUMN IF NOT EXISTS save_count INTEGER NOT NULL DEFAULT 0 CHECK (save_count >= 0),
  ADD COLUMN IF NOT EXISTS hot_score DOUBLE PRECISION NOT NULL DEFAULT 0;

-- team_posts
ALTER TABLE public.team_posts
  ADD COLUMN IF NOT EXISTS highlight_type public.post_highlight_type NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  ADD COLUMN IF NOT EXISTS like_count INTEGER NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  ADD COLUMN IF NOT EXISTS comment_count INTEGER NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  ADD COLUMN IF NOT EXISTS save_count INTEGER NOT NULL DEFAULT 0 CHECK (save_count >= 0),
  ADD COLUMN IF NOT EXISTS hot_score DOUBLE PRECISION NOT NULL DEFAULT 0;

-- forum_posts
ALTER TABLE public.forum_posts
  ADD COLUMN IF NOT EXISTS highlight_type public.post_highlight_type NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS pinned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS view_count INTEGER NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  ADD COLUMN IF NOT EXISTS save_count INTEGER NOT NULL DEFAULT 0 CHECK (save_count >= 0),
  ADD COLUMN IF NOT EXISTS hot_score DOUBLE PRECISION NOT NULL DEFAULT 0;

-- 兼容旧字段：论坛 is_pinned => highlight_type
UPDATE public.forum_posts
SET highlight_type = 'pinned'::public.post_highlight_type
WHERE is_pinned = TRUE
  AND highlight_type = 'normal'::public.post_highlight_type;

-- 3) 排序相关索引
CREATE INDEX IF NOT EXISTS rent_posts_hot_rank_idx
  ON public.rent_posts (highlight_type, hot_score DESC);
CREATE INDEX IF NOT EXISTS secondhand_posts_hot_rank_idx
  ON public.secondhand_posts (highlight_type, hot_score DESC);
CREATE INDEX IF NOT EXISTS ride_posts_hot_rank_idx
  ON public.ride_posts (highlight_type, hot_score DESC);
CREATE INDEX IF NOT EXISTS team_posts_hot_rank_idx
  ON public.team_posts (highlight_type, hot_score DESC);
CREATE INDEX IF NOT EXISTS forum_posts_hot_rank_idx
  ON public.forum_posts (highlight_type, hot_score DESC);

-- 4) 热度公式函数
-- score = view*0.4 + like*0.35 + comment*0.2 + save*0.05
-- final_score = score / ln(hours_since_post + 2)
CREATE OR REPLACE FUNCTION public.calculate_hot_score(
  p_view_count INTEGER,
  p_like_count INTEGER,
  p_comment_count INTEGER,
  p_save_count INTEGER,
  p_created_at TIMESTAMPTZ
)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_score DOUBLE PRECISION;
  v_hours DOUBLE PRECISION;
BEGIN
  v_score :=
      COALESCE(p_view_count, 0) * 0.40
    + COALESCE(p_like_count, 0) * 0.35
    + COALESCE(p_comment_count, 0) * 0.20
    + COALESCE(p_save_count, 0) * 0.05;

  v_hours := GREATEST(
    EXTRACT(EPOCH FROM (NOW() - COALESCE(p_created_at, NOW()))) / 3600.0,
    0
  );

  RETURN ROUND((v_score / LN(v_hours + 2))::NUMERIC, 6)::DOUBLE PRECISION;
END;
$$;

-- 5) 单贴同步统计
CREATE OR REPLACE FUNCTION public.sync_post_metrics(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_type TEXT;
  v_created_at TIMESTAMPTZ;
  v_view_count INTEGER;
  v_like_count INTEGER;
  v_comment_count INTEGER;
  v_save_count INTEGER;
  v_hot_score DOUBLE PRECISION;
BEGIN
  SELECT p.type, p.created_at, COALESCE(p.view_count, 0)
    INTO v_type, v_created_at, v_view_count
  FROM public.posts p
  WHERE p.id = p_post_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::INTEGER
    INTO v_like_count
  FROM public.likes l
  WHERE l.target_type = 'post'
    AND l.target_id = p_post_id;

  SELECT COUNT(*)::INTEGER
    INTO v_comment_count
  FROM public.comments c
  WHERE c.post_id = p_post_id
    AND c.is_deleted = FALSE;

  SELECT COUNT(*)::INTEGER
    INTO v_save_count
  FROM public.favorites f
  WHERE f.post_id = p_post_id;

  v_hot_score := public.calculate_hot_score(
    v_view_count,
    v_like_count,
    v_comment_count,
    v_save_count,
    v_created_at
  );

  IF v_type = 'rent' THEN
    UPDATE public.rent_posts r
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
            AND r.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE r.highlight_type
        END
    WHERE r.id = p_post_id;

  ELSIF v_type = 'secondhand' THEN
    UPDATE public.secondhand_posts s
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN s.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND s.pinned_until IS NOT NULL
            AND s.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE s.highlight_type
        END
    WHERE s.id = p_post_id;

  ELSIF v_type = 'ride' THEN
    UPDATE public.ride_posts r
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
            AND r.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE r.highlight_type
        END
    WHERE r.id = p_post_id;

  ELSIF v_type = 'team' THEN
    UPDATE public.team_posts t
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN t.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND t.pinned_until IS NOT NULL
            AND t.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE t.highlight_type
        END
    WHERE t.id = p_post_id;

  ELSIF v_type = 'forum' THEN
    UPDATE public.forum_posts f
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN f.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND f.pinned_until IS NOT NULL
            AND f.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE f.highlight_type
        END
    WHERE f.id = p_post_id;
  END IF;
END;
$$;

-- 6) 触发器（实时更新）
CREATE OR REPLACE FUNCTION public.trg_sync_post_metrics_from_likes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.target_type = 'post' THEN
      PERFORM public.sync_post_metrics(NEW.target_id);
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.target_type = 'post' THEN
      PERFORM public.sync_post_metrics(OLD.target_id);
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_post_metrics_from_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.sync_post_metrics(NEW.post_id);
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.sync_post_metrics(OLD.post_id);
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.post_id IS DISTINCT FROM OLD.post_id THEN
      PERFORM public.sync_post_metrics(OLD.post_id);
      PERFORM public.sync_post_metrics(NEW.post_id);
    ELSIF NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN
      PERFORM public.sync_post_metrics(NEW.post_id);
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_post_metrics_from_favorites()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.sync_post_metrics(NEW.post_id);
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.sync_post_metrics(OLD.post_id);
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_post_metrics_from_posts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.view_count IS DISTINCT FROM OLD.view_count THEN
    PERFORM public.sync_post_metrics(NEW.id);
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS likes_sync_post_metrics_trigger ON public.likes;
CREATE TRIGGER likes_sync_post_metrics_trigger
  AFTER INSERT OR DELETE ON public.likes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_post_metrics_from_likes();

DROP TRIGGER IF EXISTS comments_sync_post_metrics_trigger ON public.comments;
CREATE TRIGGER comments_sync_post_metrics_trigger
  AFTER INSERT OR DELETE OR UPDATE ON public.comments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_post_metrics_from_comments();

DROP TRIGGER IF EXISTS favorites_sync_post_metrics_trigger ON public.favorites;
CREATE TRIGGER favorites_sync_post_metrics_trigger
  AFTER INSERT OR DELETE ON public.favorites
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_post_metrics_from_favorites();

DROP TRIGGER IF EXISTS posts_sync_post_metrics_trigger ON public.posts;
CREATE TRIGGER posts_sync_post_metrics_trigger
  AFTER UPDATE OF view_count ON public.posts
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_post_metrics_from_posts();

-- 7) 批量刷新函数（可用于手动/定时任务）
CREATE OR REPLACE FUNCTION public.normalize_expired_highlights()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total INTEGER := 0;
  v_affected INTEGER := 0;
BEGIN
  UPDATE public.rent_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.secondhand_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.ride_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.team_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.forum_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  RETURN v_total;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_all_post_metrics()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  rec RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR rec IN SELECT id FROM public.posts LOOP
    PERFORM public.sync_post_metrics(rec.id);
    v_count := v_count + 1;
  END LOOP;

  PERFORM public.normalize_expired_highlights();

  RETURN v_count;
END;
$$;

-- 8) 重新定义各分类视图（输出排序字段）
-- 先删除可能依赖这些视图的热门函数（清理所有同名签名），避免 DROP VIEW 失败
DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_get_function_identity_arguments(p.oid) AS arg_list
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'get_hot_rent_posts',
        'get_hot_secondhand_posts',
        'get_hot_ride_posts',
        'get_hot_team_posts',
        'get_hot_forum_posts'
      )
  LOOP
    EXECUTE format(
      'DROP FUNCTION IF EXISTS %I.%I(%s);',
      fn.schema_name,
      fn.function_name,
      fn.arg_list
    );
  END LOOP;
END $$;

-- DROP 后再重建，避免 CREATE OR REPLACE VIEW 在老视图上触发列重命名/位置冲突
DROP VIEW IF EXISTS public.rent_posts_view;
DROP VIEW IF EXISTS public.secondhand_posts_view;
DROP VIEW IF EXISTS public.ride_posts_view;
DROP VIEW IF EXISTS public.team_posts_view;
DROP VIEW IF EXISTS public.forum_posts_view;

CREATE OR REPLACE VIEW public.rent_posts_view AS
SELECT
  r.id,
  r.price,
  r.location,
  r.latitude,
  r.longitude,
  r.bedrooms,
  r.bathrooms,
  r.specs,
  r.property_type,
  r.is_available,
  r.available_from,
  r.lease_duration,
  r.utilities_included,
  r.pets_allowed,
  r.parking_available,
  r.laundry_type,
  r.amenities,
  tier.effective_highlight_type AS highlight_type,
  r.pinned_until,
  r.view_count,
  r.like_count,
  r.comment_count,
  r.save_count,
  public.calculate_hot_score(r.view_count, r.like_count, r.comment_count, r.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = r.id
    ),
    '[]'::json
  ) AS images
FROM public.rent_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
      AND r.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE r.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

CREATE OR REPLACE VIEW public.secondhand_posts_view AS
SELECT
  s.id,
  s.price,
  s.original_price,
  s.is_negotiable,
  s.is_free,
  s.category,
  s.condition,
  s.pickup_location,
  s.can_ship,
  s.shipping_fee,
  s.quantity,
  s.sold_count,
  tier.effective_highlight_type AS highlight_type,
  s.pinned_until,
  s.view_count,
  s.like_count,
  s.comment_count,
  s.save_count,
  public.calculate_hot_score(s.view_count, s.like_count, s.comment_count, s.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = s.id
    ),
    '[]'::json
  ) AS images,
  CASE
    WHEN s.original_price IS NOT NULL AND s.original_price > 0
    THEN ROUND((1 - s.price / s.original_price) * 100)
    ELSE NULL
  END AS discount_percent
FROM public.secondhand_posts s
JOIN public.posts p ON s.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN s.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND s.pinned_until IS NOT NULL
      AND s.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE s.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

CREATE OR REPLACE VIEW public.ride_posts_view AS
SELECT
  r.id,
  r.departure_location,
  r.departure_lat,
  r.departure_lng,
  r.destination_location,
  r.destination_lat,
  r.destination_lng,
  r.departure_time,
  r.is_flexible,
  r.role,
  r.total_seats,
  r.available_seats,
  r.price_per_seat,
  r.is_free,
  r.contact_method,
  r.contact_info,
  r.has_luggage_space,
  r.pets_allowed,
  r.smoking_allowed,
  r.notes,
  tier.effective_highlight_type AS highlight_type,
  r.pinned_until,
  r.view_count,
  r.like_count,
  r.comment_count,
  r.save_count,
  public.calculate_hot_score(r.view_count, r.like_count, r.comment_count, r.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  CASE
    WHEN r.role = 'driver' AND r.available_seats <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  CASE
    WHEN r.departure_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM public.ride_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
      AND r.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE r.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND r.departure_time > (NOW() - INTERVAL '1 hour');

CREATE OR REPLACE VIEW public.team_posts_view AS
SELECT
  t.id,
  t.category,
  t.course_name,
  t.professor,
  t.team_size,
  t.current_members,
  t.spots_available,
  t.skills_needed,
  t.skills_offered,
  t.deadline,
  t.commitment_hours,
  t.is_remote,
  t.meeting_location,
  t.has_compensation,
  t.compensation_details,
  tier.effective_highlight_type AS highlight_type,
  t.pinned_until,
  t.view_count,
  t.like_count,
  t.comment_count,
  t.save_count,
  public.calculate_hot_score(t.view_count, t.like_count, t.comment_count, t.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  CASE
    WHEN t.spots_available <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  CASE
    WHEN t.deadline IS NOT NULL AND t.deadline < CURRENT_DATE THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM public.team_posts t
JOIN public.posts p ON t.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN t.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND t.pinned_until IS NOT NULL
      AND t.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE t.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

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
  public.calculate_hot_score(f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
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
  ) AS images
FROM public.forum_posts f
JOIN public.posts p ON f.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND f.pinned_until IS NOT NULL
      AND f.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE f.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

-- 9) 热门 RPC endpoint（每个板块）
CREATE OR REPLACE FUNCTION public.get_hot_rent_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.rent_posts_view
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.rent_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION public.get_hot_secondhand_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.secondhand_posts_view
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.secondhand_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION public.get_hot_ride_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.ride_posts_view
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.ride_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION public.get_hot_team_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.team_posts_view
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.team_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION public.get_hot_forum_posts(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.forum_posts_view
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.forum_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

-- 10) 启用 security_invoker（保持与 009 一致）
ALTER VIEW IF EXISTS public.rent_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.secondhand_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.ride_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.team_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.forum_posts_view SET (security_invoker = true);

-- 11) 初始回填
SELECT public.refresh_all_post_metrics();
