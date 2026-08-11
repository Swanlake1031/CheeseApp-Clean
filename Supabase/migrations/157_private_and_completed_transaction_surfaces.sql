-- 157_private_and_completed_transaction_surfaces.sql
--
-- Separates recoverable private posts from completed Marketplace archives.
-- Completed listings remain stored, but never re-enter normal post/profile
-- queries. Transaction history is returned as a collection (not a single-row
-- active-listing lookup), so a completed listing cannot produce PGRST116 when
-- it disappears from secondhand_posts_view.

BEGIN;

CREATE OR REPLACE FUNCTION public.set_my_post_hidden(
  p_post_id UUID,
  p_hidden BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_type TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_hidden IS NULL THEN
    RAISE EXCEPTION 'Private state is required' USING ERRCODE = '22023';
  END IF;

  SELECT post_row.type INTO v_type
  FROM public.posts post_row
  WHERE post_row.id = p_post_id
    AND post_row.user_id = v_me
    AND post_row.type IN ('forum', 'secondhand')
    AND post_row.status = 'active'
  FOR UPDATE;

  IF v_type IS NULL THEN
    RAISE EXCEPTION 'Active post not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  IF p_hidden THEN
    UPDATE public.posts
    SET is_private = TRUE,
        hidden_at = v_now,
        hidden_reason = 'user',
        updated_at = v_now
    WHERE id = p_post_id;
  ELSE
    UPDATE public.posts
    SET is_private = FALSE,
        hidden_at = NULL,
        hidden_reason = NULL,
        updated_at = v_now
    WHERE id = p_post_id;

    IF v_type = 'secondhand' THEN
      PERFORM set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);

      UPDATE public.secondhand_posts
      SET availability_confirmed_at = v_now,
          availability_reminder_sent_at = NULL,
          availability_cycle = availability_cycle + 1,
          sold_at = NULL,
          expires_at = v_now + INTERVAL '30 days'
      WHERE id = p_post_id;

      PERFORM set_config('cheese.secondhand_lifecycle_write', '', TRUE);
    END IF;
  END IF;

  RETURN p_hidden;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  TO authenticated;

-- Stopping a listing is a recoverable owner action. It ends every active
-- transaction, but the post itself enters the normal private lifecycle.
CREATE OR REPLACE FUNCTION public.stop_selling_secondhand_listing(
  p_listing_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_listing_status TEXT;
  v_intent public.secondhand_purchase_intents%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT post_row.status INTO v_listing_status
  FROM public.posts post_row
  JOIN public.secondhand_posts listing ON listing.id = post_row.id
  WHERE post_row.id = p_listing_id
    AND post_row.type = 'secondhand'
    AND post_row.user_id = v_me
  FOR UPDATE OF post_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;
  IF v_listing_status <> 'active' THEN
    RAISE EXCEPTION 'Listing is no longer active'
      USING ERRCODE = '55000';
  END IF;

  FOR v_intent IN
    SELECT *
    FROM public.secondhand_purchase_intents intent
    WHERE intent.listing_id = p_listing_id
      AND intent.status = 'active'
    FOR UPDATE
  LOOP
    UPDATE public.secondhand_purchase_intents
    SET status = 'seller_stopped',
        ended_at = v_now,
        updated_at = v_now
    WHERE id = v_intent.id;

    PERFORM public.append_secondhand_transaction_chat_event(
      v_intent.conversation_id,
      v_me,
      p_listing_id,
      v_intent.id,
      'seller_stopped',
      '卖家已停止出售该商品'
    );
  END LOOP;

  UPDATE public.posts
  SET status = 'active',
      is_private = TRUE,
      hidden_at = v_now,
      hidden_reason = 'user',
      updated_at = v_now
  WHERE id = p_listing_id;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  TO authenticated;

-- Keep the legacy four-argument activity contract for installed clients, but
-- all regular activity surfaces now require an active, viewable post.
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
  v_kind TEXT := lower(btrim(COALESCE(p_activity_kind, '')));
  v_post_type TEXT := NULLIF(lower(btrim(COALESCE(p_post_type, ''))), '');
  v_visibility TEXT := lower(btrim(COALESCE(p_visibility, 'visible')));
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
      RAISE EXCEPTION 'Private filtering is only supported for published activity'
        USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    SELECT * FROM public.get_my_profile_activity_page(
      p_activity_kind, p_before_created_at, p_before_id, p_limit
    );
    RETURN;
  END IF;

  IF v_post_type IS NOT NULL AND v_post_type NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'Unsupported published post type' USING ERRCODE = '22023';
  END IF;

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
    AND (v_post_type IS NULL OR post_row.type = v_post_type)
    AND post_row.status = 'active'
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
    AND profile.deactivated_at IS NULL
    AND (
      post_row.user_id = v_me
      OR public.can_view_post(post_row.id)
    )
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

CREATE OR REPLACE FUNCTION public.get_my_completed_secondhand_transactions(
  p_role TEXT
)
RETURNS TABLE (
  transaction_id UUID,
  listing_id UUID,
  role TEXT,
  listing_title TEXT,
  price NUMERIC,
  cover_image TEXT,
  counterparty_id UUID,
  counterparty_name TEXT,
  counterparty_avatar TEXT,
  completed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_role TEXT := lower(btrim(COALESCE(p_role, '')));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_role NOT IN ('buyer', 'seller') THEN
    RAISE EXCEPTION 'Unsupported completed transaction role'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    intent.id,
    intent.listing_id,
    v_role,
    post_row.title,
    listing.price,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = intent.listing_id
      ORDER BY image.order_index, image.id
      LIMIT 1
    ),
    CASE WHEN v_role = 'buyer' THEN intent.seller_id ELSE intent.buyer_id END,
    COALESCE(NULLIF(btrim(counterparty.full_name), ''), '已注销'),
    counterparty.avatar_url,
    COALESCE(intent.ended_at, intent.updated_at)
  FROM public.secondhand_purchase_intents intent
  JOIN public.posts post_row ON post_row.id = intent.listing_id
  JOIN public.secondhand_posts listing ON listing.id = intent.listing_id
  LEFT JOIN public.profiles counterparty ON counterparty.id = CASE
    WHEN v_role = 'buyer' THEN intent.seller_id
    ELSE intent.buyer_id
  END
  WHERE intent.status = 'completed'
    AND post_row.status = 'completed'
    AND (
      (v_role = 'buyer' AND intent.buyer_id = v_me)
      OR (v_role = 'seller' AND intent.seller_id = v_me)
    )
  ORDER BY COALESCE(intent.ended_at, intent.updated_at) DESC, intent.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
