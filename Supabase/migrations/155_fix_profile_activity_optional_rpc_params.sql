-- 155_fix_profile_activity_optional_rpc_params.sql
--
-- Swift's synthesized Encodable implementation omits nil optional values.
-- The unfiltered published-content request therefore does not send
-- p_post_type or either cursor argument. Keep one canonical RPC and make
-- those optional inputs optional in the database contract as well.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_profile_activity_page(
  p_activity_kind TEXT,
  p_post_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'visible',
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
  v_visibility TEXT := LOWER(BTRIM(COALESCE(p_visibility, 'visible')));
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_visibility NOT IN ('visible', 'hidden') THEN
    RAISE EXCEPTION 'Unsupported post visibility' USING ERRCODE = '22023';
  END IF;
  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Both cursor fields must be supplied together'
      USING ERRCODE = '22023';
  END IF;

  IF v_kind <> 'published' THEN
    IF v_visibility <> 'visible' THEN
      RAISE EXCEPTION 'Hidden filtering is only supported for published activity'
        USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    SELECT * FROM public.get_my_profile_activity_page(
      p_activity_kind,
      p_before_created_at,
      p_before_id,
      p_limit
    );
    RETURN;
  END IF;

  IF v_post_type IS NOT NULL AND v_post_type NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'Unsupported published post type' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    post_row.id,
    post_row.id,
    post_row.type,
    post_row.title,
    COALESCE(post_row.description, ''),
    COALESCE(post_row.description, ''),
    NULL::UUID,
    post_row.created_at,
    market.price,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = post_row.id
      ORDER BY image.order_index, image.id
      LIMIT 1
    )
  FROM public.posts post_row
  LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
  WHERE post_row.user_id = v_me
    AND post_row.type IN ('forum', 'secondhand')
    AND (v_post_type IS NULL OR post_row.type = v_post_type)
    AND post_row.status <> 'deleted'
    AND post_row.is_private = (v_visibility = 'hidden')
    AND (
      p_before_created_at IS NULL
      OR (post_row.created_at, post_row.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY post_row.created_at DESC, post_row.id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
