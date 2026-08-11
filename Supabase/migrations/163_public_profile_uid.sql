-- 163_public_profile_uid.sql
--
-- Adds an immutable, database-generated eight-digit identifier for sharing
-- and profile lookup. Auth UUIDs remain the internal primary/foreign keys.

BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN public_uid TEXT;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_public_uid_key UNIQUE (public_uid);

CREATE FUNCTION public.assign_profile_public_uid()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_candidate TEXT;
  v_attempts INTEGER := 0;
BEGIN
  -- Serialize the very small allocation step. Combined with the unique
  -- constraint, this prevents concurrent registrations from accepting the
  -- same randomly generated value.
  PERFORM pg_advisory_xact_lock(58310427);

  LOOP
    v_attempts := v_attempts + 1;
    IF v_attempts > 1000 THEN
      RAISE EXCEPTION 'Unable to allocate public user ID'
        USING ERRCODE = '54000';
    END IF;

    v_candidate := (
      FLOOR(random() * 90000000)::BIGINT + 10000000
    )::TEXT;

    IF NOT EXISTS (
      SELECT 1
      FROM public.profiles profile
      WHERE profile.public_uid = v_candidate
    ) THEN
      NEW.public_uid := v_candidate;
      RETURN NEW;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_profile_public_uid() FROM PUBLIC;

CREATE TRIGGER profiles_assign_public_uid
BEFORE INSERT ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.assign_profile_public_uid();

DO $$
DECLARE
  v_profile_id UUID;
  v_candidate TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(58310427);

  FOR v_profile_id IN
    SELECT profile.id
    FROM public.profiles profile
    WHERE profile.public_uid IS NULL
    ORDER BY profile.created_at, profile.id
  LOOP
    LOOP
      v_candidate := (
        FLOOR(random() * 90000000)::BIGINT + 10000000
      )::TEXT;

      BEGIN
        UPDATE public.profiles
        SET public_uid = v_candidate
        WHERE id = v_profile_id;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        -- Retry against the database constraint instead of assuming a random
        -- candidate cannot collide.
      END;
    END LOOP;
  END LOOP;
END;
$$;

ALTER TABLE public.profiles
  ALTER COLUMN public_uid SET NOT NULL;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_public_uid_format_check
  CHECK (public_uid ~ '^[0-9]{8}$');

CREATE FUNCTION public.prevent_profile_public_uid_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF NEW.public_uid IS DISTINCT FROM OLD.public_uid THEN
    RAISE EXCEPTION 'Public user ID cannot be changed'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_profile_public_uid_change() FROM PUBLIC;

CREATE TRIGGER profiles_prevent_public_uid_change
BEFORE UPDATE OF public_uid ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.prevent_profile_public_uid_change();

COMMENT ON COLUMN public.profiles.public_uid IS
  'Immutable database-generated eight-digit public profile identifier.';

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
  profile.public_uid
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

DROP FUNCTION public.search_profiles(TEXT, INTEGER);

CREATE FUNCTION public.search_profiles(
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT,
  bio TEXT,
  is_following BOOLEAN,
  is_mutual_follow BOOLEAN,
  public_uid TEXT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  WITH input AS (
    SELECT LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text
  )
  SELECT
    profile.id,
    profile.full_name,
    profile.avatar_url,
    profile.university,
    profile.bio,
    EXISTS (
      SELECT 1
      FROM public.user_follows follow_row
      WHERE follow_row.follower_id = auth.uid()
        AND follow_row.following_id = profile.id
    ),
    EXISTS (
      SELECT 1
      FROM public.user_follows outgoing
      JOIN public.user_follows incoming
        ON incoming.follower_id = outgoing.following_id
       AND incoming.following_id = outgoing.follower_id
      WHERE outgoing.follower_id = auth.uid()
        AND outgoing.following_id = profile.id
    ),
    profile.public_uid
  FROM public.profile_public_view profile
  CROSS JOIN input
  WHERE auth.uid() IS NOT NULL
    AND (
      input.query_text = ''
      OR profile.public_uid = input.query_text
      OR profile.full_name ILIKE '%' || input.query_text || '%'
      OR COALESCE(profile.university, '') ILIKE '%' || input.query_text || '%'
    )
  ORDER BY
    (profile.public_uid = input.query_text) DESC,
    profile.full_name,
    profile.id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
$$;

REVOKE ALL ON FUNCTION public.search_profiles(TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_profiles(TEXT, INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
