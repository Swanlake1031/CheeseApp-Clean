BEGIN;

ALTER TABLE public.carpool_route_templates
  ADD COLUMN IF NOT EXISTS price_overrides JSONB NOT NULL DEFAULT '{}'::JSONB;

COMMENT ON COLUMN public.carpool_route_templates.price_map IS
  'Final pairwise CAD prices keyed by boardingStopKey:destinationStopKey.';

COMMENT ON COLUMN public.carpool_route_templates.price_overrides IS
  'Driver-entered pairwise price overrides keyed by boardingStopKey:destinationStopKey.';

UPDATE public.carpool_corridors
SET suggested_full_route_price_cad = CASE slug
  WHEN 'hamilton_toronto' THEN 25.00
  WHEN 'london_toronto' THEN 45.00
  WHEN 'mississauga_toronto' THEN 12.00
  ELSE suggested_full_route_price_cad
END
WHERE slug IN ('hamilton_toronto', 'london_toronto', 'mississauga_toronto');

ALTER TABLE public.carpool_bookings
  ADD COLUMN IF NOT EXISTS boarding_stop_key TEXT,
  ADD COLUMN IF NOT EXISTS destination_stop_key TEXT;

UPDATE public.carpool_bookings
SET boarding_stop_key = COALESCE(boarding_stop_key, boarding_hub_id::TEXT),
    destination_stop_key = COALESCE(destination_stop_key, destination_hub_id::TEXT)
WHERE boarding_stop_key IS NULL
   OR destination_stop_key IS NULL;

ALTER TABLE public.carpool_bookings
  ALTER COLUMN boarding_hub_id DROP NOT NULL,
  ALTER COLUMN destination_hub_id DROP NOT NULL,
  ALTER COLUMN boarding_stop_key SET NOT NULL,
  ALTER COLUMN destination_stop_key SET NOT NULL;

ALTER TABLE public.carpool_bookings
  DROP CONSTRAINT IF EXISTS carpool_bookings_distinct_hubs;

ALTER TABLE public.carpool_bookings
  DROP CONSTRAINT IF EXISTS carpool_bookings_distinct_stop_keys;

ALTER TABLE public.carpool_bookings
  ADD CONSTRAINT carpool_bookings_distinct_stop_keys
  CHECK (boarding_stop_key <> destination_stop_key);

CREATE INDEX IF NOT EXISTS carpool_bookings_trip_stop_keys_idx
  ON public.carpool_bookings (trip_instance_id, boarding_stop_key, destination_stop_key);

CREATE OR REPLACE FUNCTION public.carpool_lookup_booking_price(
  p_trip_instance_id UUID,
  p_boarding_stop_key TEXT,
  p_destination_stop_key TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_pair_key TEXT;
  v_price NUMERIC(10,2);
BEGIN
  v_pair_key := TRIM(COALESCE(p_boarding_stop_key, '')) || ':' || TRIM(COALESCE(p_destination_stop_key, ''));

  SELECT (rt.price_map ->> v_pair_key)::NUMERIC(10,2)
  INTO v_price
  FROM public.carpool_trip_instances ti
  JOIN public.carpool_route_templates rt
    ON rt.id = ti.route_template_id
  WHERE ti.id = p_trip_instance_id
    AND rt.is_active = TRUE;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'no carpool price found for trip % and pair %', p_trip_instance_id, v_pair_key;
  END IF;

  RETURN v_price;
END;
$$;

GRANT EXECUTE ON FUNCTION public.carpool_lookup_booking_price(UUID, TEXT, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.carpool_bookings_apply_server_price()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.boarding_stop_key := COALESCE(NULLIF(TRIM(NEW.boarding_stop_key), ''), NEW.boarding_hub_id::TEXT);
  NEW.destination_stop_key := COALESCE(NULLIF(TRIM(NEW.destination_stop_key), ''), NEW.destination_hub_id::TEXT);

  IF NEW.boarding_stop_key IS NULL OR NEW.destination_stop_key IS NULL THEN
    RAISE EXCEPTION 'boarding_stop_key and destination_stop_key are required';
  END IF;

  NEW.price_paid := public.carpool_lookup_booking_price(
    NEW.trip_instance_id,
    NEW.boarding_stop_key,
    NEW.destination_stop_key
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS carpool_bookings_apply_server_price ON public.carpool_bookings;
CREATE TRIGGER carpool_bookings_apply_server_price
  BEFORE INSERT OR UPDATE OF trip_instance_id, boarding_hub_id, destination_hub_id, boarding_stop_key, destination_stop_key
  ON public.carpool_bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.carpool_bookings_apply_server_price();

COMMIT;
