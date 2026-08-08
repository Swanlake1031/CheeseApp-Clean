-- 066_remove_legacy_carpool_template_artifacts.sql
-- Remove the abandoned route-template based carpool system if it was ever applied.

BEGIN;

DROP VIEW IF EXISTS public.ride_driver_dashboard_view;

DROP TRIGGER IF EXISTS trg_ride_posts_sync_generated_instance ON public.ride_posts;

ALTER TABLE public.ride_posts
  DROP COLUMN IF EXISTS generated_from_template_id,
  DROP COLUMN IF EXISTS generated_instance_id,
  DROP COLUMN IF EXISTS marketplace_tags;

DROP TABLE IF EXISTS public.ride_instances CASCADE;
DROP TABLE IF EXISTS public.ride_template_health CASCADE;
DROP TABLE IF EXISTS public.ride_weekly_schedules CASCADE;
DROP TABLE IF EXISTS public.ride_route_templates CASCADE;
DROP TABLE IF EXISTS public.ride_driver_statuses CASCADE;

DROP FUNCTION IF EXISTS public.sync_ride_instance_status_with_post();
DROP FUNCTION IF EXISTS public.confirm_ride_template_alive(UUID);
DROP FUNCTION IF EXISTS public.toggle_ride_driver_availability(BOOLEAN);
DROP FUNCTION IF EXISTS public.update_ride_instance_seats(UUID, INTEGER);
DROP FUNCTION IF EXISTS public.pause_stale_ride_templates();
DROP FUNCTION IF EXISTS public.expire_generated_ride_instances();
DROP FUNCTION IF EXISTS public.generate_scheduled_ride_instances(DATE, INTEGER);
DROP FUNCTION IF EXISTS public.ensure_ride_template_health_row();
DROP FUNCTION IF EXISTS public.touch_updated_at_column();

COMMIT;

-- If pg_cron jobs were created manually for the old system, remove them separately.
-- Example:
--   SELECT cron.unschedule('carpool-generate-and-expire-15min');
--   SELECT cron.unschedule('carpool-pause-stale-templates-daily');
