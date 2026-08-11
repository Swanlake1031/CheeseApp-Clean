-- 158_fix_legacy_profile_comment_activity.sql
--
-- Migration 157 kept the legacy four-argument profile activity RPC for
-- installed clients, but its commented branch accidentally returned three
-- duplicate columns. Restore the ten-column contract while retaining the
-- active/viewable post filters introduced by 157.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_profile_activity_page(
  p_activity_kind TEXT,
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
  v_kind TEXT := lower(btrim(COALESCE(p_activity_kind, '')));
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_kind NOT IN ('published', 'liked', 'commented', 'favorited') THEN
    RAISE EXCEPTION 'Unsupported profile activity kind' USING ERRCODE = '22023';
  END IF;
  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Both cursor fields must be supplied together'
      USING ERRCODE = '22023';
  END IF;

  IF v_kind = 'published' THEN
    RETURN QUERY
    SELECT
      post_row.id, post_row.id, post_row.type, post_row.title,
      COALESCE(post_row.description, ''), COALESCE(post_row.description, ''),
      NULL::UUID, post_row.created_at, market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.posts post_row
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE post_row.user_id = v_me
      AND post_row.type IN ('forum', 'secondhand')
      AND post_row.status = 'active'
      AND (
        p_before_created_at IS NULL
        OR (post_row.created_at, post_row.id) < (p_before_created_at, p_before_id)
      )
    ORDER BY post_row.created_at DESC, post_row.id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'liked' THEN
    RETURN QUERY
    SELECT
      liked.target_id, post_row.id, post_row.type, post_row.title,
      COALESCE(post_row.description, ''), COALESCE(post_row.description, ''),
      NULL::UUID, liked.created_at, market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.likes liked
    JOIN public.posts post_row ON post_row.id = liked.target_id
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE liked.user_id = v_me
      AND liked.target_type = 'post'
      AND post_row.type IN ('forum', 'secondhand')
      AND post_row.status = 'active'
      AND public.can_view_post(post_row.id)
      AND (
        p_before_created_at IS NULL
        OR (liked.created_at, liked.target_id) < (p_before_created_at, p_before_id)
      )
    ORDER BY liked.created_at DESC, liked.target_id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'commented' THEN
    RETURN QUERY
    SELECT
      comment_row.id, post_row.id, post_row.type, post_row.title,
      COALESCE(post_row.description, ''), comment_row.content,
      comment_row.id, comment_row.created_at, market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.comments comment_row
    JOIN public.posts post_row ON post_row.id = comment_row.post_id
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE comment_row.user_id = v_me
      AND comment_row.is_deleted = FALSE
      AND post_row.type IN ('forum', 'secondhand')
      AND post_row.status = 'active'
      AND public.can_view_post(post_row.id)
      AND (
        p_before_created_at IS NULL
        OR (comment_row.created_at, comment_row.id)
          < (p_before_created_at, p_before_id)
      )
    ORDER BY comment_row.created_at DESC, comment_row.id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    favorite.post_id, post_row.id, post_row.type, post_row.title,
    COALESCE(post_row.description, ''), COALESCE(post_row.description, ''),
    NULL::UUID, favorite.created_at, market.price,
    (
      SELECT image.url FROM public.post_images image
      WHERE image.post_id = post_row.id
      ORDER BY image.order_index, image.id LIMIT 1
    )
  FROM public.favorites favorite
  JOIN public.posts post_row ON post_row.id = favorite.post_id
  LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
  WHERE favorite.user_id = v_me
    AND post_row.type IN ('forum', 'secondhand')
    AND post_row.status = 'active'
    AND public.can_view_post(post_row.id)
    AND (
      p_before_created_at IS NULL
      OR (favorite.created_at, favorite.post_id)
        < (p_before_created_at, p_before_id)
    )
  ORDER BY favorite.created_at DESC, favorite.post_id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
