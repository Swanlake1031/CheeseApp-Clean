-- 070_carpool_hub_corridor_framework.sql
-- New fixed-schedule carpool framework built around hubs, corridors,
-- route templates, trip instances, and bookings.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_hub_type'
  ) THEN
    CREATE TYPE public.carpool_hub_type AS ENUM (
      'university',
      'transit_station',
      'mall',
      'chinese_plaza',
      'custom'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_hub_priority'
  ) THEN
    CREATE TYPE public.carpool_hub_priority AS ENUM ('high', 'medium');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_custom_hub_status'
  ) THEN
    CREATE TYPE public.carpool_custom_hub_status AS ENUM ('pending', 'approved', 'rejected');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_template_recurrence'
  ) THEN
    CREATE TYPE public.carpool_template_recurrence AS ENUM ('one_time', 'weekly', 'biweekly');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_trip_status'
  ) THEN
    CREATE TYPE public.carpool_trip_status AS ENUM ('scheduled', 'confirmed', 'completed', 'cancelled');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_booking_status'
  ) THEN
    CREATE TYPE public.carpool_booking_status AS ENUM ('pending', 'confirmed', 'completed', 'cancelled');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'carpool_user_role'
  ) THEN
    CREATE TYPE public.carpool_user_role AS ENUM ('passenger', 'driver', 'both');
  END IF;
