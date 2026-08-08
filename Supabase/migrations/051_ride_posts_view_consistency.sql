-- 051_ride_posts_view_consistency.sql
-- Keep ride list/detail eligibility aligned with geo feed (status-based only).

BEGIN;

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS luggage_amount INTEGER
  CHECK (luggage_amount IS NULL OR luggage_amount >= 0),
  ADD COLUMN IF NOT EXISTS vehicle_type TEXT
  CHECK (vehicle_type IS NULL OR vehicle_type IN ('SUV', 'sedan')),
  ADD COLUMN IF NOT EXISTS distance_from_school_km NUMERIC(8,2)
  CHECK (distance_from_school_km IS NULL OR distance_from_school_km >= 0),
  ADD COLUMN IF NOT EXISTS drive_distance_km NUMERIC(8,2)
  CHECK (drive_distance_km IS NULL OR drive_distance_km >= 0),
  ADD COLUMN IF NOT EXISTS drive_duration_min NUMERIC(8,1)
  CHECK (drive_duration_min IS NULL OR drive_duration_min >= 0),
  ADD COLUMN IF NOT EXISTS route_needs_recalc BOOLEAN NOT NULL DEFAULT FALSE;

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
WHERE p.status = 'active';

ALTER VIEW IF EXISTS public.ride_posts_view SET (security_invoker = true);

COMMIT;
