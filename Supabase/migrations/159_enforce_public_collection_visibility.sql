-- 159_enforce_public_collection_visibility.sql
--
-- Owner-capable detail views intentionally expose an author's private post to
-- that author. Surface the privacy bit so collection queries can explicitly
-- remain public-only, and make legacy profile activity/profile-post RPCs use
-- the same public collection contract.

BEGIN;

CREATE OR REPLACE VIEW public.secondhand_posts_view AS
SELECT
  s.id, s.price, s.original_price, s.is_negotiable, s.is_free,
  s.category, s.condition, s.can_ship, s.shipping_fee,
  s.quantity, s.sold_count,
  tier.effective_highlight_type AS highlight_type,
  s.pinned_until, s.view_count, s.like_count, s.comment_count, s.save_count,
  public.calculate_hot_score(
    s.view_count, s.like_count, s.comment_count, s.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id, p.title, p.description, p.status, p.is_anonymous,
  p.created_at, p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = s.id
    ),
    '[]'::JSON
  ) AS images,
  CASE
    WHEN s.original_price IS NOT NULL AND s.original_price > 0
    THEN ROUND((1 - s.price / s.original_price) * 100)
    ELSE NULL
  END AS discount_percent,
  s.expires_at,
  (s.expires_at IS NOT NULL AND s.expires_at <= NOW()) AS is_expired,
  CASE WHEN p.is_anonymous THEN FALSE ELSE pr.is_mcmaster_verified END
    AS user_mcmaster_verified,
  p.is_private
FROM public.secondhand_posts s
JOIN public.posts p ON p.id = s.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN s.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND s.pinned_until IS NOT NULL
      AND s.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE s.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND (p.is_private = FALSE OR p.user_id = auth.uid());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id, f.board_id, board.slug AS board_slug, board.name AS board_name,
  board.icon AS board_icon,
  board.allows_anonymous_posts AS board_allows_anonymous,
  f.allow_comments, f.is_pinned, f.is_locked, f.like_count, f.comment_count,
  tier.effective_highlight_type AS highlight_type, f.pinned_until,
  f.view_count, f.save_count,
  public.calculate_hot_score(
    f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE p.user_id
  END AS user_id,
  p.title, p.description, p.status, p.is_anonymous, p.created_at, p.updated_at,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.full_name
  END AS user_name,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.avatar_url
  END AS user_avatar,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.university
  END AS user_university,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.verified
  END AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = f.id
    ),
    '[]'::JSON
  ) AS images,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN FALSE
    ELSE COALESCE(pr.is_official, FALSE)
  END AS user_official,
  (p.user_id = auth.uid()) AS viewer_owns_post,
  CASE
    WHEN p.is_anonymous THEN FALSE
    ELSE pr.is_mcmaster_verified
  END AS user_mcmaster_verified,
  p.is_private
FROM public.forum_posts f
JOIN public.posts p ON p.id = f.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
JOIN public.forum_boards board ON board.id = f.board_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND f.pinned_until IS NOT NULL
      AND f.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE f.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND (p.is_private = FALSE OR p.user_id = auth.uid())
  AND board.status <> 'archived';

ALTER VIEW public.forum_posts_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.forum_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.forum_posts_view TO authenticated, service_role;

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
      AND post_row.is_private = FALSE
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
      AND post_row.is_private = FALSE
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
      AND post_row.is_private = FALSE
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
    AND post_row.is_private = FALSE
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

CREATE OR REPLACE FUNCTION public.get_profile_posts(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  type TEXT,
  title TEXT,
  description TEXT,
  status TEXT,
  is_anonymous BOOLEAN,
  is_private BOOLEAN,
  created_at TIMESTAMPTZ,
  price NUMERIC,
  original_price NUMERIC,
  category TEXT,
  condition TEXT,
  is_negotiable BOOLEAN,
  board_id UUID,
  board_name TEXT,
  allow_comments BOOLEAN,
  user_name TEXT,
  user_avatar TEXT,
  images JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    post_row.id, post_row.user_id, post_row.type, post_row.title,
    COALESCE(post_row.description, ''), post_row.status,
    post_row.is_anonymous, post_row.is_private, post_row.created_at,
    market.price, market.original_price, market.category, market.condition,
    market.is_negotiable, forum.board_id, board.name, forum.allow_comments,
    profile.full_name, profile.avatar_url,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', image.id,
            'url', image.url,
            'order_index', image.order_index
          )
          ORDER BY image.order_index, image.id
        )
        FROM public.post_images image
        WHERE image.post_id = post_row.id
      ),
      '[]'::JSONB
    )
  FROM public.posts post_row
  JOIN public.profiles profile ON profile.id = post_row.user_id
  LEFT JOIN public.secondhand_posts market
    ON market.id = post_row.id AND post_row.type = 'secondhand'
  LEFT JOIN public.forum_posts forum
    ON forum.id = post_row.id AND post_row.type = 'forum'
  LEFT JOIN public.forum_boards board ON board.id = forum.board_id
  WHERE post_row.user_id = p_user_id
    AND post_row.type IN ('forum', 'secondhand')
    AND post_row.status = 'active'
    AND post_row.is_private = FALSE
    AND profile.deactivated_at IS NULL
    AND public.can_view_post(post_row.id)
    AND (
      post_row.type <> 'forum'
      OR post_row.is_anonymous = FALSE
      OR post_row.user_id = v_me
    )
  ORDER BY post_row.created_at DESC, post_row.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_profile_posts(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_profile_posts(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
