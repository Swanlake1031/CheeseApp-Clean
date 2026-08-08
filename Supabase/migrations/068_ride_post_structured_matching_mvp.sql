-- 068_ride_post_structured_matching_mvp.sql
-- Lightweight structured fields for ride-post matching MVP.

BEGIN;

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS departure_window_minutes SMALLINT NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS detour_minutes SMALLINT NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS pickup_point TEXT,
  ADD COLUMN IF NOT EXISTS dropoff_point TEXT,
  ADD COLUMN IF NOT EXISTS is_fixed_route BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS has_return_trip BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS suggested_price_per_seat NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS preference_tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  ADD COLUMN IF NOT EXISTS vehicle_model TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ride_posts_departure_window_minutes_check'
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_departure_window_minutes_check
      CHECK (departure_window_minutes IN (0, 30, 60, 90));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ride_posts_detour_minutes_check'
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_detour_minutes_check
      CHECK (detour_minutes IN (0, 5, 10, 15));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ride_posts_suggested_price_per_seat_check'
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_suggested_price_per_seat_check
      CHECK (suggested_price_per_seat IS NULL OR suggested_price_per_seat >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ride_posts_preference_tags_check'
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_preference_tags_check
      CHECK (
        preference_tags <@ ARRAY[
          'quiet',
          'chatty',
          'luggage_friendly'
        ]::TEXT[]
      );
  END IF;
END $$;

UPDATE public.ride_posts
SET departure_window_minutes = COALESCE(departure_window_minutes, 60),
    detour_minutes = COALESCE(detour_minutes, 10),
    preference_tags = COALESCE(preference_tags, ARRAY[]::TEXT[])
WHERE departure_window_minutes IS NULL
   OR detour_minutes IS NULL
   OR preference_tags IS NULL;

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
  r.route_needs_recalc,
  r.recurrence_enabled,
  r.recurrence_days,
  r.recurrence_paused,
  credit.credit_score AS user_credit_score,
  r.departure_window_minutes,
  r.detour_minutes,
  r.pickup_point,
  r.dropoff_point,
  r.is_fixed_route,
  r.has_return_trip,
  r.suggested_price_per_seat,
  r.preference_tags,
  r.vehicle_model
FROM public.ride_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
JOIN public.schools s ON s.id = p.school_id
LEFT JOIN public.public_user_credit_summary_view credit
  ON credit.user_id = p.user_id
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
