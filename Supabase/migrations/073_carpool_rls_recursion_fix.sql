-- 073_carpool_rls_recursion_fix.sql
-- Break the RLS recursion between carpool_trip_instances and carpool_bookings.

BEGIN;

CREATE OR REPLACE FUNCTION public.carpool_user_owns_route_template(
  p_route_template_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.carpool_route_templates rt
    WHERE rt.id = p_route_template_id
      AND rt.driver_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.carpool_user_drives_trip(
  p_trip_instance_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.carpool_trip_instances ti
    JOIN public.carpool_route_templates rt
      ON rt.id = ti.route_template_id
    WHERE ti.id = p_trip_instance_id
      AND rt.driver_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.carpool_user_booked_trip(
  p_trip_instance_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.carpool_bookings b
    WHERE b.trip_instance_id = p_trip_instance_id
      AND b.passenger_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.carpool_user_owns_route_template(UUID)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.carpool_user_drives_trip(UUID)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.carpool_user_booked_trip(UUID)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.carpool_user_owns_route_template(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.carpool_user_drives_trip(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.carpool_user_booked_trip(UUID)
  TO authenticated, service_role;

DROP POLICY IF EXISTS "carpool_route_template_hubs_mutate_own" ON public.carpool_route_template_hubs;
CREATE POLICY "carpool_route_template_hubs_mutate_own" ON public.carpool_route_template_hubs
  FOR ALL
  USING (public.carpool_user_owns_route_template(route_template_id))
  WITH CHECK (public.carpool_user_owns_route_template(route_template_id));

DROP POLICY IF EXISTS "carpool_trip_instances_read" ON public.carpool_trip_instances;
CREATE POLICY "carpool_trip_instances_read" ON public.carpool_trip_instances
  FOR SELECT
  USING (
    status <> 'cancelled'
    OR public.carpool_user_drives_trip(id)
    OR public.carpool_user_booked_trip(id)
  );

DROP POLICY IF EXISTS "carpool_trip_instances_mutate_own" ON public.carpool_trip_instances;
CREATE POLICY "carpool_trip_instances_mutate_own" ON public.carpool_trip_instances
  FOR ALL
  USING (public.carpool_user_drives_trip(id))
  WITH CHECK (public.carpool_user_owns_route_template(route_template_id));

DROP POLICY IF EXISTS "carpool_bookings_read_participants" ON public.carpool_bookings;
CREATE POLICY "carpool_bookings_read_participants" ON public.carpool_bookings
  FOR SELECT
  USING (
    passenger_id = auth.uid()
    OR public.carpool_user_drives_trip(trip_instance_id)
  );

DROP POLICY IF EXISTS "carpool_bookings_update_participants" ON public.carpool_bookings;
CREATE POLICY "carpool_bookings_update_participants" ON public.carpool_bookings
  FOR UPDATE
  USING (
    passenger_id = auth.uid()
    OR public.carpool_user_drives_trip(trip_instance_id)
  )
  WITH CHECK (
    passenger_id = auth.uid()
    OR public.carpool_user_drives_trip(trip_instance_id)
  );

COMMIT;
