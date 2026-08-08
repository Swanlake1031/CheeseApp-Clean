-- 148_search_profiles_by_uid.sql
-- Allows an authenticated user to find an active, visible profile by its
-- canonical database UUID in addition to display name and university.

BEGIN;

CREATE OR REPLACE FUNCTION public.search_profiles(
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
  is_mutual_follow BOOLEAN
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
    )
  FROM public.profile_public_view profile
  CROSS JOIN input
  WHERE auth.uid() IS NOT NULL
    AND (
      input.query_text = ''
      OR LOWER(profile.id::TEXT) = input.query_text
      OR profile.full_name ILIKE '%' || input.query_text || '%'
      OR COALESCE(profile.university, '') ILIKE '%' || input.query_text || '%'
    )
  ORDER BY
    (LOWER(profile.id::TEXT) = input.query_text) DESC,
    profile.full_name,
    profile.id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
$$;

REVOKE ALL ON FUNCTION public.search_profiles(TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_profiles(TEXT, INTEGER)
  TO authenticated, service_role;

COMMIT;
