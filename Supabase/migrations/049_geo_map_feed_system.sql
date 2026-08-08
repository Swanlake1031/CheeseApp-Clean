-- 049_geo_map_feed_system.sql
-- Production-grade GEO + MAP + FEED foundation for Cheese

BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- =========================================================
-- Schools / Campuses
-- =========================================================
CREATE TABLE IF NOT EXISTS public.schools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  city TEXT NOT NULL,
  region TEXT NOT NULL DEFAULT 'ON',
  default_radius_km DOUBLE PRECISION NOT NULL DEFAULT 25 CHECK (default_radius_km > 0),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.school_campuses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  geo extensions.geography(Point, 4326) NOT NULL,
  is_default BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS schools_active_idx
  ON public.schools(active);

CREATE UNIQUE INDEX IF NOT EXISTS school_campuses_one_default_idx
  ON public.school_campuses(school_id)
  WHERE is_default = TRUE;

CREATE INDEX IF NOT EXISTS school_campuses_school_id_idx
  ON public.school_campuses(school_id);

CREATE INDEX IF NOT EXISTS school_campuses_geo_gist
  ON public.school_campuses USING GIST(geo);

-- Seed schools (Ontario target list)
INSERT INTO public.schools (name, city, region, default_radius_km, active)
VALUES
  ('University of Toronto', 'Toronto', 'ON', 25, TRUE),
  ('York University', 'Toronto', 'ON', 25, TRUE),
  ('Toronto Metropolitan University', 'Toronto', 'ON', 25, TRUE),
  ('OCAD University', 'Toronto', 'ON', 25, TRUE),
  ('Ontario Tech University', 'Oshawa', 'ON', 25, TRUE),
  ('McMaster University', 'Hamilton', 'ON', 25, TRUE),
  ('Redeemer University', 'Hamilton', 'ON', 25, TRUE),
  ('University of Guelph-Humber', 'Toronto', 'ON', 25, TRUE),
  ('Seneca Polytechnic', 'Toronto', 'ON', 25, TRUE),
  ('Humber Polytechnic', 'Toronto', 'ON', 25, TRUE),
  ('George Brown College', 'Toronto', 'ON', 25, TRUE),
  ('Centennial College', 'Toronto', 'ON', 25, TRUE),
  ('Sheridan College', 'Oakville', 'ON', 25, TRUE),
  ('Durham College', 'Oshawa', 'ON', 25, TRUE),
  ('Mohawk College', 'Hamilton', 'ON', 25, TRUE)
ON CONFLICT (name) DO UPDATE SET
  city = EXCLUDED.city,
  region = EXCLUDED.region,
  default_radius_km = EXCLUDED.default_radius_km,
  active = EXCLUDED.active,
  updated_at = NOW();

-- Seed default campuses (coarse public coordinates)
WITH s AS (
  SELECT id, name FROM public.schools
)
INSERT INTO public.school_campuses (school_id, name, geo, is_default)
SELECT
  s.id,
  seed.campus_name,
  extensions.ST_SetSRID(extensions.ST_MakePoint(seed.lng, seed.lat), 4326)::extensions.geography,
  TRUE
FROM s
JOIN (
  VALUES
    ('University of Toronto', 'St. George Campus', -79.3957::double precision, 43.6629::double precision),
    ('York University', 'Keele Campus', -79.5027, 43.7735),
    ('Toronto Metropolitan University', 'Downtown Campus', -79.3781, 43.6577),
    ('OCAD University', 'Main Campus', -79.3923, 43.6532),
    ('Ontario Tech University', 'North Oshawa Campus', -78.8958, 43.9455),
    ('McMaster University', 'Main Campus', -79.9192, 43.2609),
    ('Redeemer University', 'Ancaster Campus', -79.9556, 43.2294),
    ('University of Guelph-Humber', 'Humber North Campus', -79.6060, 43.7286),
    ('Seneca Polytechnic', 'Newnham Campus', -79.3495, 43.7957),
    ('Humber Polytechnic', 'North Campus', -79.6060, 43.7286),
    ('George Brown College', 'St James Campus', -79.3685, 43.6518),
    ('Centennial College', 'Progress Campus', -79.2272, 43.7855),
    ('Sheridan College', 'Trafalgar Campus', -79.6990, 43.4696),
    ('Durham College', 'Oshawa Campus', -78.8967, 43.9458),
    ('Mohawk College', 'Fennell Campus', -79.8854, 43.2386)
) AS seed(school_name, campus_name, lng, lat)
  ON seed.school_name = s.name
