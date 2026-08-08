-- 034_rent_size_loft_and_view_sync.sql
-- Rent 模块增强：
-- 1) 新增面积字段 size
-- 2) property_type 支持 loft
-- 3) rent_posts_view 追加 size 列（保持旧列顺序，避免列重排冲突）

BEGIN;

ALTER TABLE public.rent_posts
  ADD COLUMN IF NOT EXISTS size NUMERIC(10,2) CHECK (size > 0);

ALTER TABLE public.rent_posts
  DROP CONSTRAINT IF EXISTS rent_posts_property_type_check;

ALTER TABLE public.rent_posts
  ADD CONSTRAINT rent_posts_property_type_check
  CHECK (property_type IN ('studio', 'apartment', 'house', 'condo', 'room', 'loft'));

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
  ) AS images,
  r.size
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

ALTER VIEW IF EXISTS public.rent_posts_view SET (security_invoker = true);

COMMIT;
