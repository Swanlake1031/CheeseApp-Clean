-- 152_hidden_post_lifecycle.sql
--
-- Makes post hiding a recoverable, canonical visibility transition and changes
-- the Marketplace 30-day lifecycle from status=inactivate to auto-hide.
-- Existing post rows, images, reactions, favorites, and metadata are preserved.

BEGIN;

ALTER TABLE public.posts
  ADD COLUMN hidden_at TIMESTAMPTZ,
  ADD COLUMN hidden_reason TEXT;

-- Install the invariants before the data transition without scanning legacy
-- rows in this transaction. Migration 153 validates them after this migration
-- commits, avoiding PostgreSQL's pending-trigger-event ALTER TABLE guard.
ALTER TABLE public.posts
  ADD CONSTRAINT posts_hidden_reason_check
    CHECK (hidden_reason IS NULL OR hidden_reason IN ('user', 'auto_expired'))
    NOT VALID,
  ADD CONSTRAINT posts_hidden_metadata_consistent_check
    CHECK (
      (is_private = TRUE AND hidden_at IS NOT NULL AND hidden_reason IS NOT NULL)
      OR
      (is_private = FALSE AND hidden_at IS NULL AND hidden_reason IS NULL)
    )
    NOT VALID;

CREATE INDEX posts_owner_hidden_created_idx
  ON public.posts (user_id, created_at DESC, id DESC)
  WHERE is_private = TRUE AND status <> 'deleted';

CREATE OR REPLACE FUNCTION public.normalize_post_hidden_metadata()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.is_private THEN
    NEW.hidden_at := COALESCE(NEW.hidden_at, clock_timestamp());
    NEW.hidden_reason := COALESCE(NULLIF(NEW.hidden_reason, ''), 'user');
  ELSE
    NEW.hidden_at := NULL;
    NEW.hidden_reason := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_post_hidden_metadata ON public.posts;
CREATE TRIGGER trg_normalize_post_hidden_metadata
BEFORE INSERT OR UPDATE OF is_private, hidden_at, hidden_reason
ON public.posts
FOR EACH ROW EXECUTE FUNCTION public.normalize_post_hidden_metadata();

REVOKE ALL ON FUNCTION public.normalize_post_hidden_metadata()
  FROM PUBLIC, anon, authenticated, service_role;

-- Preserve existing user-hidden rows and convert the legacy Marketplace
-- inactive/expired state into the new recoverable hidden state.
UPDATE public.posts
SET hidden_at = COALESCE(updated_at, created_at, clock_timestamp()),
    hidden_reason = 'user'
WHERE is_private = TRUE;

UPDATE public.posts AS post_row
SET status = 'active',
    is_private = TRUE,
    hidden_at = COALESCE(
      market.expires_at,
      market.availability_confirmed_at + INTERVAL '30 days',
      post_row.updated_at,
      clock_timestamp()
    ),
    hidden_reason = 'auto_expired',
    updated_at = clock_timestamp()
FROM public.secondhand_posts market
WHERE market.id = post_row.id
  AND post_row.type = 'secondhand'
  AND post_row.status = 'inactive';

UPDATE public.posts AS post_row
SET is_private = TRUE,
    hidden_at = COALESCE(market.expires_at, clock_timestamp()),
    hidden_reason = 'auto_expired',
    updated_at = clock_timestamp()
FROM public.secondhand_posts market
WHERE market.id = post_row.id
  AND post_row.type = 'secondhand'
  AND post_row.status = 'active'
  AND post_row.is_private = FALSE
  AND market.expires_at <= clock_timestamp();

-- Expiry is a scheduling deadline. It no longer independently decides public
-- visibility. A restored listing receives a fresh 30-day cycle.
CREATE OR REPLACE FUNCTION public.enforce_secondhand_fixed_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  NEW.expires_at := COALESCE(
    NEW.availability_confirmed_at,
    clock_timestamp()
  ) + INTERVAL '30 days';
  RETURN NEW;
