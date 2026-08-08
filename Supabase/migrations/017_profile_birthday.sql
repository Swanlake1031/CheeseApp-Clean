-- ============================================
-- Add birthday field to profiles
-- ============================================

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS birthday DATE;

COMMENT ON COLUMN public.profiles.birthday IS 'User birthday (date only)';