WHERE NOT EXISTS (
  SELECT 1
  FROM public.school_campuses c
  WHERE c.school_id = s.id
    AND c.is_default = TRUE
);

-- =========================================================
-- Profiles geo/school fields
-- =========================================================
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS school_id UUID REFERENCES public.schools(id),
  ADD COLUMN IF NOT EXISTS campus_id UUID REFERENCES public.school_campuses(id),
  ADD COLUMN IF NOT EXISTS last_known_geo extensions.geography(Point, 4326),
  ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS profiles_school_id_idx
  ON public.profiles(school_id);

CREATE INDEX IF NOT EXISTS profiles_campus_id_idx
  ON public.profiles(campus_id);

CREATE INDEX IF NOT EXISTS profiles_last_known_geo_gist
  ON public.profiles USING GIST(last_known_geo);

-- Backfill school_id from existing university text
UPDATE public.profiles p
SET school_id = s.id
FROM public.schools s
WHERE p.school_id IS NULL
  AND btrim(COALESCE(p.university, '')) <> ''
  AND lower(btrim(p.university)) = lower(s.name);

-- Fallback unmatched users to McMaster to satisfy mandatory school rule
UPDATE public.profiles p
SET school_id = s.id
FROM public.schools s
WHERE p.school_id IS NULL
  AND s.name = 'McMaster University';

-- Backfill default campus
UPDATE public.profiles p
SET campus_id = c.id
FROM public.school_campuses c
WHERE p.campus_id IS NULL
  AND p.school_id = c.school_id
  AND c.is_default = TRUE;

ALTER TABLE public.profiles
  ALTER COLUMN school_id SET NOT NULL;

-- Keep legacy university text in sync
UPDATE public.profiles p
SET university = s.name
FROM public.schools s
WHERE p.school_id = s.id
  AND (p.university IS NULL OR btrim(p.university) = '');

CREATE OR REPLACE FUNCTION public.sync_profile_school_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_school_name TEXT;
  v_default_campus_id UUID;
