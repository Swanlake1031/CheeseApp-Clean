-- 027_profile_onboarding_and_geo.sql
-- Profile onboarding fields + geo/ip privacy model

-- ============================================
-- Profiles: onboarding fields
-- ============================================
ALTER TABLE public.profiles
  ALTER COLUMN university DROP NOT NULL;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS gender TEXT,
  ADD COLUMN IF NOT EXISTS occupation TEXT,
  ADD COLUMN IF NOT EXISTS profile_completed BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'profiles_gender_check'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_gender_check
      CHECK (
        gender IS NULL
        OR gender IN ('male', 'female', 'non_binary', 'prefer_not_to_say')
      );
  END IF;
END
$$;

UPDATE public.profiles
SET profile_completed = TRUE
WHERE profile_completed = FALSE
  AND birthday IS NOT NULL
  AND gender IS NOT NULL;

-- ============================================
-- Geo/IP profile table (privacy-safe display)
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_geo_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  ip_raw INET,
  ip_masked TEXT,
  country_code TEXT,
  country_name TEXT,
  region TEXT,
  city TEXT,
  source TEXT DEFAULT 'manual',
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS user_geo_profiles_country_idx
  ON public.user_geo_profiles(country_code);

CREATE INDEX IF NOT EXISTS user_geo_profiles_region_idx
  ON public.user_geo_profiles(region);

ALTER TABLE public.user_geo_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own geo profile" ON public.user_geo_profiles;
CREATE POLICY "Users can view own geo profile"
  ON public.user_geo_profiles
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role can manage geo profile" ON public.user_geo_profiles;
CREATE POLICY "Service role can manage geo profile"
  ON public.user_geo_profiles
  FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE OR REPLACE FUNCTION public.touch_user_geo_profiles_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_geo_profiles_updated_at ON public.user_geo_profiles;
CREATE TRIGGER trg_user_geo_profiles_updated_at
BEFORE UPDATE ON public.user_geo_profiles
FOR EACH ROW
EXECUTE FUNCTION public.touch_user_geo_profiles_updated_at();

CREATE OR REPLACE FUNCTION public.mask_ip_text(p_ip TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_inet INET;
BEGIN
  IF p_ip IS NULL OR btrim(p_ip) = '' THEN
    RETURN NULL;
  END IF;

  v_inet := p_ip::inet;

  IF family(v_inet) = 4 THEN
    RETURN split_part(host(v_inet), '.', 1)
      || '.' || split_part(host(v_inet), '.', 2)
      || '.*.*';
  END IF;

  RETURN split_part(host(v_inet), ':', 1)
    || ':' || split_part(host(v_inet), ':', 2)
    || ':*:*';
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_user_geo_profile(
  p_ip TEXT DEFAULT NULL,
  p_country_code TEXT DEFAULT NULL,
  p_country_name TEXT DEFAULT NULL,
  p_region TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_source TEXT DEFAULT 'client'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO public.user_geo_profiles (
    user_id,
    ip_raw,
    ip_masked,
    country_code,
    country_name,
    region,
    city,
    source,
    last_seen_at
  ) VALUES (
    v_user_id,
    CASE WHEN p_ip IS NULL OR btrim(p_ip) = '' THEN NULL ELSE p_ip::inet END,
    public.mask_ip_text(p_ip),
    NULLIF(btrim(p_country_code), ''),
    NULLIF(btrim(p_country_name), ''),
    NULLIF(btrim(p_region), ''),
    NULLIF(btrim(p_city), ''),
    COALESCE(NULLIF(btrim(p_source), ''), 'client'),
    NOW()
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    ip_raw = COALESCE(EXCLUDED.ip_raw, public.user_geo_profiles.ip_raw),
    ip_masked = COALESCE(EXCLUDED.ip_masked, public.user_geo_profiles.ip_masked),
    country_code = COALESCE(EXCLUDED.country_code, public.user_geo_profiles.country_code),
    country_name = COALESCE(EXCLUDED.country_name, public.user_geo_profiles.country_name),
    region = COALESCE(EXCLUDED.region, public.user_geo_profiles.region),
    city = COALESCE(EXCLUDED.city, public.user_geo_profiles.city),
    source = EXCLUDED.source,
    last_seen_at = NOW(),
    updated_at = NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_user_geo_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;

-- ============================================
-- Onboarding completion RPC (birthday + gender required)
-- ============================================
CREATE OR REPLACE FUNCTION public.complete_profile(
  p_full_name TEXT DEFAULT NULL,
  p_university TEXT DEFAULT NULL,
  p_birthday DATE DEFAULT NULL,
  p_gender TEXT DEFAULT NULL,
  p_occupation TEXT DEFAULT NULL,
  p_bio TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_row public.profiles;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_birthday IS NULL THEN
    RAISE EXCEPTION 'birthday is required';
  END IF;

  IF p_gender IS NULL OR p_gender NOT IN ('male', 'female', 'non_binary', 'prefer_not_to_say') THEN
    RAISE EXCEPTION 'gender is required and invalid';
  END IF;

  UPDATE public.profiles
  SET
    full_name = COALESCE(NULLIF(btrim(p_full_name), ''), full_name),
    university = NULLIF(btrim(p_university), ''),
    birthday = p_birthday,
    gender = p_gender,
    occupation = NULLIF(btrim(p_occupation), ''),
    bio = COALESCE(NULLIF(btrim(p_bio), ''), bio),
    avatar_url = COALESCE(NULLIF(btrim(p_avatar_url), ''), avatar_url),
    profile_completed = TRUE,
    updated_at = NOW()
  WHERE id = v_user_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_profile(TEXT, TEXT, DATE, TEXT, TEXT, TEXT, TEXT)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
