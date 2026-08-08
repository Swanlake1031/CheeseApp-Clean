-- 030_ride_team_new_fields_and_views.sql
-- Carpool + team module field updates and view refresh

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS luggage_amount INTEGER,
  ADD COLUMN IF NOT EXISTS vehicle_type TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ride_posts_luggage_amount_check'
      AND conrelid = 'public.ride_posts'::regclass
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_luggage_amount_check
      CHECK (luggage_amount IS NULL OR luggage_amount >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ride_posts_vehicle_type_check'
      AND conrelid = 'public.ride_posts'::regclass
  ) THEN
    ALTER TABLE public.ride_posts
      ADD CONSTRAINT ride_posts_vehicle_type_check
      CHECK (vehicle_type IS NULL OR vehicle_type IN ('SUV', 'sedan'));
  END IF;
END
$$;

ALTER TABLE public.team_posts
  ADD COLUMN IF NOT EXISTS event_time TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ride_posts_vehicle_type_idx
  ON public.ride_posts(vehicle_type)
  WHERE vehicle_type IS NOT NULL;

CREATE INDEX IF NOT EXISTS team_posts_event_time_idx
  ON public.team_posts(event_time)
  WHERE event_time IS NOT NULL;

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
  r.vehicle_type
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
    WHEN t.event_time IS NOT NULL AND t.event_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired,
  t.event_time
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

NOTIFY pgrst, 'reload schema';
