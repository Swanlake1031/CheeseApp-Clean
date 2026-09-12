-- Expand the profile school directory, add student/working status, and make
-- the existing server-owned McMaster verification boundary work for every
-- supported university. Legacy names remain in place where changing them
-- would break already-shipped clients.
--
-- No user rows are deleted. Existing profiles remain `student`; existing
-- McMaster verifications are bound to McMaster during the migration.
-- Rollback requires a new migration and cannot safely restore a verification
-- after a user changes school or switches to working status.

BEGIN;

ALTER TABLE public.schools
  ADD COLUMN IF NOT EXISTS verification_domains TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS badge_code TEXT;

INSERT INTO public.schools (
  name, city, region, active, verification_domains, badge_code
)
VALUES
  ('University of Alberta', 'Edmonton', 'AB', TRUE, ARRAY['ualberta.ca'], 'A'),
  ('University of British Columbia', 'Vancouver', 'BC', TRUE, ARRAY['student.ubc.ca'], 'UBC'),
  ('Brock University', 'St. Catharines', 'ON', TRUE, ARRAY['brocku.ca'], 'B'),
  ('University of Calgary', 'Calgary', 'AB', TRUE, ARRAY['ucalgary.ca'], 'C'),
  ('Carleton University', 'Ottawa', 'ON', TRUE, ARRAY['cmail.carleton.ca'], 'C'),
  ('Concordia University', 'Montréal', 'QC', TRUE, ARRAY['mail.concordia.ca','live.concordia.ca'], 'C'),
  ('Dalhousie University', 'Halifax', 'NS', TRUE, ARRAY['dal.ca'], 'D'),
  ('University of Guelph', 'Guelph', 'ON', TRUE, ARRAY['uoguelph.ca'], 'G'),
  ('Simon Fraser University', 'Burnaby', 'BC', TRUE, ARRAY['sfu.ca'], 'S'),
  ('Lakehead University', 'Thunder Bay', 'ON', TRUE, ARRAY['lakeheadu.ca'], 'L'),
  ('McGill University', 'Montréal', 'QC', TRUE, ARRAY['mail.mcgill.ca','mcgill.ca'], 'M'),
  ('University of Manitoba', 'Winnipeg', 'MB', TRUE, ARRAY['myumanitoba.ca'], 'M'),
  ('McMaster University', 'Hamilton', 'ON', TRUE, ARRAY['mcmaster.ca'], 'M'),
  ('Université de Montréal', 'Montréal', 'QC', TRUE, ARRAY['umontreal.ca'], 'UdeM'),
  ('Ontario Tech University', 'Oshawa', 'ON', TRUE, ARRAY['ontariotechu.net'], 'OT'),
  ('Queen''s University', 'Kingston', 'ON', TRUE, ARRAY['queensu.ca'], 'Q'),
  ('University of Toronto', 'Toronto', 'ON', TRUE, ARRAY['mail.utoronto.ca'], 'T'),
  ('Toronto Metropolitan University', 'Toronto', 'ON', TRUE, ARRAY['torontomu.ca'], 'TMU'),
  ('Trent University', 'Peterborough', 'ON', TRUE, ARRAY['trentu.ca'], 'T'),
  ('University of Waterloo', 'Waterloo', 'ON', TRUE, ARRAY['uwaterloo.ca'], 'W'),
  ('York University', 'Toronto', 'ON', TRUE, ARRAY['my.yorku.ca','yorku.ca'], 'Y'),
  ('OCAD University', 'Toronto', 'ON', TRUE, ARRAY['ocadu.ca'], 'O'),
  ('Redeemer University', 'Hamilton', 'ON', TRUE, ARRAY['redeemer.ca'], 'R'),
  ('University of Guelph-Humber', 'Toronto', 'ON', TRUE, ARRAY['guelphhumber.ca'], 'GH'),
  ('Other', 'Canada', 'CA', TRUE, ARRAY[]::TEXT[], '•')
ON CONFLICT (name) DO UPDATE SET
  city = EXCLUDED.city,
  region = EXCLUDED.region,
  active = TRUE,
  verification_domains = EXCLUDED.verification_domains,
  badge_code = EXCLUDED.badge_code,
  updated_at = clock_timestamp();

