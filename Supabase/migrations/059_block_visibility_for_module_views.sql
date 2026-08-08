-- 059_block_visibility_for_module_views.sql
-- Enforce blocker-side post visibility on module views.
-- Rule: blocker can still see blocked user's posts; blocked user cannot see blocker's posts.

BEGIN;

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
WHERE p.status = 'active'
  AND (
    auth.uid() = p.user_id
    OR NOT public.is_blocked_by(p.user_id, auth.uid())
  );

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
  END AS is_expired,
  r.luggage_amount,
  r.vehicle_type,
  p.school_id,
  s.name AS school_name,
  r.distance_from_school_km,
  r.drive_distance_km,
  r.drive_duration_min,
  r.route_needs_recalc
FROM public.ride_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
JOIN public.schools s ON s.id = p.school_id
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
  AND (
    auth.uid() = p.user_id
    OR NOT public.is_blocked_by(p.user_id, auth.uid())
  );

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
    WHEN t.event_time IS NOT NULL AND t.event_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired,
  t.event_time,
  t.join_mode
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
WHERE p.status = 'active'
  AND (
    auth.uid() = p.user_id
    OR NOT public.is_blocked_by(p.user_id, auth.uid())
  );

ALTER VIEW IF EXISTS public.secondhand_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.ride_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.team_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.geo_feed_posts_v1 SET (security_invoker = true);

DO $$
BEGIN
  IF to_regprocedure(
    'public.get_geo_feed(uuid,text,integer,jsonb,double precision,double precision,double precision,double precision,integer)'
  ) IS NOT NULL THEN
    ALTER FUNCTION public.get_geo_feed(
      UUID,
      TEXT,
      INTEGER,
      JSONB,
      DOUBLE PRECISION,
      DOUBLE PRECISION,
      DOUBLE PRECISION,
      DOUBLE PRECISION,
      INTEGER
    ) SECURITY INVOKER;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