END;
$$;

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
    RAISE EXCEPTION 'Hidden state is required' USING ERRCODE = '22023';
  END IF;

  SELECT post_row.type INTO v_type
  FROM public.posts post_row
  WHERE post_row.id = p_post_id
    AND post_row.user_id = v_me
    AND post_row.type IN ('forum', 'secondhand')
    AND post_row.status <> 'deleted'
  FOR UPDATE;

  IF v_type IS NULL THEN
    RAISE EXCEPTION 'Post not found or not owned by caller'
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
    SET status = 'active',
        is_private = FALSE,
        hidden_at = NULL,
        hidden_reason = NULL,
        updated_at = v_now
    WHERE id = p_post_id;

    IF v_type = 'secondhand' THEN
      PERFORM set_config(
        'cheese.secondhand_lifecycle_write',
        'allowed',
        TRUE
      );

      UPDATE public.secondhand_posts
      SET availability_confirmed_at = v_now,
          availability_reminder_sent_at = NULL,
          availability_cycle = availability_cycle + 1,
          sold_at = NULL,
          expires_at = v_now + INTERVAL '30 days'
      WHERE id = p_post_id;

      PERFORM set_config(
        'cheese.secondhand_lifecycle_write',
        '',
        TRUE
      );
    END IF;
  END IF;

  RETURN p_hidden;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  TO authenticated;

DROP FUNCTION public.process_secondhand_availability_lifecycle(INTEGER);

CREATE FUNCTION public.process_secondhand_availability_lifecycle(
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  reminders_created INTEGER,
  listings_hidden INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := clock_timestamp();
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 50), 100));
  v_reminders INTEGER := 0;
  v_hidden INTEGER := 0;
  v_listing RECORD;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);

  FOR v_listing IN
    SELECT market.id
    FROM public.secondhand_posts market
    JOIN public.posts post_row ON post_row.id = market.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND post_row.is_private = FALSE
      AND market.expires_at <= v_now
    ORDER BY market.expires_at, market.id
    FOR UPDATE OF market, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    UPDATE public.posts
    SET is_private = TRUE,
        hidden_at = v_now,
        hidden_reason = 'auto_expired',
        updated_at = v_now
    WHERE id = v_listing.id
      AND status = 'active'
      AND is_private = FALSE;
    IF FOUND THEN v_hidden := v_hidden + 1; END IF;
  END LOOP;

  FOR v_listing IN
    SELECT market.id, post_row.user_id, post_row.title, market.availability_cycle
    FROM public.secondhand_posts market
    JOIN public.posts post_row ON post_row.id = market.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND post_row.is_private = FALSE
      AND market.availability_confirmed_at <= v_now - INTERVAL '14 days'
      AND market.expires_at > v_now
      AND market.availability_reminder_sent_at IS NULL
    ORDER BY market.availability_confirmed_at, market.id
    FOR UPDATE OF market, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_listing.user_id,
      p_event_id := format(
        'secondhand_availability:%s:%s',
        v_listing.id,
        v_listing.availability_cycle
      ),
      p_kind := 'secondhand_availability',
      p_title := '你的商品将在两周后自动隐藏',
      p_body := format(
        '「%s」发布满 30 天后会自动隐藏，并保留在私密内容中。',
        COALESCE(NULLIF(left(btrim(v_listing.title), 60), ''), '这件商品')
      ),
      p_post_id := v_listing.id,
      p_content_kind := 'secondhand',
      p_cta_kind := 'secondhand_availability'
    );

    UPDATE public.secondhand_posts
    SET availability_reminder_sent_at = v_now
    WHERE id = v_listing.id
      AND availability_cycle = v_listing.availability_cycle
      AND availability_reminder_sent_at IS NULL;
    IF FOUND THEN v_reminders := v_reminders + 1; END IF;
  END LOOP;

  PERFORM set_config('cheese.secondhand_lifecycle_write', '', TRUE);
  RETURN QUERY SELECT v_reminders, v_hidden;
END;
$$;