INSERT INTO public.school_campuses (school_id, name, is_default)
SELECT school.id, 'Main Campus', TRUE
FROM public.schools AS school
WHERE school.name IN (
  'University of Alberta', 'University of British Columbia', 'Brock University',
  'University of Calgary', 'Carleton University', 'Concordia University',
  'Dalhousie University', 'University of Guelph', 'Simon Fraser University',
  'Lakehead University', 'McGill University', 'University of Manitoba',
  'Université de Montréal', 'Queen''s University', 'Trent University',
  'University of Waterloo', 'Other'
)
AND NOT EXISTS (
  SELECT 1 FROM public.school_campuses AS campus
  WHERE campus.school_id = school.id AND campus.is_default
);

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS profile_status TEXT NOT NULL DEFAULT 'student';

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_profile_status_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_profile_status_check
  CHECK (profile_status IN ('student', 'working'));

COMMENT ON COLUMN public.profiles.profile_status IS
  'User-selected profile status: student or working.';

ALTER TABLE public.mcmaster_student_verifications
  ADD COLUMN IF NOT EXISTS school_id UUID REFERENCES public.schools(id);
ALTER TABLE public.mcmaster_email_challenges
  ADD COLUMN IF NOT EXISTS school_id UUID REFERENCES public.schools(id);

UPDATE public.mcmaster_student_verifications
SET school_id = (SELECT id FROM public.schools WHERE name = 'McMaster University')
WHERE school_id IS NULL;
UPDATE public.mcmaster_email_challenges
SET school_id = (SELECT id FROM public.schools WHERE name = 'McMaster University')
WHERE school_id IS NULL;

ALTER TABLE public.mcmaster_student_verifications
  ALTER COLUMN school_id SET NOT NULL;
ALTER TABLE public.mcmaster_email_challenges
  ALTER COLUMN school_id SET NOT NULL;

ALTER TABLE public.mcmaster_student_verifications
  DROP CONSTRAINT IF EXISTS mcmaster_student_verifications_email_format_check;
ALTER TABLE public.mcmaster_email_challenges
  DROP CONSTRAINT IF EXISTS mcmaster_email_challenges_email_format_check;
ALTER TABLE public.mcmaster_student_verifications
  ADD CONSTRAINT school_student_verifications_email_format_check
  CHECK (
    email = LOWER(BTRIM(email))
    AND email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}$'
  );
ALTER TABLE public.mcmaster_email_challenges
  ADD CONSTRAINT school_email_challenges_email_format_check
  CHECK (
    email = LOWER(BTRIM(email))
    AND email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}$'
  );

