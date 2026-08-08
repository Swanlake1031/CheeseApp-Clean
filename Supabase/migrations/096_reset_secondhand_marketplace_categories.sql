-- Reset the second-hand marketplace and replace its category contract.
--
-- Deleted data:
--   Every public.posts row whose type is 'secondhand'. Cascading foreign keys
--   also delete the related secondhand_posts rows and attached relational data.
--   Rental, forum, profile, chat, and course data are not deleted.
--
-- Rollback limits:
--   Deleted marketplace posts cannot be reconstructed by a down migration.
--   Recovery requires restoring the affected rows from a pre-migration backup.
--
-- Backup requirement:
--   Take and verify a production database backup before applying this migration.
--
-- Production order:
--   1. Take and verify the backup.
--   2. Apply this migration to empty the marketplace and update the constraint.
--   3. Ship the app build that writes the new `academic` category value.

BEGIN;

DELETE FROM public.posts
WHERE type = 'secondhand';

ALTER TABLE public.secondhand_posts
  DROP CONSTRAINT IF EXISTS secondhand_posts_category_check;

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_category_check
  CHECK (category IN (
    'furniture',
    'electronics',
    'academic',
    'clothing',
    'appliances',
    'sports',
    'beauty',
    'other'
  ));

COMMIT;