REVOKE ALL ON FUNCTION public.process_secondhand_availability_lifecycle(INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_secondhand_availability_lifecycle(INTEGER)
  TO service_role;

-- Owner management uses the same paginated activity contract for both public
-- and hidden content; p_visibility is the only difference.
CREATE FUNCTION public.get_my_profile_activity_page(
  p_activity_kind TEXT,
  p_post_type TEXT,
  p_visibility TEXT,
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

-- Public profile management follows the same visibility state. expires_at is
-- deliberately absent here so it cannot become a second visibility switch.
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
    post_row.id,
    post_row.user_id,
    post_row.type,
    post_row.title,
    COALESCE(post_row.description, ''),
    post_row.status,
    post_row.is_anonymous,
    post_row.is_private,
    post_row.created_at,
    market.price,
    market.original_price,
    market.category,
    market.condition,
    market.is_negotiable,
    forum.board_id,
    board.name,
    forum.allow_comments,
    profile.full_name,
    profile.avatar_url,
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
    AND profile.deactivated_at IS NULL
    AND (
      post_row.user_id = v_me
      OR public.can_view_post(post_row.id)
    )
    AND (
      post_row.user_id = v_me
      OR post_row.status = 'active'
    )
    AND post_row.status <> 'deleted'
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

-- Detail and feed access are now controlled by status + is_private. expires_at
-- is only the deadline consumed by the lifecycle task.
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
    AS user_mcmaster_verified
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

CREATE OR REPLACE FUNCTION public.search_posts_page(
  p_query TEXT,
  p_category TEXT DEFAULT 'all',
  p_after_rank_score DOUBLE PRECISION DEFAULT NULL,
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS TABLE (
  id UUID,
  category TEXT,
  title TEXT,
  subtitle TEXT,
  preview_image_url TEXT,
  created_at TIMESTAMPTZ,
  hot_score DOUBLE PRECISION,
  rank_score DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
  v_query TEXT := LOWER(COALESCE(BTRIM(p_query), ''));
  v_category TEXT := LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all'));
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_category NOT IN ('all', 'market', 'forum') THEN
    RAISE EXCEPTION 'unsupported search category' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 50' USING ERRCODE = '22023';
  END IF;
  IF (
    (p_after_rank_score IS NULL)::INTEGER
    + (p_after_created_at IS NULL)::INTEGER
    + (p_after_id IS NULL)::INTEGER
  ) NOT IN (0, 3) THEN
    RAISE EXCEPTION 'search cursor must be complete' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH input AS (
    SELECT
      v_query AS query_text,
      CASE WHEN v_query = '' THEN NULL ELSE plainto_tsquery('simple', v_query) END
        AS text_query
  ),
  candidates AS (
    SELECT
      post.id,
      'market'::TEXT AS category,
      post.title,
      (
        '$' || TRIM(TO_CHAR(market.price, 'FM999999990.00')) || ' - '
        || COALESCE(market.condition, '')
      )::TEXT AS subtitle,
      post.created_at,
      public.calculate_hot_score(
        market.view_count,
        market.like_count,
        market.comment_count,
        market.save_count,
        post.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN market.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN market.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        AS shared_document,
      (
        COALESCE(market.category, '') || ' '
        || COALESCE(market.condition, '') || ' '
        || COALESCE(market.pickup_location, '')
      ) AS feature_document
    FROM public.posts post
    JOIN public.secondhand_posts market ON market.id = post.id
    JOIN public.profile_public_view profile ON profile.id = post.user_id
    CROSS JOIN input
    WHERE v_category IN ('all', 'market')
      AND post.type = 'secondhand'
      AND post.status = 'active'
      AND post.is_private = FALSE
      AND (
        input.query_text = ''
        OR to_tsvector(
          'simple', COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        ) @@ input.text_query
        OR (COALESCE(post.title, '') || ' ' || COALESCE(post.description, ''))
          ILIKE '%' || input.query_text || '%'
        OR (
          COALESCE(market.category, '') || ' '
          || COALESCE(market.condition, '') || ' '
          || COALESCE(market.pickup_location, '')
        ) ILIKE '%' || input.query_text || '%'
      )

    UNION ALL

    SELECT
      post.id,
      'forum'::TEXT AS category,
      post.title,
      COALESCE(NULLIF(post.description, ''), board.name)::TEXT AS subtitle,
      post.created_at,
      public.calculate_hot_score(
        forum.view_count,
        forum.like_count,
        forum.comment_count,
        forum.save_count,
        post.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN forum.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN forum.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        AS shared_document,
      COALESCE(board.name, '') AS feature_document
    FROM public.posts post
    JOIN public.forum_posts forum ON forum.id = post.id
    JOIN public.forum_boards board ON board.id = forum.board_id
    JOIN public.profile_public_view profile ON profile.id = post.user_id
    CROSS JOIN input
    WHERE v_category IN ('all', 'forum')
      AND post.type = 'forum'
      AND post.status = 'active'
      AND post.is_private = FALSE
      AND (
        input.query_text = ''
        OR to_tsvector(
          'simple', COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        ) @@ input.text_query
        OR (COALESCE(post.title, '') || ' ' || COALESCE(post.description, ''))
          ILIKE '%' || input.query_text || '%'
        OR COALESCE(board.name, '') ILIKE '%' || input.query_text || '%'
      )
  ),
  ranked AS (
    SELECT
      candidate.*,
      CASE
        WHEN input.query_text = '' THEN
          ((2 - candidate.highlight_rank) * 1000000 + candidate.hot_score)
            ::DOUBLE PRECISION
        ELSE
          (
            CASE WHEN LOWER(candidate.title) = input.query_text THEN 100 ELSE 0 END
            + CASE WHEN LOWER(candidate.title) LIKE input.query_text || '%' THEN 20 ELSE 0 END
            + 10 * ts_rank_cd(
              to_tsvector('simple', candidate.shared_document), input.text_query
            )
            + 5 * GREATEST(
              similarity(LOWER(candidate.title), input.query_text),
              similarity(LOWER(candidate.shared_document), input.query_text),
              similarity(LOWER(candidate.feature_document), input.query_text)
            )
            + LEAST(candidate.hot_score, 10000) * 0.000001
          )::DOUBLE PRECISION
      END AS rank_score
    FROM candidates candidate
    CROSS JOIN input
  )
  SELECT
    ranked.id,
    ranked.category,
    ranked.title,
    ranked.subtitle,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = ranked.id
      ORDER BY image.order_index ASC NULLS LAST, image.created_at, image.id
      LIMIT 1
    ),
    ranked.created_at,
    ranked.hot_score,
    ranked.rank_score
  FROM ranked
  WHERE p_after_rank_score IS NULL
    OR ranked.rank_score < p_after_rank_score
    OR (
      ranked.rank_score = p_after_rank_score
      AND ranked.created_at < p_after_created_at
    )
    OR (
      ranked.rank_score = p_after_rank_score
      AND ranked.created_at = p_after_created_at
      AND ranked.id < p_after_id
    )
  ORDER BY ranked.rank_score DESC, ranked.created_at DESC, ranked.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_search_post_counts()
RETURNS TABLE (category TEXT, total_count BIGINT)
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT 'market'::TEXT, COUNT(*)::BIGINT
  FROM public.posts post
  JOIN public.secondhand_posts market ON market.id = post.id
  JOIN public.profile_public_view profile ON profile.id = post.user_id
  WHERE post.type = 'secondhand'
    AND post.status = 'active'
    AND post.is_private = FALSE

  UNION ALL

  SELECT 'forum'::TEXT, COUNT(*)::BIGINT
  FROM public.posts post
  JOIN public.forum_posts forum ON forum.id = post.id
  JOIN public.profile_public_view profile ON profile.id = post.user_id
  WHERE post.type = 'forum'
    AND post.status = 'active'
    AND post.is_private = FALSE;
$$;

REVOKE ALL ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_search_post_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_search_post_counts()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
