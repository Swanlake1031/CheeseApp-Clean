-- ============================================
-- Add phone field to profiles
-- ============================================

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS phone TEXT;

COMMENT ON COLUMN public.profiles.phone IS 'User phone number';
