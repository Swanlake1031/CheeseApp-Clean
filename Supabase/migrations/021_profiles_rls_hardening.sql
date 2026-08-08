-- ============================================
-- 021_profiles_rls_hardening.sql
-- Ensure profiles RLS policies for self-service updates
-- ============================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Profiles public read" ON public.profiles;
CREATE POLICY "Profiles public read"
ON public.profiles
FOR SELECT
USING (true);

DROP POLICY IF EXISTS "Profiles user insert own" ON public.profiles;
CREATE POLICY "Profiles user insert own"
ON public.profiles
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Profiles user update own" ON public.profiles;
CREATE POLICY "Profiles user update own"
ON public.profiles
FOR UPDATE
TO authenticated
USING (auth.uid() = id)
WITH CHECK (auth.uid() = id);

NOTIFY pgrst, 'reload schema';
