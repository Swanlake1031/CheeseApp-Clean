-- 094_remove_profile_birthday.sql
-- Retire profile birthday collection, display, and persistence.

BEGIN;

DROP VIEW IF EXISTS public.profile_public_view;

DROP FUNCTION IF EXISTS public.complete_profile(
  TEXT,
  TEXT,
  DATE,
  TEXT,
  TEXT,
  TEXT,
  TEXT
);

ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS birthday;

CREATE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.gender,
  p.occupation,
  p.verified,
  p.profile_completed,
  g.ip_masked,
  g.country_name,
  g.region,
  g.city,
  g.last_seen_at,
  p.created_at,
  p.updated_at,
  p.school_id,
  p.campus_id
FROM public.profiles p
LEFT JOIN public.public_user_geo_summary_rows() g
  ON g.user_id = p.id
WHERE p.deactivated_at IS NULL;

ALTER VIEW public.profile_public_view SET (security_invoker = true);
REVOKE ALL ON public.profile_public_view FROM anon;
GRANT SELECT ON public.profile_public_view TO authenticated, service_role;

CREATE FUNCTION public.complete_profile(
  p_full_name TEXT DEFAULT NULL,
  p_university TEXT DEFAULT NULL,
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

  IF p_gender IS NULL OR p_gender NOT IN ('male', 'female', 'non_binary', 'prefer_not_to_say') THEN
    RAISE EXCEPTION 'gender is required and invalid';
  END IF;

  UPDATE public.profiles
  SET
    full_name = COALESCE(NULLIF(btrim(p_full_name), ''), full_name),
    university = NULLIF(btrim(p_university), ''),
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

REVOKE ALL ON FUNCTION public.complete_profile(
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_profile(
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
