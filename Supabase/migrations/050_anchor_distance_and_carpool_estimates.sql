-- 050_anchor_distance_and_carpool_estimates.sql
-- Anchor distance cache + carpool estimate fields + layer/ranking rule alignment

BEGIN;

-- =========================================================
-- Rent / Ride cached distance and estimate columns
-- =========================================================
ALTER TABLE public.rent_posts
  ADD COLUMN IF NOT EXISTS size NUMERIC(10,2)
  CHECK (size IS NULL OR size > 0);

ALTER TABLE public.rent_posts
  ADD COLUMN IF NOT EXISTS distance_to_school_km NUMERIC(8,2)
  CHECK (distance_to_school_km IS NULL OR distance_to_school_km >= 0);

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS luggage_amount INTEGER
  CHECK (luggage_amount IS NULL OR luggage_amount >= 0),
  ADD COLUMN IF NOT EXISTS vehicle_type TEXT
  CHECK (vehicle_type IS NULL OR vehicle_type IN ('SUV', 'sedan'));

ALTER TABLE public.ride_posts
  ADD COLUMN IF NOT EXISTS distance_from_school_km NUMERIC(8,2)
  CHECK (distance_from_school_km IS NULL OR distance_from_school_km >= 0),
  ADD COLUMN IF NOT EXISTS drive_distance_km NUMERIC(8,2)
  CHECK (drive_distance_km IS NULL OR drive_distance_km >= 0),
  ADD COLUMN IF NOT EXISTS drive_duration_min NUMERIC(8,1)
  CHECK (drive_duration_min IS NULL OR drive_duration_min >= 0),
  ADD COLUMN IF NOT EXISTS route_needs_recalc BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS rent_posts_distance_to_school_idx
  ON public.rent_posts(distance_to_school_km)
  WHERE distance_to_school_km IS NOT NULL;

CREATE INDEX IF NOT EXISTS ride_posts_distance_from_school_idx
  ON public.ride_posts(distance_from_school_km)
  WHERE distance_from_school_km IS NOT NULL;

CREATE INDEX IF NOT EXISTS ride_posts_drive_duration_idx
  ON public.ride_posts(drive_duration_min)
  WHERE drive_duration_min IS NOT NULL;

