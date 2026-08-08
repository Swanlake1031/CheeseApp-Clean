-- 072_carpool_public_search_uses_official_hubs_only.sql
-- Keep custom pickup points private extras:
-- 1. public price ladders are built from official searchable hubs only
-- 2. public search/detail stop lists only expose official hubs

BEGIN;

WITH ordered_official_stop_keys AS (
  SELECT
    rth.route_template_id,
    array_agg(
      rth.official_hub_id::TEXT
      ORDER BY rth.sort_order
    ) AS stop_keys
  FROM public.carpool_route_template_hubs rth
  WHERE rth.official_hub_id IS NOT NULL
  GROUP BY rth.route_template_id
)
UPDATE public.carpool_route_templates rt
SET price_map = public.carpool_build_price_map(
  oosk.stop_keys,
  rt.driver_full_route_price_cad
)
FROM ordered_official_stop_keys oosk
WHERE oosk.route_template_id = rt.id;

CREATE OR REPLACE FUNCTION public.search_carpool_trip_instances(
  p_origin_region TEXT,
  p_dest_region TEXT,
  p_trip_date DATE
)
RETURNS TABLE (
  trip_instance_id UUID,
  route_template_id UUID,
  corridor_id UUID,
  corridor_label TEXT,
  origin_city TEXT,
  dest_city TEXT,
  trip_date DATE,
  depart_time TIME,
  trip_status public.carpool_trip_status,
  seats_remaining INTEGER,
  driver_id UUID,
  driver_name TEXT,
  driver_avatar_url TEXT,
  driver_school_verified BOOLEAN,
  driver_rating_avg NUMERIC,
  driver_trip_count INTEGER,
  price_from_cad NUMERIC,
  price_to_cad NUMERIC,
  stops JSONB
)
LANGUAGE sql
SECURITY DEFINER
AS $$
  WITH template_stops AS (
    SELECT
      rth.route_template_id,
      rth.sort_order,
      rth.official_hub_id,
      rth.custom_hub_id,
      COALESCE(h.name, ch.name) AS name,
      COALESCE(h.name_zh, ch.name_zh) AS name_zh,
      COALESCE(h.region, ch.region) AS region,
      COALESCE(h.lat, ch.lat)::DOUBLE PRECISION AS lat,
      COALESCE(h.lng, ch.lng)::DOUBLE PRECISION AS lng,
      (rth.official_hub_id IS NOT NULL) AS is_official,
      COALESCE(rth.official_hub_id::TEXT, rth.custom_hub_id::TEXT) AS stop_key
    FROM public.carpool_route_template_hubs rth
    LEFT JOIN public.carpool_hubs h
      ON h.id = rth.official_hub_id
    LEFT JOIN public.carpool_custom_hubs ch
      ON ch.id = rth.custom_hub_id
  ),
  public_template_stops AS (
    SELECT *
    FROM template_stops
    WHERE is_official = TRUE
  ),
  final_stops AS (
    SELECT DISTINCT ON (pts.route_template_id)
      pts.route_template_id,
      pts.sort_order,
      pts.official_hub_id,
      pts.custom_hub_id,
      pts.name,
      pts.name_zh,
      pts.region,
      pts.lat,
      pts.lng,
      pts.is_official,
      pts.stop_key
    FROM public_template_stops pts
    ORDER BY pts.route_template_id, pts.sort_order DESC
  ),
  matching_pairs AS (
    SELECT
      ti.id AS trip_instance_id,
      MIN(
        (rt.price_map ->> (board.stop_key || ':' || final_stop.stop_key))::NUMERIC
      ) AS price_from_cad,
      MAX(
        (rt.price_map ->> (board.stop_key || ':' || final_stop.stop_key))::NUMERIC
      ) AS price_to_cad
    FROM public.carpool_trip_instances ti
    JOIN public.carpool_route_templates rt
      ON rt.id = ti.route_template_id
    JOIN public.carpool_corridors c
      ON c.id = rt.corridor_id
    JOIN final_stops final_stop
      ON final_stop.route_template_id = rt.id
    JOIN public_template_stops board
      ON board.route_template_id = rt.id
     AND board.sort_order < final_stop.sort_order
    WHERE ti.trip_date = p_trip_date
      AND ti.status IN ('scheduled', 'confirmed')
      AND ti.seats_remaining > 0
      AND rt.is_active = TRUE
      AND c.is_active = TRUE
      AND LOWER(board.region) = LOWER(TRIM(p_origin_region))
      AND LOWER(final_stop.region) = LOWER(TRIM(p_dest_region))
      AND rt.price_map ? (board.stop_key || ':' || final_stop.stop_key)
    GROUP BY ti.id
  )
  SELECT
    ti.id AS trip_instance_id,
    rt.id AS route_template_id,
    c.id AS corridor_id,
    c.label AS corridor_label,
    c.origin_city,
    c.dest_city,
    ti.trip_date,
    ti.depart_time,
    ti.status AS trip_status,
    ti.seats_remaining,
    p.id AS driver_id,
    COALESCE(p.full_name, 'Cheese Driver') AS driver_name,
    p.avatar_url AS driver_avatar_url,
    COALESCE(p.school_email_verified, FALSE) OR COALESCE(p.verified, FALSE) AS driver_school_verified,
    p.carpool_rating_avg AS driver_rating_avg,
    COALESCE(p.carpool_trip_count, 0) AS driver_trip_count,
    mp.price_from_cad,
    mp.price_to_cad,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', pts.stop_key,
            'official_hub_id', pts.official_hub_id,
            'custom_hub_id', pts.custom_hub_id,
            'name', pts.name,
            'name_zh', pts.name_zh,
            'region', pts.region,
            'lat', pts.lat,
            'lng', pts.lng,
            'sort_order', pts.sort_order,
            'is_official', pts.is_official
          )
          ORDER BY pts.sort_order
        )
        FROM public_template_stops pts
        WHERE pts.route_template_id = rt.id
      ),
      '[]'::JSONB
    ) AS stops
  FROM matching_pairs mp
  JOIN public.carpool_trip_instances ti
    ON ti.id = mp.trip_instance_id
  JOIN public.carpool_route_templates rt
    ON rt.id = ti.route_template_id
  JOIN public.carpool_corridors c
    ON c.id = rt.corridor_id
  JOIN public.profiles p
    ON p.id = rt.driver_id
  ORDER BY ti.trip_date, ti.depart_time, mp.price_from_cad, driver_trip_count DESC;
$$;

GRANT EXECUTE ON FUNCTION public.search_carpool_trip_instances(TEXT, TEXT, DATE)
  TO authenticated, service_role;

COMMIT;
