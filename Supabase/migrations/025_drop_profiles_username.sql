-- ============================================
-- 025_drop_profiles_username.sql
-- Remove deprecated username field from profiles
-- Safe to run multiple times
-- ============================================

ALTER TABLE public.profiles
DROP COLUMN IF EXISTS username;

NOTIFY pgrst, 'reload schema';
