-- 142_filter_published_profile_activity.sql
--
-- Adds a backward-compatible overload for filtering the current user's
-- published activity by live post type. The existing four-argument RPC remains
-- available to older app builds.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_profile_activity_page(
  p_activity_kind TEXT,
  p_post_type TEXT,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 30
)
RETURNS TABLE (
  activity_id UUID,
  post_id UUID,
  post_type TEXT,
  post_title TEXT,
  post_summary TEXT,
  activity_summary TEXT,
  comment_id UUID,
  activity_created_at TIMESTAMPTZ,
  price NUMERIC,
  cover_image TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_kind TEXT := LOWER(BTRIM(COALESCE(p_activity_kind, '')));
  v_post_type TEXT := NULLIF(LOWER(BTRIM(COALESCE(p_post_type, ''))), '');
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
BEGIN
  IF v_post_type IS NULL THEN
    RETURN QUERY
    SELECT *
    FROM public.get_my_profile_activity_page(
      p_activity_kind,
      p_before_created_at,
      p_before_id,
      p_limit
    );
    RETURN;
  END IF;

  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF v_kind <> 'published' THEN
    RAISE EXCEPTION 'Post type filtering is only supported for published activity'
      USING ERRCODE = '22023';
  END IF;

  IF v_post_type NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'Unsupported published post type' USING ERRCODE = '22023';
  END IF;

  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Both cursor fields must be supplied together'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    post.id,
    post.id,
    post.type,
    post.title,
    COALESCE(post.description, ''),
    COALESCE(post.description, ''),
    NULL::UUID,
    post.created_at,
    market.price,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = post.id
      ORDER BY image.order_index, image.id
      LIMIT 1
    )
  FROM public.posts post
  LEFT JOIN public.secondhand_posts market ON market.id = post.id
  WHERE post.user_id = v_me
    AND post.type = v_post_type
    AND post.status <> 'deleted'
    AND (
      p_before_created_at IS NULL
      OR (post.created_at, post.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY post.created_at DESC, post.id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;

COMMIT;
