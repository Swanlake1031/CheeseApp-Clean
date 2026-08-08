-- 065_ride_post_recurring_schedule.sql
-- Add lightweight recurring support directly onto existing ride posts.

BEGIN;

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS recurrence_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS recurrence_days SMALLINT[],
  ADD COLUMN IF NOT EXISTS recurrence_paused BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS recurrence_advanced_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ride_posts_recurrence_days_check'
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_recurrence_days_check
      CHECK (
        recurrence_days IS NULL
        OR recurrence_days <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::SMALLINT[]
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.next_ride_recurrence_departure(
  p_reference TIMESTAMPTZ,
  p_base_departure TIMESTAMPTZ,
  p_days SMALLINT[]
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
AS $$
DECLARE
  v_candidate TIMESTAMPTZ;
  v_days SMALLINT[];
  v_step INTEGER;
BEGIN
  SELECT ARRAY_AGG(DISTINCT day_value ORDER BY day_value)
  INTO v_days
  FROM unnest(COALESCE(p_days, ARRAY[]::SMALLINT[])) AS day_value
  WHERE day_value BETWEEN 1 AND 7;

  IF COALESCE(array_length(v_days, 1), 0) = 0 THEN
    RETURN NULL;
  END IF;

  FOR v_step IN 0..13 LOOP
    v_candidate := date_trunc('day', p_reference)
      + make_interval(days => v_step)
      + make_interval(
          hours => EXTRACT(HOUR FROM p_base_departure)::INTEGER,
          mins => EXTRACT(MINUTE FROM p_base_departure)::INTEGER,
          secs => EXTRACT(SECOND FROM p_base_departure)
        );

    IF EXTRACT(ISODOW FROM v_candidate)::INTEGER = ANY(v_days)
       AND v_candidate > p_reference THEN
      RETURN v_candidate;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.advance_recurring_ride_posts(
  p_reference TIMESTAMPTZ DEFAULT NOW()
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  ride_row RECORD;
  v_next_departure TIMESTAMPTZ;
  v_advanced_count INTEGER := 0;
BEGIN
  FOR ride_row IN
    SELECT id, departure_time, total_seats, available_seats, recurrence_days
    FROM public.ride_posts
    WHERE role = 'driver'
      AND recurrence_enabled = TRUE
      AND recurrence_paused = FALSE
      AND departure_time <= p_reference
      AND COALESCE(array_length(recurrence_days, 1), 0) > 0
  LOOP
    v_next_departure := public.next_ride_recurrence_departure(
      p_reference,
      ride_row.departure_time,
      ride_row.recurrence_days
    );

    IF v_next_departure IS NULL THEN
      CONTINUE;
    END IF;

    UPDATE public.ride_posts
    SET departure_time = v_next_departure,
        available_seats = COALESCE(total_seats, available_seats),
        recurrence_advanced_at = p_reference
    WHERE id = ride_row.id;

    v_advanced_count := v_advanced_count + 1;
  END LOOP;

  RETURN v_advanced_count;
END;
$$;

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
  r.recurrence_paused
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

-- Optional pg_cron setup:
-- SELECT cron.schedule(
--   'advance-recurring-ride-posts',
--   '*/15 * * * *',
--   $$SELECT public.advance_recurring_ride_posts();$$
-- );
