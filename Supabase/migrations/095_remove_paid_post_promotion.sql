-- Remove the paid post-promotion system from the active rental and
-- second-hand marketplace surfaces.
--
-- Deleted data:
--   Existing urgent/pinned promotion state and its expiry timestamps are
--   permanently reset to normal/null. Post content is not deleted.
--
-- Rollback limits:
--   The previous promotion tier and expiry cannot be reconstructed from the
--   database after this migration. Restore those columns from a pre-migration
--   backup if the promotion metadata must be recovered.
--
-- Backup requirement:
--   Take a production database backup before applying this migration.
--
-- Production order:
--   1. Take and verify the backup.
--   2. Apply this migration to neutralize existing promotions and reject old
--      clients that attempt to create new ones.
--   3. Ship the app build with the promotion UI and payload fields removed.

BEGIN;

UPDATE public.rent_posts
SET
  highlight_type = 'normal'::public.post_highlight_type,
  pinned_until = NULL
WHERE highlight_type <> 'normal'::public.post_highlight_type
   OR pinned_until IS NOT NULL;

UPDATE public.secondhand_posts
SET
  highlight_type = 'normal'::public.post_highlight_type,
  pinned_until = NULL
WHERE highlight_type <> 'normal'::public.post_highlight_type
   OR pinned_until IS NOT NULL;

ALTER TABLE public.rent_posts
  DROP CONSTRAINT IF EXISTS rent_posts_paid_promotion_removed_check;

ALTER TABLE public.rent_posts
  ADD CONSTRAINT rent_posts_paid_promotion_removed_check
  CHECK (
    highlight_type = 'normal'::public.post_highlight_type
    AND pinned_until IS NULL
  );

ALTER TABLE public.secondhand_posts
  DROP CONSTRAINT IF EXISTS secondhand_posts_paid_promotion_removed_check;

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_paid_promotion_removed_check
  CHECK (
    highlight_type = 'normal'::public.post_highlight_type
    AND pinned_until IS NULL
  );

DROP INDEX IF EXISTS public.rent_posts_pinned_until_idx;
DROP INDEX IF EXISTS public.secondhand_posts_pinned_until_idx;

COMMIT;
