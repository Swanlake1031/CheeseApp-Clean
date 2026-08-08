-- 118_private_profile_activity.sql
-- Viewer-relative, private activity history for the signed-in profile.
--
-- This migration reuses posts, likes, comments, and favorites. It does not
-- create a second activity store or accept a client-supplied user ID.

BEGIN;

CREATE INDEX IF NOT EXISTS likes_owner_post_activity_idx
  ON public.likes (user_id, created_at DESC, target_id DESC)
  WHERE target_type = 'post';

CREATE INDEX IF NOT EXISTS favorites_owner_activity_idx
  ON public.favorites (user_id, created_at DESC, post_id DESC);

CREATE INDEX IF NOT EXISTS comments_owner_activity_idx
  ON public.comments (user_id, created_at DESC, id DESC)
  WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS posts_owner_activity_idx
  ON public.posts (user_id, created_at DESC, id DESC)
  WHERE status <> 'deleted';

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
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF v_kind NOT IN ('published', 'liked', 'commented', 'favorited') THEN
    RAISE EXCEPTION 'Unsupported profile activity kind'
      USING ERRCODE = '22023';
  END IF;

  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Both cursor fields must be supplied together'
      USING ERRCODE = '22023';
  END IF;

  IF v_kind = 'published' THEN
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
      CASE
        WHEN post_row.type = 'rent' THEN rent.price
        WHEN post_row.type = 'secondhand' THEN market.price
        ELSE NULL
      END,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id
        LIMIT 1
      )
    FROM public.posts post_row
    LEFT JOIN public.rent_posts rent ON rent.id = post_row.id
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE post_row.user_id = v_me
      AND post_row.type IN ('forum', 'rent', 'secondhand')
      AND post_row.status <> 'deleted'
      AND (
        p_before_created_at IS NULL
        OR (post_row.created_at, post_row.id)
          < (p_before_created_at, p_before_id)
      )
    ORDER BY post_row.created_at DESC, post_row.id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'liked' THEN
    RETURN QUERY
    SELECT
      liked.target_id,
      post_row.id,
      post_row.type,
      post_row.title,
      COALESCE(post_row.description, ''),
      COALESCE(post_row.description, ''),
      NULL::UUID,
      liked.created_at,
      CASE
        WHEN post_row.type = 'rent' THEN rent.price
        WHEN post_row.type = 'secondhand' THEN market.price
        ELSE NULL
      END,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id
        LIMIT 1
      )
    FROM public.likes liked
    JOIN public.posts post_row
      ON post_row.id = liked.target_id
    LEFT JOIN public.rent_posts rent ON rent.id = post_row.id
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE liked.user_id = v_me
      AND liked.target_type = 'post'
      AND post_row.type IN ('forum', 'rent', 'secondhand')
      AND public.can_view_post(post_row.id)
      AND (
        p_before_created_at IS NULL
        OR (liked.created_at, liked.target_id)
          < (p_before_created_at, p_before_id)
      )
    ORDER BY liked.created_at DESC, liked.target_id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'commented' THEN
    RETURN QUERY
    SELECT
      comment_row.id,
      post_row.id,
      post_row.type,
      post_row.title,
      COALESCE(post_row.description, ''),
      comment_row.content,
      comment_row.id,
      comment_row.created_at,
      CASE
        WHEN post_row.type = 'rent' THEN rent.price
        WHEN post_row.type = 'secondhand' THEN market.price
        ELSE NULL
      END,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = post_row.id
        ORDER BY image.order_index, image.id
        LIMIT 1
      )
    FROM public.comments comment_row
    JOIN public.posts post_row
      ON post_row.id = comment_row.post_id
    LEFT JOIN public.rent_posts rent ON rent.id = post_row.id
    LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
    WHERE comment_row.user_id = v_me
      AND comment_row.is_deleted = FALSE
      AND post_row.type IN ('forum', 'rent', 'secondhand')
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
    favorite.post_id,
    post_row.id,
    post_row.type,
    post_row.title,
    COALESCE(post_row.description, ''),
    COALESCE(post_row.description, ''),
    NULL::UUID,
    favorite.created_at,
    CASE
      WHEN post_row.type = 'rent' THEN rent.price
      WHEN post_row.type = 'secondhand' THEN market.price
      ELSE NULL
    END,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = post_row.id
      ORDER BY image.order_index, image.id
      LIMIT 1
    )
  FROM public.favorites favorite
  JOIN public.posts post_row
    ON post_row.id = favorite.post_id
  LEFT JOIN public.rent_posts rent ON rent.id = post_row.id
  LEFT JOIN public.secondhand_posts market ON market.id = post_row.id
  WHERE favorite.user_id = v_me
    AND post_row.type IN ('forum', 'rent', 'secondhand')
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
