-- 069_blank_current_ride_module_for_redesign.sql
-- Temporarily blank the current ride/carpool module ahead of a full redesign.
--
-- Why this migration exists:
-- 1. We want all current carpool surfaces to render empty.
-- 2. We do NOT want to drop ride tables/views yet, because the app still queries them.
-- 3. We keep historical rows recoverable by soft-deactivating them instead of hard-deleting.

BEGIN;

-- Hide every existing ride post from all active surfaces.
-- ride_posts_view and related feeds only surface posts.status = 'active'.
UPDATE public.posts
SET status = 'inactive',
    updated_at = NOW()
WHERE type = 'ride'
  AND status <> 'deleted'
  AND status <> 'inactive';

-- Freeze recurring ride templates so background recurrence advancement stops touching
-- the legacy ride data while the module is being redesigned.
UPDATE public.ride_posts
SET recurrence_paused = TRUE
WHERE id IN (
    SELECT id
    FROM public.posts
    WHERE type = 'ride'
      AND status <> 'deleted'
  )
  AND recurrence_enabled = TRUE
  AND recurrence_paused = FALSE;

-- Cancel any remaining ride participation records so there are no lingering
-- "confirmed" or "pending" legacy carpools behind the scenes.
-- The existing trigger will restore available seats for previously confirmed riders.
UPDATE public.ride_participants
SET status = 'cancelled'
WHERE ride_id IN (
    SELECT id
    FROM public.posts
    WHERE type = 'ride'
      AND status <> 'deleted'
  )
  AND status <> 'cancelled';

COMMIT;