BEGIN
  IF NEW.school_id IS NOT NULL THEN
    SELECT s.name INTO v_school_name
    FROM public.schools s
    WHERE s.id = NEW.school_id;

    IF v_school_name IS NOT NULL THEN
      NEW.university := v_school_name;
    END IF;

    IF NEW.campus_id IS NULL THEN
      SELECT c.id INTO v_default_campus_id
      FROM public.school_campuses c
      WHERE c.school_id = NEW.school_id
        AND c.is_default = TRUE
      LIMIT 1;
      NEW.campus_id := COALESCE(NEW.campus_id, v_default_campus_id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_profile_school_fields ON public.profiles;
CREATE TRIGGER trg_sync_profile_school_fields
BEFORE INSERT OR UPDATE OF school_id, campus_id ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.sync_profile_school_fields();

CREATE OR REPLACE FUNCTION public.touch_profile_location_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.last_known_geo IS DISTINCT FROM OLD.last_known_geo THEN
    NEW.location_updated_at := NOW();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_profile_location_updated_at ON public.profiles;
CREATE TRIGGER trg_touch_profile_location_updated_at
BEFORE UPDATE OF last_known_geo ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.touch_profile_location_updated_at();

-- =========================================================
-- Posts geo/school fields
-- =========================================================
ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS school_id UUID REFERENCES public.schools(id),
  ADD COLUMN IF NOT EXISTS geo extensions.geography(Point, 4326);

CREATE INDEX IF NOT EXISTS posts_school_id_idx
  ON public.posts(school_id);

CREATE INDEX IF NOT EXISTS posts_geo_gist
  ON public.posts USING GIST(geo);

CREATE INDEX IF NOT EXISTS posts_module_status_created_idx
  ON public.posts(type, status, created_at DESC);

-- Backfill school_id from author profile
UPDATE public.posts p
SET school_id = pr.school_id
FROM public.profiles pr
WHERE p.school_id IS NULL
  AND pr.id = p.user_id;

UPDATE public.posts p
SET school_id = s.id
FROM public.schools s
WHERE p.school_id IS NULL
  AND s.name = 'McMaster University';

ALTER TABLE public.posts
  ALTER COLUMN school_id SET NOT NULL;

-- Backfill geo from module coordinates where available
UPDATE public.posts p
SET geo = extensions.ST_SetSRID(
  extensions.ST_MakePoint(r.longitude::double precision, r.latitude::double precision),
  4326
)::extensions.geography
FROM public.rent_posts r
WHERE p.id = r.id
  AND p.geo IS NULL
  AND r.latitude IS NOT NULL
  AND r.longitude IS NOT NULL;

UPDATE public.posts p
SET geo = extensions.ST_SetSRID(
  extensions.ST_MakePoint(r.departure_lng::double precision, r.departure_lat::double precision),
  4326
)::extensions.geography
FROM public.ride_posts r
WHERE p.id = r.id
  AND p.geo IS NULL
  AND r.departure_lat IS NOT NULL
  AND r.departure_lng IS NOT NULL;

-- =========================================================
-- Paid / pinned consistency
-- =========================================================
ALTER TABLE public.rent_posts
  ADD CONSTRAINT rent_posts_pinned_requires_paid
  CHECK (pinned_until IS NULL OR highlight_type = 'pinned'::public.post_highlight_type)
  NOT VALID;

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_pinned_requires_paid
  CHECK (pinned_until IS NULL OR highlight_type = 'pinned'::public.post_highlight_type)
  NOT VALID;

ALTER TABLE public.ride_posts
  ADD CONSTRAINT ride_posts_pinned_requires_paid
  CHECK (pinned_until IS NULL OR highlight_type = 'pinned'::public.post_highlight_type)
  NOT VALID;

ALTER TABLE public.team_posts
  ADD CONSTRAINT team_posts_pinned_requires_paid
  CHECK (pinned_until IS NULL OR highlight_type = 'pinned'::public.post_highlight_type)
  NOT VALID;

ALTER TABLE public.forum_posts
  ADD CONSTRAINT forum_posts_pinned_requires_paid
  CHECK (pinned_until IS NULL OR highlight_type = 'pinned'::public.post_highlight_type)
  NOT VALID;

CREATE OR REPLACE FUNCTION public.enforce_paid_post_geo()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_geo extensions.geography;
BEGIN
  IF NEW.highlight_type = 'pinned'::public.post_highlight_type
     AND NEW.pinned_until IS NOT NULL THEN
    SELECT p.geo INTO v_geo
    FROM public.posts p
    WHERE p.id = NEW.id;

    IF v_geo IS NULL THEN
      RAISE EXCEPTION 'Paid pinned posts require geo location (post_id=%)', NEW.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rent_paid_geo ON public.rent_posts;
CREATE TRIGGER trg_rent_paid_geo
BEFORE INSERT OR UPDATE OF highlight_type, pinned_until ON public.rent_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_paid_post_geo();

DROP TRIGGER IF EXISTS trg_secondhand_paid_geo ON public.secondhand_posts;
CREATE TRIGGER trg_secondhand_paid_geo
BEFORE INSERT OR UPDATE OF highlight_type, pinned_until ON public.secondhand_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_paid_post_geo();

DROP TRIGGER IF EXISTS trg_ride_paid_geo ON public.ride_posts;
CREATE TRIGGER trg_ride_paid_geo
BEFORE INSERT OR UPDATE OF highlight_type, pinned_until ON public.ride_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_paid_post_geo();

DROP TRIGGER IF EXISTS trg_team_paid_geo ON public.team_posts;
CREATE TRIGGER trg_team_paid_geo
BEFORE INSERT OR UPDATE OF highlight_type, pinned_until ON public.team_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_paid_post_geo();

DROP TRIGGER IF EXISTS trg_forum_paid_geo ON public.forum_posts;
CREATE TRIGGER trg_forum_paid_geo
BEFORE INSERT OR UPDATE OF highlight_type, pinned_until ON public.forum_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_paid_post_geo();

-- =========================================================
-- Public profile view (include school_id/campus_id)
-- =========================================================
CREATE OR REPLACE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.birthday,
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
  p.campus_id
FROM public.profiles p
LEFT JOIN public.user_geo_profiles g
  ON g.user_id = p.id
WHERE p.deactivated_at IS NULL;

-- =========================================================
-- Feed source view
-- =========================================================
CREATE OR REPLACE VIEW public.geo_feed_posts_v1 AS
SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  r.highlight_type,
  r.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.rent_posts r ON r.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'rent'

UNION ALL

SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  sh.highlight_type,
  sh.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.secondhand_posts sh ON sh.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'secondhand'

UNION ALL

SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  rd.highlight_type,
  rd.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.ride_posts rd ON rd.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'ride'

UNION ALL

SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  t.highlight_type,
  t.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.team_posts t ON t.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'team';

-- =========================================================
-- Cursor-based feed RPC
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
  v_anchor extensions.geography;
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

  IF p_anchor_lat IS NOT NULL AND p_anchor_lng IS NOT NULL THEN
    v_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(p_anchor_lng, p_anchor_lat),
      4326
    )::extensions.geography;
  ELSIF v_profile_geo IS NOT NULL THEN
    v_anchor := v_profile_geo;
  END IF;

  IF v_anchor IS NULL THEN
    SELECT c.geo INTO v_anchor
    FROM public.school_campuses c
    WHERE c.id = v_viewer_campus_id
    LIMIT 1;
  END IF;

  IF v_anchor IS NULL THEN
    SELECT c.geo INTO v_anchor
    FROM public.school_campuses c
    WHERE c.school_id = v_viewer_school_id
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_anchor IS NULL THEN
    SELECT c.geo INTO v_anchor
    FROM public.school_campuses c
    JOIN public.schools s ON s.id = c.school_id
    WHERE s.name = 'McMaster University'
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_anchor IS NULL THEN
    v_anchor := extensions.ST_SetSRID(
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
      COALESCE(g.geo, campus.geo) AS effective_geo
    FROM public.geo_feed_posts_v1 g
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = g.school_id
     AND campus.is_default = TRUE
    WHERE g.module = v_module
      AND g.status = 'active'
  ),
  scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.effective_geo IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.effective_geo, v_anchor)
      END AS distance_m,
      CASE
        WHEN b.school_id = v_viewer_school_id THEN 1
        WHEN (
          CASE
            WHEN b.effective_geo IS NULL THEN 999999999.0
            ELSE extensions.ST_Distance(b.effective_geo, v_anchor)
          END
        ) <= (v_nearby_radius_km * 1000) THEN 2
        ELSE 3
      END AS layer
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
    WHERE distance_m <= (COALESCE(p_pinned_local_radius_km, 25) * 1000)
    ORDER BY distance_m ASC, pinned_until DESC, created_at DESC, post_id DESC
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
        WHEN s.layer IN (1, 2) THEN s.distance_m
        ELSE 999999999.0
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
            'distance_km', ROUND((p.distance_m / 1000.0)::numeric, 2),
            'lat', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(p.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(p.effective_geo::extensions.geometry) END,
            'is_paid', TRUE
          )
          ORDER BY p.distance_m ASC, p.created_at DESC
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
            'distance_km', ROUND((p.distance_m / 1000.0)::numeric, 2),
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
            'distance_km', ROUND((o.distance_m / 1000.0)::numeric, 2),
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

-- Optional profile location update RPC (coarse-friendly)
CREATE OR REPLACE FUNCTION public.update_profile_last_known_geo(
  p_lat DOUBLE PRECISION,
  p_lng DOUBLE PRECISION
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_lat DOUBLE PRECISION;
  v_lng DOUBLE PRECISION;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- coarse location (about 1.1km at 2 decimals) for privacy
  v_lat := ROUND(COALESCE(p_lat, 0)::numeric, 2)::double precision;
  v_lng := ROUND(COALESCE(p_lng, 0)::numeric, 2)::double precision;

  UPDATE public.profiles
  SET
    last_known_geo = extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography,
    location_updated_at = NOW(),
    updated_at = NOW()
  WHERE id = v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_profile_last_known_geo(DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
