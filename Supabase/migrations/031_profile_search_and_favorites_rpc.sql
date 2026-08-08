-- 031_profile_search_and_favorites_rpc.sql
-- Profile search + profile-facing favorites feed

CREATE OR REPLACE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.birthday,
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
  p.updated_at
FROM public.profiles p
LEFT JOIN public.user_geo_profiles g
  ON g.user_id = p.id;

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
  ip_masked TEXT,
  region TEXT,
  country_name TEXT,
  is_following BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_query TEXT := COALESCE(NULLIF(btrim(p_query), ''), '');
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    COALESCE(NULLIF(p.full_name, ''), split_part(p.email, '@', 1), '用户') AS full_name,
    p.avatar_url,
    p.university,
    p.bio,
    g.ip_masked,
    g.region,
    g.country_name,
    EXISTS (
      SELECT 1
      FROM public.user_follows uf
      WHERE uf.follower_id = v_user_id
        AND uf.following_id = p.id
    ) AS is_following,
    CASE
      WHEN v_user_id IS NULL THEN FALSE
      ELSE public.is_mutual_follow(v_user_id, p.id)
    END AS is_mutual_follow
  FROM public.profiles p
  LEFT JOIN public.user_geo_profiles g ON g.user_id = p.id
  WHERE v_query = ''
    OR COALESCE(p.full_name, '') ILIKE '%' || v_query || '%'
    OR COALESCE(p.university, '') ILIKE '%' || v_query || '%'
    OR split_part(p.email, '@', 1) ILIKE '%' || v_query || '%'
  ORDER BY p.verified DESC, p.updated_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_profiles(TEXT, INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_my_favorite_posts(
  p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
  post_id UUID,
  post_type TEXT,
  title TEXT,
  description TEXT,
  price NUMERIC,
  subtitle TEXT,
  cover_image TEXT,
  saved_at TIMESTAMPTZ,
  author_id UUID,
  author_name TEXT,
  author_avatar TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    p.id AS post_id,
    p.type AS post_type,
    p.title,
    p.description,
    CASE
      WHEN p.type = 'rent' THEN r.price
      WHEN p.type = 'secondhand' THEN s.price
      ELSE NULL
    END AS price,
    CASE
      WHEN p.type = 'rent' THEN COALESCE(r.location, '')
      WHEN p.type = 'secondhand' THEN COALESCE(s.condition, '')
      ELSE ''
    END AS subtitle,
    (
      SELECT pi.url
      FROM public.post_images pi
      WHERE pi.post_id = p.id
      ORDER BY pi.order_index ASC
      LIMIT 1
    ) AS cover_image,
    f.created_at AS saved_at,
    p.user_id AS author_id,
    COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
    pr.avatar_url AS author_avatar
  FROM public.favorites f
  JOIN public.posts p ON p.id = f.post_id
  JOIN public.profiles pr ON pr.id = p.user_id
  LEFT JOIN public.rent_posts r ON r.id = p.id
  LEFT JOIN public.secondhand_posts s ON s.id = p.id
  WHERE f.user_id = auth.uid()
    AND p.type IN ('rent', 'secondhand')
    AND p.status = 'active'
  ORDER BY f.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 300));
$$;

GRANT EXECUTE ON FUNCTION public.get_my_favorite_posts(INTEGER)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