END $$;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS carpool_role public.carpool_user_role NOT NULL DEFAULT 'both',
  ADD COLUMN IF NOT EXISTS carpool_rating_avg NUMERIC(3,2),
  ADD COLUMN IF NOT EXISTS carpool_trip_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS school_email TEXT,
  ADD COLUMN IF NOT EXISTS school_email_verified BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS public.carpool_hubs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  name_zh TEXT,
  lat NUMERIC(10,8) NOT NULL,
  lng NUMERIC(11,8) NOT NULL,
  hub_type public.carpool_hub_type NOT NULL,
  region TEXT NOT NULL,
  priority public.carpool_hub_priority NOT NULL DEFAULT 'medium',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.carpool_custom_hubs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submitted_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  name_zh TEXT,
  lat NUMERIC(10,8),
  lng NUMERIC(11,8),
  address_note TEXT,
  region TEXT,
  status public.carpool_custom_hub_status NOT NULL DEFAULT 'pending',
  is_shared BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.carpool_corridors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  origin_city TEXT NOT NULL,
  dest_city TEXT NOT NULL,
  suggested_full_route_price_cad NUMERIC(10,2) NOT NULL CHECK (suggested_full_route_price_cad > 0),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.carpool_corridor_hubs (
  corridor_id UUID NOT NULL REFERENCES public.carpool_corridors(id) ON DELETE CASCADE,
  hub_id UUID NOT NULL REFERENCES public.carpool_hubs(id) ON DELETE CASCADE,
  sort_order INTEGER NOT NULL CHECK (sort_order > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (corridor_id, hub_id),
  UNIQUE (corridor_id, sort_order)
);

CREATE TABLE IF NOT EXISTS public.carpool_route_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  corridor_id UUID NOT NULL REFERENCES public.carpool_corridors(id) ON DELETE RESTRICT,
  total_seats INTEGER NOT NULL CHECK (total_seats > 0),
  departure_time TIME NOT NULL,
  driver_full_route_price_cad NUMERIC(10,2) NOT NULL CHECK (driver_full_route_price_cad > 0),
  recurrence_type public.carpool_template_recurrence NOT NULL DEFAULT 'one_time',
  recurrence_days SMALLINT[],
  price_map JSONB NOT NULL DEFAULT '{}'::JSONB,
  driver_note TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.carpool_route_template_hubs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_template_id UUID NOT NULL REFERENCES public.carpool_route_templates(id) ON DELETE CASCADE,
  official_hub_id UUID REFERENCES public.carpool_hubs(id) ON DELETE RESTRICT,
  custom_hub_id UUID REFERENCES public.carpool_custom_hubs(id) ON DELETE RESTRICT,
  sort_order INTEGER NOT NULL CHECK (sort_order > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (route_template_id, sort_order),
  CONSTRAINT carpool_route_template_hubs_one_source CHECK (
    (official_hub_id IS NOT NULL AND custom_hub_id IS NULL)
    OR
    (official_hub_id IS NULL AND custom_hub_id IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.carpool_trip_instances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_template_id UUID NOT NULL REFERENCES public.carpool_route_templates(id) ON DELETE CASCADE,
  trip_date DATE NOT NULL,
  depart_time TIME NOT NULL,
  seats_remaining INTEGER NOT NULL CHECK (seats_remaining >= 0),
  status public.carpool_trip_status NOT NULL DEFAULT 'scheduled',
  driver_note TEXT,
  confirmed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (route_template_id, trip_date)
);

CREATE TABLE IF NOT EXISTS public.carpool_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_instance_id UUID NOT NULL REFERENCES public.carpool_trip_instances(id) ON DELETE CASCADE,
  passenger_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  boarding_hub_id UUID NOT NULL REFERENCES public.carpool_hubs(id) ON DELETE RESTRICT,
  destination_hub_id UUID NOT NULL REFERENCES public.carpool_hubs(id) ON DELETE RESTRICT,
  price_paid NUMERIC(10,2) NOT NULL CHECK (price_paid >= 0),
  seats_booked INTEGER NOT NULL DEFAULT 1 CHECK (seats_booked > 0),
  status public.carpool_booking_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cancelled_at TIMESTAMPTZ,
  CONSTRAINT carpool_bookings_distinct_hubs CHECK (boarding_hub_id <> destination_hub_id)
);

CREATE TABLE IF NOT EXISTS public.carpool_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES public.carpool_bookings(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reviewee_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (booking_id, reviewer_id, reviewee_id),
  CONSTRAINT carpool_reviews_no_self_review CHECK (reviewer_id <> reviewee_id)
);

CREATE INDEX IF NOT EXISTS carpool_hubs_region_idx
  ON public.carpool_hubs (LOWER(region))
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS carpool_custom_hubs_submitter_idx
  ON public.carpool_custom_hubs (submitted_by, status);

CREATE INDEX IF NOT EXISTS carpool_corridors_active_idx
  ON public.carpool_corridors (is_active, origin_city, dest_city);

CREATE INDEX IF NOT EXISTS carpool_route_templates_driver_idx
  ON public.carpool_route_templates (driver_id, is_active);

CREATE INDEX IF NOT EXISTS carpool_trip_instances_lookup_idx
  ON public.carpool_trip_instances (trip_date, status, seats_remaining);

CREATE INDEX IF NOT EXISTS carpool_bookings_trip_idx
  ON public.carpool_bookings (trip_instance_id, status);

CREATE INDEX IF NOT EXISTS carpool_reviews_reviewee_idx
  ON public.carpool_reviews (reviewee_id, created_at DESC);

DROP TRIGGER IF EXISTS carpool_hubs_updated_at ON public.carpool_hubs;
CREATE TRIGGER carpool_hubs_updated_at
  BEFORE UPDATE ON public.carpool_hubs
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS carpool_custom_hubs_updated_at ON public.carpool_custom_hubs;
CREATE TRIGGER carpool_custom_hubs_updated_at
  BEFORE UPDATE ON public.carpool_custom_hubs
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS carpool_corridors_updated_at ON public.carpool_corridors;
CREATE TRIGGER carpool_corridors_updated_at
  BEFORE UPDATE ON public.carpool_corridors
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS carpool_route_templates_updated_at ON public.carpool_route_templates;
CREATE TRIGGER carpool_route_templates_updated_at
  BEFORE UPDATE ON public.carpool_route_templates
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS carpool_trip_instances_updated_at ON public.carpool_trip_instances;
CREATE TRIGGER carpool_trip_instances_updated_at
  BEFORE UPDATE ON public.carpool_trip_instances
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS carpool_bookings_updated_at ON public.carpool_bookings;
CREATE TRIGGER carpool_bookings_updated_at
  BEFORE UPDATE ON public.carpool_bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

CREATE OR REPLACE FUNCTION public.carpool_round_to_half_cad(p_amount NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ROUND((COALESCE(p_amount, 0) * 2.0)) / 2.0;
$$;

CREATE OR REPLACE FUNCTION public.carpool_build_price_map(
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

CREATE OR REPLACE FUNCTION public.refresh_carpool_profile_stats(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rating_avg NUMERIC(3,2);
  v_trip_count INTEGER;
BEGIN
  SELECT ROUND(AVG(r.rating)::NUMERIC, 2)
  INTO v_rating_avg
  FROM public.carpool_reviews r
  WHERE r.reviewee_id = p_user_id;

  WITH completed_driver_trips AS (
    SELECT ti.id
    FROM public.carpool_trip_instances ti
    JOIN public.carpool_route_templates rt
      ON rt.id = ti.route_template_id
    WHERE rt.driver_id = p_user_id
      AND ti.status = 'completed'
  ),
  completed_passenger_bookings AS (
    SELECT b.id
    FROM public.carpool_bookings b
    WHERE b.passenger_id = p_user_id
      AND b.status = 'completed'
  )
  SELECT COALESCE((SELECT COUNT(*) FROM completed_driver_trips), 0)
       + COALESCE((SELECT COUNT(*) FROM completed_passenger_bookings), 0)
  INTO v_trip_count;

  UPDATE public.profiles
  SET carpool_rating_avg = v_rating_avg,
      carpool_trip_count = COALESCE(v_trip_count, 0),
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.carpool_reviews_refresh_stats()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM public.refresh_carpool_profile_stats(COALESCE(NEW.reviewee_id, OLD.reviewee_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS carpool_reviews_refresh_stats ON public.carpool_reviews;
CREATE TRIGGER carpool_reviews_refresh_stats
  AFTER INSERT OR UPDATE OR DELETE ON public.carpool_reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.carpool_reviews_refresh_stats();

CREATE OR REPLACE FUNCTION public.carpool_bookings_adjust_seats()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_delta INTEGER := 0;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status IN ('pending', 'confirmed') THEN
      v_delta := NEW.seats_booked;
      UPDATE public.carpool_trip_instances
      SET seats_remaining = seats_remaining - v_delta
      WHERE id = NEW.trip_instance_id
        AND seats_remaining >= v_delta;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'not enough seats remaining for trip %', NEW.trip_instance_id;
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status IN ('pending', 'confirmed') AND NEW.status NOT IN ('pending', 'confirmed') THEN
      UPDATE public.carpool_trip_instances
      SET seats_remaining = seats_remaining + OLD.seats_booked
      WHERE id = NEW.trip_instance_id;
    ELSIF OLD.status NOT IN ('pending', 'confirmed') AND NEW.status IN ('pending', 'confirmed') THEN
      UPDATE public.carpool_trip_instances
      SET seats_remaining = seats_remaining - NEW.seats_booked
      WHERE id = NEW.trip_instance_id
        AND seats_remaining >= NEW.seats_booked;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'not enough seats remaining for trip %', NEW.trip_instance_id;
      END IF;
    ELSIF OLD.status IN ('pending', 'confirmed')
      AND NEW.status IN ('pending', 'confirmed')
      AND OLD.seats_booked <> NEW.seats_booked THEN
      v_delta := NEW.seats_booked - OLD.seats_booked;

      IF v_delta > 0 THEN
        UPDATE public.carpool_trip_instances
        SET seats_remaining = seats_remaining - v_delta
        WHERE id = NEW.trip_instance_id
          AND seats_remaining >= v_delta;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'not enough seats remaining for trip %', NEW.trip_instance_id;
        END IF;
      ELSIF v_delta < 0 THEN
        UPDATE public.carpool_trip_instances
        SET seats_remaining = seats_remaining + ABS(v_delta)
        WHERE id = NEW.trip_instance_id;
      END IF;
    END IF;

    IF NEW.status = 'completed' OR OLD.status = 'completed' THEN
      PERFORM public.refresh_carpool_profile_stats(NEW.passenger_id);
      PERFORM public.refresh_carpool_profile_stats(
        (
          SELECT rt.driver_id
          FROM public.carpool_trip_instances ti
          JOIN public.carpool_route_templates rt
            ON rt.id = ti.route_template_id
          WHERE ti.id = NEW.trip_instance_id
        )
      );
    END IF;

    RETURN NEW;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS carpool_bookings_adjust_seats ON public.carpool_bookings;
CREATE TRIGGER carpool_bookings_adjust_seats
  AFTER INSERT OR UPDATE ON public.carpool_bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.carpool_bookings_adjust_seats();

CREATE OR REPLACE VIEW public.carpool_regions_view AS
SELECT DISTINCT ON (LOWER(region))
  LOWER(region) AS normalized_region,
  region AS display_region,
  CASE priority
    WHEN 'high' THEN 0
    ELSE 1
  END AS sort_rank
FROM public.carpool_hubs
WHERE is_active = TRUE
ORDER BY LOWER(region), sort_rank, name;

ALTER VIEW IF EXISTS public.carpool_regions_view SET (security_invoker = true);

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

INSERT INTO public.carpool_hubs (
  slug,
  name,
  name_zh,
  lat,
  lng,
  hub_type,
  region,
  priority
)
VALUES
  ('mcmaster_university', 'McMaster University', '麦马大学', 43.26090000, -79.91920000, 'university', 'Hamilton', 'high'),
  ('hamilton_go_centre', 'Hamilton GO Centre', 'Hamilton GO', 43.25698000, -79.86919000, 'transit_station', 'Hamilton', 'high'),
  ('oakville_go', 'Oakville GO', 'Oakville GO', 43.45619000, -79.68323000, 'transit_station', 'Oakville', 'medium'),
  ('square_one', 'Square One', '一号广场', 43.59302000, -79.64310000, 'mall', 'Mississauga', 'high'),
  ('golden_square_mississauga', 'Golden Square Mississauga', '黄金广场', 43.59269000, -79.66742000, 'chinese_plaza', 'Mississauga', 'high'),
  ('islington_station', 'Islington Station', 'Islington 站', 43.64534000, -79.52459000, 'transit_station', 'Toronto', 'medium'),
  ('union_station', 'Union Station', 'Union 站', 43.64524000, -79.38060000, 'transit_station', 'Toronto', 'high'),
  ('western_university', 'Western University', '西大', 43.00960000, -81.27370000, 'university', 'London', 'high'),
  ('london_via_station', 'London VIA Station', 'London VIA', 42.98151000, -81.24625000, 'transit_station', 'London', 'medium')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    name_zh = EXCLUDED.name_zh,
    lat = EXCLUDED.lat,
    lng = EXCLUDED.lng,
    hub_type = EXCLUDED.hub_type,
    region = EXCLUDED.region,
    priority = EXCLUDED.priority,
    is_active = TRUE,
    updated_at = NOW();

INSERT INTO public.carpool_corridors (
  slug,
  label,
  origin_city,
  dest_city,
  suggested_full_route_price_cad
)
VALUES
  ('hamilton_toronto', 'Hamilton -> Toronto', 'Hamilton', 'Toronto', 28.00),
  ('london_toronto', 'London -> Toronto', 'London', 'Toronto', 46.00),
  ('mississauga_toronto', 'Mississauga -> Toronto', 'Mississauga', 'Toronto', 18.00)
ON CONFLICT (slug) DO UPDATE
SET label = EXCLUDED.label,
    origin_city = EXCLUDED.origin_city,
    dest_city = EXCLUDED.dest_city,
    suggested_full_route_price_cad = EXCLUDED.suggested_full_route_price_cad,
    is_active = TRUE,
    updated_at = NOW();

INSERT INTO public.carpool_corridor_hubs (corridor_id, hub_id, sort_order)
SELECT c.id, h.id, mapping.sort_order
FROM (
  VALUES
    ('hamilton_toronto', 'mcmaster_university', 1),
    ('hamilton_toronto', 'hamilton_go_centre', 2),
    ('hamilton_toronto', 'oakville_go', 3),
    ('hamilton_toronto', 'square_one', 4),
    ('hamilton_toronto', 'golden_square_mississauga', 5),
    ('hamilton_toronto', 'islington_station', 6),
    ('hamilton_toronto', 'union_station', 7),
    ('london_toronto', 'western_university', 1),
    ('london_toronto', 'london_via_station', 2),
    ('london_toronto', 'square_one', 3),
    ('london_toronto', 'golden_square_mississauga', 4),
    ('london_toronto', 'islington_station', 5),
    ('london_toronto', 'union_station', 6),
    ('mississauga_toronto', 'square_one', 1),
    ('mississauga_toronto', 'golden_square_mississauga', 2),
    ('mississauga_toronto', 'islington_station', 3),
    ('mississauga_toronto', 'union_station', 4)
) AS mapping(corridor_slug, hub_slug, sort_order)
JOIN public.carpool_corridors c
  ON c.slug = mapping.corridor_slug
JOIN public.carpool_hubs h
  ON h.slug = mapping.hub_slug
ON CONFLICT (corridor_id, hub_id) DO UPDATE
SET sort_order = EXCLUDED.sort_order;

ALTER TABLE public.carpool_hubs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_custom_hubs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_corridors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_corridor_hubs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_route_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_route_template_hubs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_trip_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "carpool_hubs_active_read" ON public.carpool_hubs;
CREATE POLICY "carpool_hubs_active_read" ON public.carpool_hubs
  FOR SELECT
  USING (is_active = TRUE);

DROP POLICY IF EXISTS "carpool_corridors_active_read" ON public.carpool_corridors;
CREATE POLICY "carpool_corridors_active_read" ON public.carpool_corridors
  FOR SELECT
  USING (is_active = TRUE);

DROP POLICY IF EXISTS "carpool_corridor_hubs_read" ON public.carpool_corridor_hubs;
CREATE POLICY "carpool_corridor_hubs_read" ON public.carpool_corridor_hubs
  FOR SELECT
  USING (TRUE);

DROP POLICY IF EXISTS "carpool_custom_hubs_read" ON public.carpool_custom_hubs;
CREATE POLICY "carpool_custom_hubs_read" ON public.carpool_custom_hubs
  FOR SELECT
  USING (
    status = 'approved'
    OR submitted_by = auth.uid()
  );

DROP POLICY IF EXISTS "carpool_custom_hubs_insert_own" ON public.carpool_custom_hubs;
CREATE POLICY "carpool_custom_hubs_insert_own" ON public.carpool_custom_hubs
  FOR INSERT
  WITH CHECK (submitted_by = auth.uid());

DROP POLICY IF EXISTS "carpool_custom_hubs_update_own" ON public.carpool_custom_hubs;
CREATE POLICY "carpool_custom_hubs_update_own" ON public.carpool_custom_hubs
  FOR UPDATE
  USING (submitted_by = auth.uid())
  WITH CHECK (submitted_by = auth.uid());

DROP POLICY IF EXISTS "carpool_route_templates_read" ON public.carpool_route_templates;
CREATE POLICY "carpool_route_templates_read" ON public.carpool_route_templates
  FOR SELECT
  USING (
    is_active = TRUE
    OR driver_id = auth.uid()
  );

DROP POLICY IF EXISTS "carpool_route_templates_insert_own" ON public.carpool_route_templates;
CREATE POLICY "carpool_route_templates_insert_own" ON public.carpool_route_templates
  FOR INSERT
  WITH CHECK (driver_id = auth.uid());

DROP POLICY IF EXISTS "carpool_route_templates_update_own" ON public.carpool_route_templates;
CREATE POLICY "carpool_route_templates_update_own" ON public.carpool_route_templates
  FOR UPDATE
  USING (driver_id = auth.uid())
  WITH CHECK (driver_id = auth.uid());

DROP POLICY IF EXISTS "carpool_route_templates_delete_own" ON public.carpool_route_templates;
CREATE POLICY "carpool_route_templates_delete_own" ON public.carpool_route_templates
  FOR DELETE
  USING (driver_id = auth.uid());

DROP POLICY IF EXISTS "carpool_route_template_hubs_read" ON public.carpool_route_template_hubs;
CREATE POLICY "carpool_route_template_hubs_read" ON public.carpool_route_template_hubs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND (rt.is_active = TRUE OR rt.driver_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "carpool_route_template_hubs_mutate_own" ON public.carpool_route_template_hubs;
CREATE POLICY "carpool_route_template_hubs_mutate_own" ON public.carpool_route_template_hubs
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND rt.driver_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND rt.driver_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "carpool_trip_instances_read" ON public.carpool_trip_instances;
CREATE POLICY "carpool_trip_instances_read" ON public.carpool_trip_instances
  FOR SELECT
  USING (
    status <> 'cancelled'
    OR EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND rt.driver_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1
      FROM public.carpool_bookings b
      WHERE b.trip_instance_id = id
        AND b.passenger_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "carpool_trip_instances_mutate_own" ON public.carpool_trip_instances;
CREATE POLICY "carpool_trip_instances_mutate_own" ON public.carpool_trip_instances
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND rt.driver_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.carpool_route_templates rt
      WHERE rt.id = route_template_id
        AND rt.driver_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "carpool_bookings_read_participants" ON public.carpool_bookings;
CREATE POLICY "carpool_bookings_read_participants" ON public.carpool_bookings
  FOR SELECT
  USING (
    passenger_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.carpool_trip_instances ti
      JOIN public.carpool_route_templates rt
        ON rt.id = ti.route_template_id
      WHERE ti.id = trip_instance_id
        AND rt.driver_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "carpool_bookings_insert_self" ON public.carpool_bookings;
CREATE POLICY "carpool_bookings_insert_self" ON public.carpool_bookings
  FOR INSERT
  WITH CHECK (passenger_id = auth.uid());

DROP POLICY IF EXISTS "carpool_bookings_update_participants" ON public.carpool_bookings;
CREATE POLICY "carpool_bookings_update_participants" ON public.carpool_bookings
  FOR UPDATE
  USING (
    passenger_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.carpool_trip_instances ti
      JOIN public.carpool_route_templates rt
        ON rt.id = ti.route_template_id
      WHERE ti.id = trip_instance_id
        AND rt.driver_id = auth.uid()
    )
  )
  WITH CHECK (
    passenger_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.carpool_trip_instances ti
      JOIN public.carpool_route_templates rt
        ON rt.id = ti.route_template_id
      WHERE ti.id = trip_instance_id
        AND rt.driver_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "carpool_reviews_read" ON public.carpool_reviews;
CREATE POLICY "carpool_reviews_read" ON public.carpool_reviews
  FOR SELECT
  USING (TRUE);

DROP POLICY IF EXISTS "carpool_reviews_insert_self" ON public.carpool_reviews;
CREATE POLICY "carpool_reviews_insert_self" ON public.carpool_reviews
  FOR INSERT
  WITH CHECK (reviewer_id = auth.uid());

GRANT SELECT ON public.carpool_hubs TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.carpool_custom_hubs TO authenticated, service_role;
GRANT SELECT ON public.carpool_corridors TO authenticated, service_role;
GRANT SELECT ON public.carpool_corridor_hubs TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.carpool_route_templates TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.carpool_route_template_hubs TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.carpool_trip_instances TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.carpool_bookings TO authenticated, service_role;
GRANT SELECT, INSERT ON public.carpool_reviews TO authenticated, service_role;
GRANT SELECT ON public.carpool_regions_view TO authenticated, service_role;

COMMIT;
