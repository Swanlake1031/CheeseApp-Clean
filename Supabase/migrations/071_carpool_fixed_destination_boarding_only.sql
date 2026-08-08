-- 071_carpool_fixed_destination_boarding_only.sql
-- Upgrade the new carpool framework from segment-to-segment pricing
-- to boarding-only hubs with a fixed final destination.

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'carpool_corridors'
      AND column_name = 'full_route_price_cad'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'carpool_corridors'
      AND column_name = 'suggested_full_route_price_cad'
  ) THEN
    ALTER TABLE public.carpool_corridors
      RENAME COLUMN full_route_price_cad TO suggested_full_route_price_cad;
  END IF;
END $$;

ALTER TABLE public.carpool_route_templates
  ADD COLUMN IF NOT EXISTS driver_full_route_price_cad NUMERIC(10,2);

UPDATE public.carpool_route_templates rt
SET driver_full_route_price_cad = c.suggested_full_route_price_cad
FROM public.carpool_corridors c
WHERE c.id = rt.corridor_id
  AND rt.driver_full_route_price_cad IS NULL;

ALTER TABLE public.carpool_route_templates
  ALTER COLUMN driver_full_route_price_cad SET NOT NULL;

ALTER TABLE public.carpool_route_templates
  DROP CONSTRAINT IF EXISTS carpool_route_templates_driver_full_route_price_cad_check;

ALTER TABLE public.carpool_route_templates
  ADD CONSTRAINT carpool_route_templates_driver_full_route_price_cad_check
  CHECK (driver_full_route_price_cad > 0);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'carpool_bookings'
      AND column_name = 'alighting_hub_id'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'carpool_bookings'
      AND column_name = 'destination_hub_id'
  ) THEN
    ALTER TABLE public.carpool_bookings
      RENAME COLUMN alighting_hub_id TO destination_hub_id;
  END IF;
END $$;

ALTER TABLE public.carpool_bookings
  DROP CONSTRAINT IF EXISTS carpool_bookings_distinct_hubs;

ALTER TABLE public.carpool_bookings
  ADD CONSTRAINT carpool_bookings_distinct_hubs
  CHECK (boarding_hub_id <> destination_hub_id);

DROP FUNCTION IF EXISTS public.carpool_build_price_map(TEXT[], NUMERIC);

CREATE FUNCTION public.carpool_build_price_map(
  p_stop_keys TEXT[],
  p_driver_full_route_price NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_stop_count INTEGER;
  v_segment_count INTEGER;
  v_from_index INTEGER;
  v_price_map JSONB := '{}'::JSONB;
  v_destination_key TEXT;
  v_key TEXT;
  v_price NUMERIC;
BEGIN
  v_stop_count := COALESCE(array_length(p_stop_keys, 1), 0);
  IF v_stop_count < 2 THEN
    RETURN '{}'::JSONB;
  END IF;

  v_segment_count := v_stop_count - 1;
  v_destination_key := p_stop_keys[v_stop_count];

  FOR v_from_index IN 1..(v_stop_count - 1) LOOP
    v_key := p_stop_keys[v_from_index] || ':' || v_destination_key;
    v_price := public.carpool_round_to_half_cad(
      p_driver_full_route_price * ((v_stop_count - v_from_index)::NUMERIC / v_segment_count::NUMERIC)
    );
    v_price_map := v_price_map || jsonb_build_object(v_key, v_price);
  END LOOP;

  RETURN v_price_map;
END;
$$;

WITH ordered_stop_keys AS (
  SELECT
    rth.route_template_id,
    array_agg(
      COALESCE(rth.official_hub_id::TEXT, rth.custom_hub_id::TEXT)
      ORDER BY rth.sort_order
    ) AS stop_keys
  FROM public.carpool_route_template_hubs rth
  GROUP BY rth.route_template_id
)
UPDATE public.carpool_route_templates rt
SET price_map = public.carpool_build_price_map(osk.stop_keys, rt.driver_full_route_price_cad)
FROM ordered_stop_keys osk
WHERE osk.route_template_id = rt.id;

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
  final_stops AS (
    SELECT DISTINCT ON (ts.route_template_id)
      ts.route_template_id,
      ts.sort_order,
      ts.official_hub_id,
      ts.custom_hub_id,
      ts.name,
      ts.name_zh,
      ts.region,
      ts.lat,
      ts.lng,
      ts.is_official,
      ts.stop_key
    FROM template_stops ts
    ORDER BY ts.route_template_id, ts.sort_order DESC
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
     AND final_stop.is_official = TRUE
    JOIN template_stops board
      ON board.route_template_id = rt.id
     AND board.is_official = TRUE
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
            'id', ts.stop_key,
            'official_hub_id', ts.official_hub_id,
            'custom_hub_id', ts.custom_hub_id,
            'name', ts.name,
            'name_zh', ts.name_zh,
            'region', ts.region,
            'lat', ts.lat,
            'lng', ts.lng,
            'sort_order', ts.sort_order,
            'is_official', ts.is_official
          )
          ORDER BY ts.sort_order
        )
        FROM template_stops ts
        WHERE ts.route_template_id = rt.id
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
