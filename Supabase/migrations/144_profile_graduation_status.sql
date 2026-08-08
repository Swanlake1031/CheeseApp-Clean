-- 144_profile_graduation_status.sql
-- Stores whether a profile owner has graduated. Graduated users keep their
-- selected school for historical display, while clients disable student-only
-- school selection and verification controls.

BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_graduated BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  CASE WHEN profile.show_gender THEN profile.gender ELSE NULL END AS gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::TEXT AS country_name,
  NULL::TEXT AS region,
  NULL::TEXT AS city,
  profile.is_mcmaster_verified,
  profile.show_gender,
  profile.is_graduated
FROM public.profiles profile
WHERE profile.deactivated_at IS NULL
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks block_row
          WHERE block_row.blocker_id = profile.id
            AND block_row.blocked_id = auth.uid()
        )
      )
    )
  );

ALTER VIEW public.profile_public_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.profile_public_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.profile_public_view TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.complete_profile(
  p_full_name TEXT,
  p_university TEXT,
  p_gender TEXT,
  p_occupation TEXT,
  p_bio TEXT,
  p_avatar_url TEXT,
  p_is_graduated BOOLEAN
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_gender TEXT := NULLIF(btrim(p_gender), '');
  v_university TEXT := COALESCE(
    NULLIF(btrim(p_university), ''),
    'McMaster University'
  );
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
      is_graduated = COALESCE(p_is_graduated, FALSE),
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
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
) TO authenticated, service_role;

COMMIT;
