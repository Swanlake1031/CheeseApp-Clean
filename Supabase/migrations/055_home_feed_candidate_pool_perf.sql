-- 055_home_feed_candidate_pool_perf.sql
-- Home feed performance tuning:
-- 1) limit geo scoring to a bounded candidate pool
-- 2) add indexes for same-school candidate lookups and pinned windows

BEGIN;

CREATE INDEX IF NOT EXISTS posts_module_status_school_created_idx
  ON public.posts(type, status, school_id, created_at DESC);

CREATE INDEX IF NOT EXISTS rent_posts_pinned_until_idx
  ON public.rent_posts (pinned_until DESC, id)
  WHERE highlight_type = 'pinned'::public.post_highlight_type
    AND pinned_until IS NOT NULL;

CREATE INDEX IF NOT EXISTS secondhand_posts_pinned_until_idx
  ON public.secondhand_posts (pinned_until DESC, id)
  WHERE highlight_type = 'pinned'::public.post_highlight_type
    AND pinned_until IS NOT NULL;

CREATE INDEX IF NOT EXISTS ride_posts_pinned_until_idx
  ON public.ride_posts (pinned_until DESC, id)
  WHERE highlight_type = 'pinned'::public.post_highlight_type
    AND pinned_until IS NOT NULL;

CREATE INDEX IF NOT EXISTS team_posts_pinned_until_idx
  ON public.team_posts (pinned_until DESC, id)
  WHERE highlight_type = 'pinned'::public.post_highlight_type
    AND pinned_until IS NOT NULL;

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
SET row_security = on
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
  v_nearby_radius_m DOUBLE PRECISION;
  v_cursor_layer INTEGER;
  v_cursor_distance_key BIGINT;
  v_cursor_created_at TIMESTAMPTZ;
  v_cursor_id UUID;
  v_recent_pool_limit INTEGER := 2800;
  v_same_school_pool_limit INTEGER := 1600;
  v_pinned_pool_limit INTEGER := 400;
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
    v_sort_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(p_anchor_lng, p_anchor_lat),
      4326
    )::extensions.geography;
  ELSIF v_profile_geo IS NOT NULL THEN
    v_sort_anchor := v_profile_geo;
  END IF;

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

  v_nearby_radius_m := COALESCE(v_nearby_radius_km, 25) * 1000.0;

  v_cursor_layer := COALESCE((p_cursor ->> 'layer')::INTEGER, NULL);
  v_cursor_distance_key := COALESCE(
    (p_cursor ->> 'distance_sort_key')::BIGINT,
    ROUND((p_cursor ->> 'distance_sort')::DOUBLE PRECISION)::BIGINT,
    NULL
  );
  v_cursor_created_at := COALESCE((p_cursor ->> 'created_at')::TIMESTAMPTZ, NULL);
  v_cursor_id := COALESCE((p_cursor ->> 'id')::UUID, NULL);

  WITH recent_candidates AS (
    SELECT p.id AS post_id
    FROM public.posts p
    WHERE p.type = v_module
      AND p.status = 'active'
    ORDER BY p.created_at DESC
    LIMIT v_recent_pool_limit
  ),
  same_school_candidates AS (
    SELECT p.id AS post_id
    FROM public.posts p
    WHERE p.type = v_module
      AND p.status = 'active'
      AND p.school_id = v_viewer_school_id
    ORDER BY p.created_at DESC
    LIMIT v_same_school_pool_limit
  ),
  pinned_seed AS (
    SELECT g.post_id
    FROM public.geo_feed_posts_v1 g
    WHERE g.module = v_module
      AND g.status = 'active'
      AND g.highlight_type = 'pinned'::public.post_highlight_type
      AND g.pinned_until IS NOT NULL
      AND g.pinned_until > NOW()
    ORDER BY g.pinned_until DESC, g.created_at DESC
    LIMIT v_pinned_pool_limit
  ),
  candidate_ids AS (
    SELECT post_id FROM recent_candidates
    UNION
    SELECT post_id FROM same_school_candidates
    UNION
    SELECT post_id FROM pinned_seed
  ),
  base AS (
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
      rd.distance_from_school_km AS ride_cached_distance_to_school_km,
      COALESCE(r.view_count, sh.view_count, rd.view_count, tm.view_count, 0)::double precision AS view_count
    FROM public.geo_feed_posts_v1 g
    JOIN candidate_ids cid
      ON cid.post_id = g.post_id
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = g.school_id
     AND campus.is_default = TRUE
    LEFT JOIN public.rent_posts r
      ON g.module = 'rent'
     AND r.id = g.post_id
    LEFT JOIN public.secondhand_posts sh
      ON g.module = 'secondhand'
     AND sh.id = g.post_id
    LEFT JOIN public.ride_posts rd
      ON g.module = 'ride'
     AND rd.id = g.post_id
    LEFT JOIN public.team_posts tm
      ON g.module = 'team'
     AND tm.id = g.post_id
    WHERE g.module = v_module
      AND g.status = 'active'
  ),
  school_scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN FALSE
        ELSE extensions.ST_DWithin(b.school_anchor, v_school_anchor, v_nearby_radius_m)
      END AS is_nearby_school,
      CASE
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.school_anchor, v_school_anchor)
      END AS school_anchor_distance_m
    FROM base b
  ),
  scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.module = 'rent'
          AND b.school_id = v_viewer_school_id
          AND b.highlight_type = 'pinned'::public.post_highlight_type
          AND b.pinned_until IS NOT NULL
          AND b.pinned_until > NOW() THEN 1
        WHEN b.module = 'rent'
          AND b.school_id = v_viewer_school_id THEN 2
        WHEN b.module = 'rent'
          AND b.school_id <> v_viewer_school_id
          AND b.highlight_type = 'pinned'::public.post_highlight_type
          AND b.pinned_until IS NOT NULL
          AND b.pinned_until > NOW() THEN 3
        WHEN b.module = 'rent' THEN 4
        WHEN b.school_id = v_viewer_school_id THEN 1
        WHEN b.is_nearby_school THEN 2
        ELSE 3
      END AS layer,
      CASE
        WHEN b.effective_geo IS NULL THEN 999999999.0
        WHEN b.module = 'rent' OR b.school_id = v_viewer_school_id OR b.is_nearby_school THEN
          CASE
            WHEN v_sort_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_sort_anchor)
            WHEN v_school_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_school_anchor)
            ELSE 999999999.0
          END
        ELSE 999999999.0
      END AS distance_sort_m,
      CASE
        WHEN b.module = 'rent' AND b.rent_cached_distance_to_school_km IS NOT NULL
          THEN (b.rent_cached_distance_to_school_km::double precision * 1000.0)
        WHEN b.module = 'ride' AND b.ride_cached_distance_to_school_km IS NOT NULL
          THEN (b.ride_cached_distance_to_school_km::double precision * 1000.0)
        WHEN b.effective_geo IS NULL OR b.school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.effective_geo, b.school_anchor)
      END AS distance_to_school_m
    FROM school_scored b
  ),
  pinned_candidates AS (
    SELECT *
    FROM scored
    WHERE v_module <> 'rent'
      AND highlight_type = 'pinned'::public.post_highlight_type
      AND pinned_until IS NOT NULL
      AND pinned_until > NOW()
  ),
  pinned_local_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE distance_sort_m <= (COALESCE(p_pinned_local_radius_km, 25) * 1000)
    ORDER BY distance_sort_m ASC, view_count DESC, pinned_until DESC, created_at DESC, post_id DESC
    LIMIT GREATEST(1, COALESCE(p_pinned_slots, 3))
  ),
  pinned_more_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE post_id NOT IN (SELECT post_id FROM pinned_local_rows)
    ORDER BY view_count DESC, created_at DESC, post_id DESC
    LIMIT 50
  ),
  organic_pool AS (
    SELECT
      s.*,
      x.distance_sort_raw,
      ROUND(x.distance_sort_raw)::BIGINT AS distance_sort_key
    FROM scored s
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN s.layer IN (1, 2) AND s.distance_sort_m <= v_nearby_radius_m
          THEN ((1000000000.0 - LEAST(COALESCE(s.view_count, 0), 999999999.0)) * 1000000.0) + LEAST(s.distance_sort_m, 999999.0)
        WHEN s.module = 'rent' THEN s.distance_to_school_m
        WHEN s.layer IN (1, 2) THEN s.distance_sort_m
        ELSE s.school_anchor_distance_m
      END AS distance_sort_raw
    ) x
    WHERE NOT (
      v_module <> 'rent'
      AND s.highlight_type = 'pinned'::public.post_highlight_type
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
        OR (o.layer = v_cursor_layer AND o.distance_sort_key > v_cursor_distance_key)
        OR (o.layer = v_cursor_layer AND o.distance_sort_key = v_cursor_distance_key AND o.created_at < v_cursor_created_at)
        OR (o.layer = v_cursor_layer AND o.distance_sort_key = v_cursor_distance_key AND o.created_at = v_cursor_created_at AND o.post_id < v_cursor_id)
      )
    ORDER BY o.layer ASC, o.distance_sort_key ASC, o.created_at DESC, o.post_id DESC
    LIMIT v_page_size
  ),
  organic_last AS (
    SELECT *
    FROM organic_ranked
    ORDER BY layer DESC, distance_sort_key DESC, created_at ASC, post_id ASC
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
            'highlight_type', p.highlight_type,
            'pinned_until', p.pinned_until,
            'is_paid', (
              p.highlight_type = 'pinned'::public.post_highlight_type
              AND p.pinned_until IS NOT NULL
              AND p.pinned_until > NOW()
            ),
            'view_count', p.view_count
          )
          ORDER BY p.distance_sort_m ASC, p.view_count DESC, p.created_at DESC
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
            'highlight_type', p.highlight_type,
            'pinned_until', p.pinned_until,
            'is_paid', (
              p.highlight_type = 'pinned'::public.post_highlight_type
              AND p.pinned_until IS NOT NULL
              AND p.pinned_until > NOW()
            ),
            'view_count', p.view_count
          )
          ORDER BY p.view_count DESC, p.created_at DESC
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
            'distance_sort', o.distance_sort_key,
            'distance_sort_raw', o.distance_sort_raw,
            'layer', o.layer,
            'lat', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(o.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(o.effective_geo::extensions.geometry) END,
            'highlight_type', o.highlight_type,
            'pinned_until', o.pinned_until,
            'is_paid', (
              o.highlight_type = 'pinned'::public.post_highlight_type
              AND o.pinned_until IS NOT NULL
              AND o.pinned_until > NOW()
            ),
            'view_count', o.view_count
          )
          ORDER BY o.layer ASC, o.distance_sort_key ASC, o.created_at DESC, o.post_id DESC
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
            'distance_sort', ol.distance_sort_key,
            'distance_sort_key', ol.distance_sort_key,
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
