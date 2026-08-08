-- 147_make_profile_school_optional.sql
-- Keeps the internal school_id routing fallback intact while allowing the
-- user-facing university field to remain empty during profile completion.

BEGIN;

CREATE OR REPLACE FUNCTION public.complete_profile(
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
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_gender TEXT := NULLIF(btrim(p_gender), '');
  v_university TEXT := NULLIF(btrim(p_university), '');
  v_row public.profiles;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_gender IS NULL THEN
    RAISE EXCEPTION 'Gender is required' USING ERRCODE = '22023';
  END IF;
  IF v_gender NOT IN ('male', 'female', 'non_binary', 'prefer_not_to_say') THEN
    RAISE EXCEPTION 'Invalid gender' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET full_name = COALESCE(NULLIF(btrim(p_full_name), ''), full_name),
      university = v_university,
      gender = v_gender,
      occupation = NULLIF(btrim(p_occupation), ''),
      bio = COALESCE(NULLIF(btrim(p_bio), ''), bio),
      avatar_url = COALESCE(NULLIF(btrim(p_avatar_url), ''), avatar_url),
      profile_completed = TRUE,
      updated_at = clock_timestamp()
  WHERE id = v_user_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO authenticated, service_role;

COMMIT;
