BEGIN;

ALTER TABLE public.carpool_route_templates
  ADD COLUMN IF NOT EXISTS start_address_label TEXT,
  ADD COLUMN IF NOT EXISTS start_lat DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS start_lng DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS end_address_label TEXT,
  ADD COLUMN IF NOT EXISTS end_lat DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS end_lng DOUBLE PRECISION;

COMMENT ON COLUMN public.carpool_route_templates.start_address_label IS
  'Driver-entered real departure address for this route template.';
COMMENT ON COLUMN public.carpool_route_templates.start_lat IS
  'Latitude of the driver-entered real departure address.';
COMMENT ON COLUMN public.carpool_route_templates.start_lng IS
  'Longitude of the driver-entered real departure address.';
COMMENT ON COLUMN public.carpool_route_templates.end_address_label IS
  'Driver-entered real destination address for this route template.';
COMMENT ON COLUMN public.carpool_route_templates.end_lat IS
  'Latitude of the driver-entered real destination address.';
COMMENT ON COLUMN public.carpool_route_templates.end_lng IS
  'Longitude of the driver-entered real destination address.';

COMMIT;
