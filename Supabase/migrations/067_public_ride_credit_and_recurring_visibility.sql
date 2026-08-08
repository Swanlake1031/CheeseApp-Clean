-- 067_public_ride_credit_and_recurring_visibility.sql
-- Expose safe public credit info for ride cards and keep ride_posts_view aligned.

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_reputation_summary'
      AND column_name = 'credit_score'
  ) THEN
    EXECUTE $view$
      CREATE OR REPLACE VIEW public.public_user_credit_summary_view AS
      SELECT
        s.user_id,
        s.credit_score::INTEGER AS credit_score
      FROM public.user_reputation_summary s
    $view$;
  ELSE
    EXECUTE $view$
      CREATE OR REPLACE VIEW public.public_user_credit_summary_view AS
      SELECT
        p.id AS user_id,
        100::INTEGER AS credit_score
      FROM public.profiles p
    $view$;
  END IF;
END $$;

GRANT SELECT ON public.public_user_credit_summary_view TO authenticated;

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
  credit.credit_score AS user_credit_score
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