CREATE OR REPLACE FUNCTION public.protect_mcmaster_verification_flag()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.role() IS DISTINCT FROM 'service_role'
     AND NEW.is_mcmaster_verified IS DISTINCT FROM OLD.is_mcmaster_verified
     AND NEW.is_mcmaster_verified = TRUE THEN
    RAISE EXCEPTION 'School verification is server managed'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION school_selection_private.enforce_completed_school()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.deactivated_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.profile_status NOT IN ('student', 'working') THEN
    RAISE EXCEPTION 'Select a valid profile status' USING ERRCODE = '23514';
  END IF;

  IF NEW.profile_completed THEN
    IF current_user IN ('authenticated', 'anon')
       AND (TG_OP = 'INSERT' OR OLD.profile_completed IS DISTINCT FROM TRUE) THEN
      RAISE EXCEPTION 'Complete profile through the validated completion form'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.profile_status = 'student' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.schools AS school
        WHERE school.id = NEW.school_id
          AND school.active
          AND school.name = NEW.university
      ) THEN
        RAISE EXCEPTION 'A student profile requires a valid matching school'
          USING ERRCODE = '23514';
      END IF;
    ELSIF NEW.university IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.schools AS school
      WHERE school.id = NEW.school_id
        AND school.active
        AND school.name = NEW.university
    ) THEN
      RAISE EXCEPTION 'Selected school does not match the school directory'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP FUNCTION IF EXISTS public.complete_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE FUNCTION public.complete_profile(
  p_full_name TEXT DEFAULT NULL,
  p_university TEXT DEFAULT NULL,
  p_gender TEXT DEFAULT NULL,
  p_occupation TEXT DEFAULT NULL,
  p_bio TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL,
  p_profile_status TEXT DEFAULT 'student'
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_gender TEXT := NULLIF(BTRIM(p_gender), '');
  v_status TEXT := LOWER(COALESCE(NULLIF(BTRIM(p_profile_status), ''), 'student'));
  v_school public.schools%ROWTYPE;
  v_row public.profiles;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_status NOT IN ('student', 'working') THEN
    RAISE EXCEPTION 'Select a valid profile status' USING ERRCODE = '22023';
  END IF;
  IF v_status = 'student' AND NULLIF(BTRIM(p_university), '') IS NULL THEN
    RAISE EXCEPTION 'School is required for students' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_school
  FROM public.schools AS school
  WHERE school.active
    AND LOWER(school.name) = LOWER(
      CASE
        WHEN v_status = 'working' AND NULLIF(BTRIM(p_university), '') IS NULL
          THEN 'Other'
        ELSE BTRIM(p_university)
      END
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Select a supported school' USING ERRCODE = '22023';
  END IF;
  IF v_gender IS NULL
     OR v_gender NOT IN ('male', 'female', 'non_binary', 'prefer_not_to_say') THEN
    RAISE EXCEPTION 'Valid gender is required' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET full_name = COALESCE(NULLIF(BTRIM(p_full_name), ''), full_name),
      profile_status = v_status,
      university = CASE
        WHEN v_status = 'working' AND NULLIF(BTRIM(p_university), '') IS NULL THEN NULL
        ELSE v_school.name
      END,
      school_id = v_school.id,
      campus_id = (
        SELECT campus.id FROM public.school_campuses AS campus
        WHERE campus.school_id = v_school.id AND campus.is_default
        ORDER BY campus.id LIMIT 1
      ),
      gender = v_gender,
      occupation = NULLIF(BTRIM(p_occupation), ''),
      bio = COALESCE(NULLIF(BTRIM(p_bio), ''), bio),
      avatar_url = COALESCE(NULLIF(BTRIM(p_avatar_url), ''), avatar_url),
      profile_completed = TRUE,
      updated_at = clock_timestamp()
  WHERE id = v_user_id AND deactivated_at IS NULL
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active profile not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.issue_school_email_challenge(
  p_user_id UUID,
  p_school_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE (status TEXT, retry_after_seconds INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_email TEXT := LOWER(BTRIM(COALESCE(p_email, '')));
  v_domain TEXT := SPLIT_PART(v_email, '@', 2);
  v_existing public.mcmaster_email_challenges%ROWTYPE;
  v_wait INTEGER;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles AS profile
    JOIN public.schools AS school ON school.id = profile.school_id
    WHERE profile.id = p_user_id
      AND profile.deactivated_at IS NULL
      AND profile.profile_status = 'student'
      AND profile.school_id = p_school_id
      AND school.active
      AND CARDINALITY(school.verification_domains) > 0
      AND v_domain = ANY(school.verification_domains)
  ) THEN
    RAISE EXCEPTION 'Email domain does not match the selected school'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_code_hash, '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid verification hash' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));
  IF EXISTS (
    SELECT 1 FROM public.mcmaster_student_verifications AS verification
    WHERE verification.user_id = p_user_id
      AND verification.school_id = p_school_id
  ) THEN
    RETURN QUERY SELECT 'already_verified'::TEXT, 0;
    RETURN;
  END IF;

  SELECT challenge.* INTO v_existing
  FROM public.mcmaster_email_challenges AS challenge
  WHERE challenge.user_id = p_user_id
  FOR UPDATE;

  IF FOUND AND v_existing.last_sent_at > v_now - INTERVAL '60 seconds' THEN
    v_wait := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (
      v_existing.last_sent_at + INTERVAL '60 seconds' - v_now
    )))::INTEGER);
    RETURN QUERY SELECT 'cooldown'::TEXT, v_wait;
    RETURN;
  END IF;
  IF FOUND
     AND v_existing.send_window_started_at > v_now - INTERVAL '24 hours'
     AND v_existing.send_count >= 5 THEN
    v_wait := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (
      v_existing.send_window_started_at + INTERVAL '24 hours' - v_now
    )))::INTEGER);
    RETURN QUERY SELECT 'rate_limited'::TEXT, v_wait;
    RETURN;
  END IF;

  INSERT INTO public.mcmaster_email_challenges (
    user_id, school_id, email, code_hash, expires_at, attempt_count,
    last_sent_at, send_window_started_at, send_count, updated_at
  ) VALUES (
    p_user_id, p_school_id, v_email, p_code_hash, v_now + INTERVAL '10 minutes',
    0, v_now, v_now, 1, v_now
  )
  ON CONFLICT (user_id) DO UPDATE SET
    school_id = EXCLUDED.school_id,
    email = EXCLUDED.email,
    code_hash = EXCLUDED.code_hash,
    expires_at = EXCLUDED.expires_at,
    attempt_count = 0,
    last_sent_at = EXCLUDED.last_sent_at,
    send_window_started_at = CASE
      WHEN public.mcmaster_email_challenges.send_window_started_at <= v_now - INTERVAL '24 hours'
        THEN v_now
      ELSE public.mcmaster_email_challenges.send_window_started_at
    END,
    send_count = CASE
      WHEN public.mcmaster_email_challenges.send_window_started_at <= v_now - INTERVAL '24 hours'
        THEN 1
      ELSE public.mcmaster_email_challenges.send_count + 1
    END,
    updated_at = v_now;

  RETURN QUERY SELECT 'issued'::TEXT, 60;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_school_email_challenge(
  p_user_id UUID,
  p_school_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE (status TEXT, remaining_attempts INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_email TEXT := LOWER(BTRIM(COALESCE(p_email, '')));
  v_challenge public.mcmaster_email_challenges%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles AS profile
    WHERE profile.id = p_user_id
      AND profile.deactivated_at IS NULL
      AND profile.profile_status = 'student'
      AND profile.school_id = p_school_id
  ) THEN
    RAISE EXCEPTION 'Selected school is no longer active for this profile'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));
  SELECT challenge.* INTO v_challenge
  FROM public.mcmaster_email_challenges AS challenge
  WHERE challenge.user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN QUERY SELECT 'missing'::TEXT, 0; RETURN; END IF;
  IF v_challenge.expires_at <= v_now THEN
    DELETE FROM public.mcmaster_email_challenges WHERE user_id = p_user_id;
    RETURN QUERY SELECT 'expired'::TEXT, 0; RETURN;
  END IF;
  IF v_challenge.attempt_count >= 5 THEN
    RETURN QUERY SELECT 'locked'::TEXT, 0; RETURN;
  END IF;

  IF v_challenge.school_id IS DISTINCT FROM p_school_id
     OR v_challenge.email IS DISTINCT FROM v_email
     OR v_challenge.code_hash IS DISTINCT FROM p_code_hash THEN
    UPDATE public.mcmaster_email_challenges
    SET attempt_count = LEAST(attempt_count + 1, 5), updated_at = v_now
    WHERE user_id = p_user_id
    RETURNING * INTO v_challenge;
    RETURN QUERY SELECT
      CASE WHEN v_challenge.attempt_count >= 5 THEN 'locked' ELSE 'invalid' END,
      GREATEST(0, 5 - v_challenge.attempt_count);
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.mcmaster_student_verifications (
      user_id, school_id, email, verified_at, created_at, updated_at
    ) VALUES (p_user_id, p_school_id, v_email, v_now, v_now, v_now)
    ON CONFLICT (user_id) DO UPDATE SET
      school_id = EXCLUDED.school_id,
      email = EXCLUDED.email,
      verified_at = EXCLUDED.verified_at,
      updated_at = EXCLUDED.updated_at;
  EXCEPTION WHEN unique_violation THEN
    RETURN QUERY SELECT 'email_in_use'::TEXT, 0; RETURN;
  END;

  UPDATE public.profiles
  SET is_mcmaster_verified = TRUE, updated_at = v_now
  WHERE id = p_user_id
    AND profile_status = 'student'
    AND school_id = p_school_id;
  DELETE FROM public.mcmaster_email_challenges WHERE user_id = p_user_id;
  RETURN QUERY SELECT 'verified'::TEXT, 5;
