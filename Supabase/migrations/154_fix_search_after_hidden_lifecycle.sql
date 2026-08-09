-- 154_fix_search_after_hidden_lifecycle.sql
--
-- Migration 152 restored the current visibility filter but accidentally copied
-- a pre-geolocation search expression that referenced the removed
-- secondhand_posts.pickup_location column. Recreate the RPC against the active
-- Marketplace schema while retaining status + is_private visibility.

BEGIN;

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
      COALESCE(market.category, '') || ' ' || COALESCE(market.condition, '')
        AS feature_document
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
          || COALESCE(market.condition, '')
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

REVOKE ALL ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
