-- Retire the unused Spring Blessings seasonal feature.

BEGIN;

DROP FUNCTION IF EXISTS public.increment_spring_lamp();
DROP FUNCTION IF EXISTS public.on_spring_blessing_insert() CASCADE;
DROP FUNCTION IF EXISTS public.touch_spring_blessings_meta_updated_at() CASCADE;

DROP TABLE IF EXISTS public.spring_blessings CASCADE;
DROP TABLE IF EXISTS public.spring_blessings_meta CASCADE;

COMMIT;