-- =========================================================
-- Helpers / triggers: keep posts.geo + cached school-distance in sync
-- =========================================================
CREATE OR REPLACE FUNCTION public.compute_post_school_anchor_distance_km(
  p_post_id UUID,
  p_lat DOUBLE PRECISION,
  p_lng DOUBLE PRECISION
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_school_geo extensions.geography;
  v_distance_km DOUBLE PRECISION;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.geo
  INTO v_school_geo
  FROM public.posts p
  JOIN public.school_campuses c
    ON c.school_id = p.school_id
   AND c.is_default = TRUE
  WHERE p.id = p_post_id
  LIMIT 1;

  IF v_school_geo IS NULL THEN
    RETURN NULL;
  END IF;

  v_distance_km := extensions.ST_Distance(
    extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography,
    v_school_geo
  ) / 1000.0;

  RETURN ROUND(v_distance_km::numeric, 2);
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_rent_anchor_distance_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
    NEW.distance_to_school_km := NULL;
  ELSE
    NEW.distance_to_school_km := public.compute_post_school_anchor_distance_km(
      NEW.id,
      NEW.latitude::double precision,
      NEW.longitude::double precision
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_rent_post_geo_mirror()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_geo extensions.geography;
BEGIN
  v_geo := CASE
    WHEN NEW.latitude IS NULL OR NEW.longitude IS NULL THEN NULL
    ELSE extensions.ST_SetSRID(
      extensions.ST_MakePoint(NEW.longitude::double precision, NEW.latitude::double precision),
      4326
    )::extensions.geography
  END;

  UPDATE public.posts p
  SET geo = v_geo
  WHERE p.id = NEW.id
    AND p.geo IS DISTINCT FROM v_geo;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_ride_anchor_distance_and_estimate_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_departure_changed BOOLEAN;
  v_destination_changed BOOLEAN;
  v_route_changed BOOLEAN;
BEGIN
  IF NEW.departure_lat IS NULL OR NEW.departure_lng IS NULL THEN
    NEW.distance_from_school_km := NULL;
  ELSE
    NEW.distance_from_school_km := public.compute_post_school_anchor_distance_km(
      NEW.id,
      NEW.departure_lat::double precision,
      NEW.departure_lng::double precision
    );
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_departure_changed := NEW.departure_lat IS NOT NULL OR NEW.departure_lng IS NOT NULL;
    v_destination_changed := NEW.destination_lat IS NOT NULL OR NEW.destination_lng IS NOT NULL;
  ELSE
    v_departure_changed := NEW.departure_lat IS DISTINCT FROM OLD.departure_lat
      OR NEW.departure_lng IS DISTINCT FROM OLD.departure_lng;
    v_destination_changed := NEW.destination_lat IS DISTINCT FROM OLD.destination_lat
      OR NEW.destination_lng IS DISTINCT FROM OLD.destination_lng;
  END IF;

  v_route_changed := v_departure_changed OR v_destination_changed;

  -- Route changed: clear stale estimates unless caller already supplied fresh values.
  IF v_route_changed THEN
    IF NEW.drive_distance_km IS NULL OR NEW.drive_duration_min IS NULL THEN
      NEW.drive_distance_km := NULL;
      NEW.drive_duration_min := NULL;
      NEW.route_needs_recalc := TRUE;
    ELSE
      NEW.route_needs_recalc := FALSE;
    END IF;
  ELSIF NEW.drive_distance_km IS NOT NULL AND NEW.drive_duration_min IS NOT NULL THEN
    NEW.route_needs_recalc := FALSE;
  ELSE
    NEW.route_needs_recalc := COALESCE(NEW.route_needs_recalc, FALSE);
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_ride_post_geo_mirror()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_geo extensions.geography;
BEGIN
  v_geo := CASE
    WHEN NEW.departure_lat IS NULL OR NEW.departure_lng IS NULL THEN NULL
    ELSE extensions.ST_SetSRID(
      extensions.ST_MakePoint(NEW.departure_lng::double precision, NEW.departure_lat::double precision),
      4326
    )::extensions.geography
  END;

  UPDATE public.posts p
  SET geo = v_geo
  WHERE p.id = NEW.id
    AND p.geo IS DISTINCT FROM v_geo;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_00_rent_sync_geo_and_distance ON public.rent_posts;
DROP TRIGGER IF EXISTS trg_00_rent_sync_anchor_distance_only ON public.rent_posts;
CREATE TRIGGER trg_00_rent_sync_anchor_distance_only
BEFORE INSERT OR UPDATE OF latitude, longitude ON public.rent_posts
FOR EACH ROW
EXECUTE FUNCTION public.sync_rent_anchor_distance_only();

DROP TRIGGER IF EXISTS trg_00_rent_sync_post_geo_mirror ON public.rent_posts;
CREATE TRIGGER trg_00_rent_sync_post_geo_mirror
AFTER INSERT OR UPDATE OF latitude, longitude ON public.rent_posts
FOR EACH ROW
EXECUTE FUNCTION public.sync_rent_post_geo_mirror();

DROP TRIGGER IF EXISTS trg_00_ride_sync_geo_and_distance ON public.ride_posts;
DROP TRIGGER IF EXISTS trg_00_ride_sync_anchor_and_estimate ON public.ride_posts;
CREATE TRIGGER trg_00_ride_sync_anchor_and_estimate
BEFORE INSERT OR UPDATE OF departure_lat, departure_lng, destination_lat, destination_lng, drive_distance_km, drive_duration_min
ON public.ride_posts
FOR EACH ROW
EXECUTE FUNCTION public.sync_ride_anchor_distance_and_estimate_state();

DROP TRIGGER IF EXISTS trg_00_ride_sync_post_geo_mirror ON public.ride_posts;
CREATE TRIGGER trg_00_ride_sync_post_geo_mirror
AFTER INSERT OR UPDATE OF departure_lat, departure_lng ON public.ride_posts
FOR EACH ROW
EXECUTE FUNCTION public.sync_ride_post_geo_mirror();

-- Backfill cached fields and posts.geo (legacy rows)
UPDATE public.rent_posts r
SET distance_to_school_km = public.compute_post_school_anchor_distance_km(
  r.id,
  r.latitude::double precision,
  r.longitude::double precision
)
WHERE r.latitude IS NOT NULL
  AND r.longitude IS NOT NULL;

UPDATE public.ride_posts r
SET distance_from_school_km = public.compute_post_school_anchor_distance_km(
  r.id,
  r.departure_lat::double precision,
  r.departure_lng::double precision
)
WHERE r.departure_lat IS NOT NULL
  AND r.departure_lng IS NOT NULL;

UPDATE public.ride_posts r
SET route_needs_recalc = CASE
  WHEN r.departure_lat IS NOT NULL
    AND r.departure_lng IS NOT NULL
    AND r.destination_lat IS NOT NULL
    AND r.destination_lng IS NOT NULL
    AND (r.drive_distance_km IS NULL OR r.drive_duration_min IS NULL)
  THEN TRUE
  ELSE FALSE
END;

UPDATE public.posts p
SET geo = extensions.ST_SetSRID(
  extensions.ST_MakePoint(r.longitude::double precision, r.latitude::double precision),
  4326
)::extensions.geography
FROM public.rent_posts r
WHERE p.id = r.id
  AND r.latitude IS NOT NULL
  AND r.longitude IS NOT NULL
  AND p.geo IS DISTINCT FROM extensions.ST_SetSRID(
    extensions.ST_MakePoint(r.longitude::double precision, r.latitude::double precision),
    4326
  )::extensions.geography;

UPDATE public.posts p
SET geo = extensions.ST_SetSRID(
  extensions.ST_MakePoint(r.departure_lng::double precision, r.departure_lat::double precision),
  4326
)::extensions.geography
FROM public.ride_posts r
WHERE p.id = r.id
  AND r.departure_lat IS NOT NULL
  AND r.departure_lng IS NOT NULL
  AND p.geo IS DISTINCT FROM extensions.ST_SetSRID(
    extensions.ST_MakePoint(r.departure_lng::double precision, r.departure_lat::double precision),
    4326
  )::extensions.geography;

-- =========================================================
-- Views: expose school and cached distance/estimate fields
-- =========================================================
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
  r.size,
  p.school_id,
  s.name AS school_name,
  r.distance_to_school_km
FROM public.rent_posts r
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

ALTER VIEW IF EXISTS public.rent_posts_view SET (security_invoker = true);

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

-- Service queue for recomputing missing/expired ride estimates.
CREATE OR REPLACE VIEW public.ride_estimate_recalc_queue AS
SELECT
  r.id,
  r.departure_lat,
  r.departure_lng,
  r.destination_lat,
  r.destination_lng,
  r.route_needs_recalc,
  p.updated_at
FROM public.ride_posts r
JOIN public.posts p ON p.id = r.id
WHERE r.route_needs_recalc = TRUE
  AND r.departure_lat IS NOT NULL
  AND r.departure_lng IS NOT NULL
  AND r.destination_lat IS NOT NULL
  AND r.destination_lng IS NOT NULL;

GRANT SELECT ON public.ride_estimate_recalc_queue TO service_role;

CREATE OR REPLACE FUNCTION public.set_ride_drive_estimate(
  p_ride_id UUID,
  p_drive_distance_km NUMERIC,
  p_drive_duration_min NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.ride_posts r
  SET
    drive_distance_km = GREATEST(COALESCE(p_drive_distance_km, 0), 0),
    drive_duration_min = GREATEST(COALESCE(p_drive_duration_min, 0), 0),
    route_needs_recalc = FALSE
  WHERE r.id = p_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_ride_drive_estimate(UUID, NUMERIC, NUMERIC)
  TO service_role;

-- =========================================================
-- Geo feed: eligibility by school anchors, location only for ranking precision
-- =========================================================
CREATE OR REPLACE FUNCTION public.get_geo_feed(
  p_viewer_user_id UUID,
  p_module TEXT,
  p_page_size INTEGER DEFAULT 20,
  p_cursor JSONB DEFAULT NULL,
  p_anchor_lat DOUBLE PRECISION DEFAULT NULL,
  p_anchor_lng DOUBLE PRECISION DEFAULT NULL,
  p_nearby_radius_km DOUBLE PRECISION DEFAULT NULL,
  p_pinned_local_radius_km DOUBLE PRECISION DEFAULT 25,
  p_pinned_slots INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_module TEXT := lower(COALESCE(p_module, ''));
  v_page_size INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 20), 50));
  v_viewer_school_id UUID;
  v_viewer_campus_id UUID;
  v_profile_geo extensions.geography;
  v_sort_anchor extensions.geography;
  v_school_anchor extensions.geography;
  v_nearby_radius_km DOUBLE PRECISION;
  v_cursor_layer INTEGER;
  v_cursor_distance DOUBLE PRECISION;
  v_cursor_created_at TIMESTAMPTZ;
  v_cursor_id UUID;
  v_pinned_local JSONB := '[]'::jsonb;
  v_pinned_more JSONB := '[]'::jsonb;
  v_organic JSONB := '[]'::jsonb;
  v_next_cursor JSONB;
BEGIN
  IF v_module NOT IN ('rent', 'secondhand', 'ride', 'team') THEN
    RAISE EXCEPTION 'Unsupported module: %', p_module;
  END IF;

  SELECT p.school_id, p.campus_id, p.last_known_geo
  INTO v_viewer_school_id, v_viewer_campus_id, v_profile_geo
  FROM public.profiles p
  WHERE p.id = p_viewer_user_id;

  IF v_viewer_school_id IS NULL THEN
    RAISE EXCEPTION 'viewer profile has no school_id';
  END IF;

  -- Location permission / profile geo only affects ranking precision.
  IF p_anchor_lat IS NOT NULL AND p_anchor_lng IS NOT NULL THEN
    v_sort_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(p_anchor_lng, p_anchor_lat),
      4326
    )::extensions.geography;
  ELSIF v_profile_geo IS NOT NULL THEN
    v_sort_anchor := v_profile_geo;
  END IF;

  -- Layer eligibility is anchored to school campus only.
  IF v_viewer_campus_id IS NOT NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    WHERE c.id = v_viewer_campus_id
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    WHERE c.school_id = v_viewer_school_id
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    JOIN public.schools s ON s.id = c.school_id
    WHERE s.name = 'McMaster University'
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    v_school_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(-79.9192, 43.2609),
      4326
    )::extensions.geography;
  END IF;

  SELECT COALESCE(p_nearby_radius_km, s.default_radius_km, 25)
  INTO v_nearby_radius_km
  FROM public.schools s
  WHERE s.id = v_viewer_school_id;

  v_cursor_layer := COALESCE((p_cursor ->> 'layer')::INTEGER, NULL);
  v_cursor_distance := COALESCE((p_cursor ->> 'distance_sort')::DOUBLE PRECISION, NULL);
  v_cursor_created_at := COALESCE((p_cursor ->> 'created_at')::TIMESTAMPTZ, NULL);
  v_cursor_id := COALESCE((p_cursor ->> 'id')::UUID, NULL);

  WITH base AS (
    SELECT
      g.post_id,
      g.author_id,
      g.module,
      g.school_id,
      g.geo,
      g.title,
      g.description,
      g.status,
      g.created_at,
      g.highlight_type,
      g.pinned_until,
      g.author_name,
      g.school_name,
      g.image_url,
      COALESCE(g.geo, campus.geo) AS effective_geo,
      campus.geo AS school_anchor,
      r.distance_to_school_km AS rent_cached_distance_to_school_km,
      rd.distance_from_school_km AS ride_cached_distance_to_school_km
    FROM public.geo_feed_posts_v1 g
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = g.school_id
     AND campus.is_default = TRUE
    LEFT JOIN public.rent_posts r
      ON g.module = 'rent'
     AND r.id = g.post_id
    LEFT JOIN public.ride_posts rd
      ON g.module = 'ride'
     AND rd.id = g.post_id
    WHERE g.module = v_module
      AND g.status = 'active'
  ),
  scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.school_id = v_viewer_school_id THEN 1
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN 3
        WHEN extensions.ST_Distance(b.school_anchor, v_school_anchor) <= (v_nearby_radius_km * 1000) THEN 2
        ELSE 3
      END AS layer,
      CASE
        WHEN b.effective_geo IS NOT NULL AND v_sort_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_sort_anchor)
        WHEN b.effective_geo IS NOT NULL AND v_school_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_school_anchor)
        WHEN b.school_anchor IS NOT NULL AND v_school_anchor IS NOT NULL THEN extensions.ST_Distance(b.school_anchor, v_school_anchor)
        ELSE 999999999.0
      END AS distance_sort_m,
      CASE
        WHEN b.module = 'rent' AND b.rent_cached_distance_to_school_km IS NOT NULL
          THEN (b.rent_cached_distance_to_school_km::double precision * 1000.0)
        WHEN b.module = 'ride' AND b.ride_cached_distance_to_school_km IS NOT NULL
          THEN (b.ride_cached_distance_to_school_km::double precision * 1000.0)
        WHEN b.effective_geo IS NULL OR b.school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.effective_geo, b.school_anchor)
      END AS distance_to_school_m,
      CASE
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.school_anchor, v_school_anchor)
      END AS school_anchor_distance_m
    FROM base b
  ),
  pinned_candidates AS (
    SELECT *
    FROM scored
    WHERE highlight_type = 'pinned'::public.post_highlight_type
      AND pinned_until IS NOT NULL
      AND pinned_until > NOW()
  ),
  pinned_local_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE distance_sort_m <= (COALESCE(p_pinned_local_radius_km, 25) * 1000)
    ORDER BY distance_sort_m ASC, pinned_until DESC, created_at DESC, post_id DESC
    LIMIT GREATEST(1, COALESCE(p_pinned_slots, 3))
  ),
  pinned_more_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE post_id NOT IN (SELECT post_id FROM pinned_local_rows)
    ORDER BY created_at DESC, post_id DESC
    LIMIT 50
  ),
  organic_pool AS (
    SELECT
      s.*,
      CASE
        WHEN s.layer IN (1, 2) THEN s.distance_sort_m
        ELSE s.school_anchor_distance_m
      END AS distance_sort
    FROM scored s
    WHERE NOT (
      s.highlight_type = 'pinned'::public.post_highlight_type
      AND s.pinned_until IS NOT NULL
      AND s.pinned_until > NOW()
    )
  ),
  organic_ranked AS (
    SELECT *
    FROM organic_pool o
    WHERE v_cursor_layer IS NULL
      OR (
        o.layer > v_cursor_layer
        OR (o.layer = v_cursor_layer AND o.distance_sort > v_cursor_distance)
        OR (o.layer = v_cursor_layer AND o.distance_sort = v_cursor_distance AND o.created_at < v_cursor_created_at)
        OR (o.layer = v_cursor_layer AND o.distance_sort = v_cursor_distance AND o.created_at = v_cursor_created_at AND o.post_id < v_cursor_id)
      )
    ORDER BY o.layer ASC, o.distance_sort ASC, o.created_at DESC, o.post_id DESC
    LIMIT v_page_size
  ),
  organic_last AS (
    SELECT *
    FROM organic_ranked
    ORDER BY layer DESC, distance_sort DESC, created_at ASC, post_id ASC
    LIMIT 1
  )
  SELECT
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', p.post_id,
            'author_id', p.author_id,
            'module', p.module,
            'school_id', p.school_id,
            'school_name', p.school_name,
            'title', p.title,
            'description', p.description,
            'author_name', p.author_name,
            'created_at', p.created_at,
            'image_url', p.image_url,
            'distance_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'lat', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(p.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(p.effective_geo::extensions.geometry) END,
            'is_paid', TRUE
          )
          ORDER BY p.distance_sort_m ASC, p.created_at DESC
        )
        FROM pinned_local_rows p
      ),
      '[]'::jsonb
    ),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', p.post_id,
            'author_id', p.author_id,
            'module', p.module,
            'school_id', p.school_id,
            'school_name', p.school_name,
            'title', p.title,
            'description', p.description,
            'author_name', p.author_name,
            'created_at', p.created_at,
            'image_url', p.image_url,
            'distance_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'lat', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(p.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(p.effective_geo::extensions.geometry) END,
            'is_paid', TRUE
          )
          ORDER BY p.created_at DESC
        )
        FROM pinned_more_rows p
      ),
      '[]'::jsonb
    ),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', o.post_id,
            'author_id', o.author_id,
            'module', o.module,
            'school_id', o.school_id,
            'school_name', o.school_name,
            'title', o.title,
            'description', o.description,
            'author_name', o.author_name,
            'created_at', o.created_at,
            'image_url', o.image_url,
            'distance_km', ROUND((o.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((o.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_sort', o.distance_sort,
            'layer', o.layer,
            'lat', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(o.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(o.effective_geo::extensions.geometry) END,
            'is_paid', FALSE
          )
          ORDER BY o.layer ASC, o.distance_sort ASC, o.created_at DESC, o.post_id DESC
        )
        FROM organic_ranked o
      ),
      '[]'::jsonb
    ),
    (
      SELECT CASE
        WHEN EXISTS (SELECT 1 FROM organic_ranked) THEN
          jsonb_build_object(
            'layer', ol.layer,
            'distance_sort', ol.distance_sort,
            'created_at', ol.created_at,
            'id', ol.post_id
          )
        ELSE NULL
      END
      FROM organic_last ol
    )
  INTO v_pinned_local, v_pinned_more, v_organic, v_next_cursor;

  RETURN jsonb_build_object(
    'module', v_module,
    'viewer_school_id', v_viewer_school_id,
    'nearby_radius_km', v_nearby_radius_km,
    'pinned_local', COALESCE(v_pinned_local, '[]'::jsonb),
    'pinned_more', COALESCE(v_pinned_more, '[]'::jsonb),
    'organic', COALESCE(v_organic, '[]'::jsonb),
    'next_cursor', v_next_cursor
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_geo_feed(UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