END;
$$;

CREATE OR REPLACE FUNCTION public.unlink_school_student_verification(p_user_id UUID)
RETURNS TABLE(unlinked BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE v_had_binding BOOLEAN;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.mcmaster_student_verifications WHERE user_id = p_user_id
  ) OR EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_user_id AND is_mcmaster_verified
  ) INTO v_had_binding;
  DELETE FROM public.mcmaster_email_challenges WHERE user_id = p_user_id;
  DELETE FROM public.mcmaster_student_verifications WHERE user_id = p_user_id;
  UPDATE public.profiles
  SET is_mcmaster_verified = FALSE, updated_at = clock_timestamp()
  WHERE id = p_user_id AND is_mcmaster_verified;
  RETURN QUERY SELECT v_had_binding;
END;
$$;

REVOKE ALL ON FUNCTION public.issue_school_email_challenge(UUID, UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.confirm_school_email_challenge(UUID, UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.unlink_school_student_verification(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_school_email_challenge(UUID, UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_school_email_challenge(UUID, UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.unlink_school_student_verification(UUID)
  TO service_role;

-- Keep the already-deployed Edge Function operational while the generalized
-- version rolls out. These legacy RPC names now target McMaster explicitly.
CREATE OR REPLACE FUNCTION public.issue_mcmaster_email_challenge(
  p_user_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE(status TEXT, retry_after_seconds INTEGER)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT *
  FROM public.issue_school_email_challenge(
    p_user_id,
    (SELECT id FROM public.schools WHERE name = 'McMaster University'),
    p_email,
    p_code_hash
  );
$$;

CREATE OR REPLACE FUNCTION public.confirm_mcmaster_email_challenge(
  p_user_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE(status TEXT, remaining_attempts INTEGER)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT *
  FROM public.confirm_school_email_challenge(
    p_user_id,
    (SELECT id FROM public.schools WHERE name = 'McMaster University'),
    p_email,
    p_code_hash
  );
$$;

CREATE OR REPLACE FUNCTION public.unlink_mcmaster_student_verification(p_user_id UUID)
RETURNS TABLE(unlinked BOOLEAN)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT * FROM public.unlink_school_student_verification(p_user_id);
$$;

REVOKE ALL ON FUNCTION public.issue_mcmaster_email_challenge(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.confirm_mcmaster_email_challenge(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.unlink_mcmaster_student_verification(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_mcmaster_email_challenge(UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_mcmaster_email_challenge(UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.unlink_mcmaster_student_verification(UUID)
  TO service_role;

CREATE OR REPLACE FUNCTION public.revoke_school_verification_on_profile_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF OLD.school_id IS DISTINCT FROM NEW.school_id
     OR OLD.profile_status IS DISTINCT FROM NEW.profile_status
     OR (NEW.profile_status = 'working' AND OLD.is_mcmaster_verified) THEN
    NEW.is_mcmaster_verified := FALSE;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_school_verification_on_profile_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS profiles_revoke_school_verification_before_change ON public.profiles;
CREATE TRIGGER profiles_revoke_school_verification_before_change
BEFORE UPDATE OF school_id, profile_status ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.revoke_school_verification_on_profile_change();

CREATE OR REPLACE FUNCTION public.cleanup_school_verification_after_profile_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF OLD.school_id IS DISTINCT FROM NEW.school_id
     OR OLD.profile_status IS DISTINCT FROM NEW.profile_status THEN
    DELETE FROM public.mcmaster_email_challenges WHERE user_id = NEW.id;
    DELETE FROM public.mcmaster_student_verifications WHERE user_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_school_verification_after_profile_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS profiles_cleanup_school_verification_after_change ON public.profiles;
CREATE TRIGGER profiles_cleanup_school_verification_after_change
AFTER UPDATE OF school_id, profile_status ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.cleanup_school_verification_after_profile_change();

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
  profile.is_graduated,
  profile.public_uid,
  profile.cover_image_url,
  profile.profile_status
FROM public.profiles AS profile
WHERE profile.deactivated_at IS NULL
  AND NOT moderation_private.is_user_suspended(profile.id)
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1 FROM public.user_blocks AS block_row
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

NOTIFY pgrst, 'reload schema';
COMMIT;
