-- ============================================
-- 023_profiles_optional_columns.sql
-- Add optional profile fields used by app UI
-- Safe to run multiple times
-- ============================================

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS username TEXT;

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS major TEXT;

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS bio TEXT;

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS grad_year INTEGER;

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS wechat_id TEXT;

NOTIFY pgrst, 'reload schema';
