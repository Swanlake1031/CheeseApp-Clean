-- Remove legacy non-driver ride rows from the live ride surface.
-- Provider carpools now live on carpool_route_templates and remain untouched.

DO $$
DECLARE
  role_constraint_name text;
BEGIN
  IF to_regclass('public.ride_posts') IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.ride_posts
  WHERE role = 'passenger';

  FOR role_constraint_name IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.ride_posts'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%role%'
  LOOP
    EXECUTE format('ALTER TABLE public.ride_posts DROP CONSTRAINT IF EXISTS %I', role_constraint_name);
  END LOOP;

  ALTER TABLE public.ride_posts
    ADD CONSTRAINT ride_posts_role_driver_only_check
    CHECK (role = 'driver');

  COMMENT ON COLUMN public.ride_posts.role IS
    'Legacy ride_posts is driver-only. Non-driver ride demand has been removed.';
END $$;

DROP INDEX IF EXISTS public.ride_posts_role_idx;
