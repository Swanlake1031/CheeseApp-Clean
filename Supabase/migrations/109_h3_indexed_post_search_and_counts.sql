-- H3 Phase G: indexed, ranked post search with stable keyset pagination and
-- honest landing-page category totals. The legacy search_posts RPC remains for
-- older clients during the compatibility window.

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- English token lookup over the shared title/description document.
CREATE INDEX IF NOT EXISTS posts_search_document_fts_idx
  ON public.posts USING GIN (
    to_tsvector(
      'simple',
      COALESCE(title, '') || ' ' || COALESCE(description, '')
    )
  );

-- Substring behavior (including Chinese text) over the same shared document.
CREATE INDEX IF NOT EXISTS posts_search_document_trgm_idx
  ON public.posts USING GIN (
    (COALESCE(title, '') || ' ' || COALESCE(description, ''))
    extensions.gin_trgm_ops
  );

-- Feature fields that are part of the existing search semantics.
CREATE INDEX IF NOT EXISTS rent_posts_location_search_trgm_idx
  ON public.rent_posts USING GIN (
    COALESCE(location, '') extensions.gin_trgm_ops
  );

CREATE INDEX IF NOT EXISTS secondhand_posts_attributes_search_trgm_idx
  ON public.secondhand_posts USING GIN (
    (
      COALESCE(category, '') || ' '
      || COALESCE(condition, '') || ' '
      || COALESCE(pickup_location, '')
    ) extensions.gin_trgm_ops
  );

CREATE INDEX IF NOT EXISTS forum_boards_name_search_trgm_idx
  ON public.forum_boards USING GIN (
    COALESCE(name, '') extensions.gin_trgm_ops
  );

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

  IF v_category NOT IN ('all', 'rent', 'market', 'forum') THEN
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
      CASE
        WHEN v_query = '' THEN NULL
        ELSE plainto_tsquery('simple', v_query)
      END AS text_query
  ),
  candidates AS (
    SELECT
      p.id,
      'rent'::TEXT AS category,
      p.title,
      (
        '$' || TRIM(TO_CHAR(r.price, 'FM999999990.00')) || '/mo - '
        || COALESCE(r.location, '')
      )::TEXT AS subtitle,
      p.created_at,
      public.calculate_hot_score(
        r.view_count, r.like_count, r.comment_count, r.save_count, p.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN r.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN r.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(p.title, '') || ' ' || COALESCE(p.description, '') AS shared_document,
      COALESCE(r.location, '') AS feature_document
    FROM public.posts p
    JOIN public.rent_posts r ON r.id = p.id
    JOIN public.profile_public_view profile ON profile.id = p.user_id
    CROSS JOIN input i
    WHERE v_category IN ('all', 'rent')
      AND p.type = 'rent'
      AND p.status = 'active'
      AND p.is_private = FALSE
      AND (r.expires_at IS NULL OR r.expires_at > NOW())
      AND (
        i.query_text = ''
        OR to_tsvector(
          'simple',
          COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')
        ) @@ i.text_query
        OR (COALESCE(p.title, '') || ' ' || COALESCE(p.description, ''))
          ILIKE '%' || i.query_text || '%'
        OR COALESCE(r.location, '') ILIKE '%' || i.query_text || '%'
      )

    UNION ALL

    SELECT
      p.id,
      'market'::TEXT AS category,
      p.title,
      (
        '$' || TRIM(TO_CHAR(s.price, 'FM999999990.00')) || ' - '
        || COALESCE(s.condition, '')
      )::TEXT AS subtitle,
      p.created_at,
      public.calculate_hot_score(
        s.view_count, s.like_count, s.comment_count, s.save_count, p.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN s.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN s.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(p.title, '') || ' ' || COALESCE(p.description, '') AS shared_document,
      (
        COALESCE(s.category, '') || ' '
        || COALESCE(s.condition, '') || ' '
        || COALESCE(s.pickup_location, '')
      ) AS feature_document
    FROM public.posts p
    JOIN public.secondhand_posts s ON s.id = p.id
    JOIN public.profile_public_view profile ON profile.id = p.user_id
    CROSS JOIN input i
    WHERE v_category IN ('all', 'market')
      AND p.type = 'secondhand'
      AND p.status = 'active'
      AND p.is_private = FALSE
      AND (s.expires_at IS NULL OR s.expires_at > NOW())
      AND (
        i.query_text = ''
        OR to_tsvector(
          'simple',
          COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')
        ) @@ i.text_query
        OR (COALESCE(p.title, '') || ' ' || COALESCE(p.description, ''))
          ILIKE '%' || i.query_text || '%'
        OR (
          COALESCE(s.category, '') || ' '
          || COALESCE(s.condition, '') || ' '
          || COALESCE(s.pickup_location, '')
        ) ILIKE '%' || i.query_text || '%'
      )

    UNION ALL

    SELECT
      p.id,
      'forum'::TEXT AS category,
      p.title,
      COALESCE(NULLIF(p.description, ''), board.name)::TEXT AS subtitle,
      p.created_at,
      public.calculate_hot_score(
        f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN f.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN f.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(p.title, '') || ' ' || COALESCE(p.description, '') AS shared_document,
      COALESCE(board.name, '') AS feature_document
    FROM public.posts p
    JOIN public.forum_posts f ON f.id = p.id
    JOIN public.forum_boards board ON board.id = f.board_id
    JOIN public.profile_public_view profile ON profile.id = p.user_id
    CROSS JOIN input i
    WHERE v_category IN ('all', 'forum')
      AND p.type = 'forum'
      AND p.status = 'active'
      AND p.is_private = FALSE
      AND (
        i.query_text = ''
        OR to_tsvector(
          'simple',
          COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')
        ) @@ i.text_query
        OR (COALESCE(p.title, '') || ' ' || COALESCE(p.description, ''))
          ILIKE '%' || i.query_text || '%'
        OR COALESCE(board.name, '') ILIKE '%' || i.query_text || '%'
      )
  ),
  ranked AS (
    SELECT
      candidate.*,
      CASE
        WHEN i.query_text = '' THEN
          (
            (2 - candidate.highlight_rank) * 1000000
            + candidate.hot_score
          )::DOUBLE PRECISION
        ELSE
          (
            CASE WHEN LOWER(candidate.title) = i.query_text THEN 100 ELSE 0 END
            + CASE WHEN LOWER(candidate.title) LIKE i.query_text || '%' THEN 20 ELSE 0 END
            + 10 * ts_rank_cd(
                to_tsvector('simple', candidate.shared_document),
                i.text_query
              )
            + 5 * GREATEST(
                similarity(LOWER(candidate.title), i.query_text),
                similarity(LOWER(candidate.shared_document), i.query_text),
                similarity(LOWER(candidate.feature_document), i.query_text)
              )
            + LEAST(candidate.hot_score, 10000) * 0.000001
          )::DOUBLE PRECISION
      END AS rank_score
    FROM candidates candidate
    CROSS JOIN input i
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
      ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC, image.id ASC
      LIMIT 1
    ) AS preview_image_url,
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
RETURNS TABLE (
  category TEXT,
  total_count BIGINT
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT 'rent'::TEXT, COUNT(*)::BIGINT
  FROM public.posts p
  JOIN public.rent_posts r ON r.id = p.id
  JOIN public.profile_public_view profile ON profile.id = p.user_id
  WHERE p.type = 'rent'
    AND p.status = 'active'
    AND p.is_private = FALSE
    AND (r.expires_at IS NULL OR r.expires_at > NOW())

  UNION ALL

  SELECT 'market'::TEXT, COUNT(*)::BIGINT
  FROM public.posts p
  JOIN public.secondhand_posts s ON s.id = p.id
  JOIN public.profile_public_view profile ON profile.id = p.user_id
  WHERE p.type = 'secondhand'
    AND p.status = 'active'
    AND p.is_private = FALSE
    AND (s.expires_at IS NULL OR s.expires_at > NOW())

  UNION ALL

  SELECT 'forum'::TEXT, COUNT(*)::BIGINT
  FROM public.posts p
  JOIN public.forum_posts f ON f.id = p.id
  JOIN public.profile_public_view profile ON profile.id = p.user_id
  WHERE p.type = 'forum'
    AND p.status = 'active'
    AND p.is_private = FALSE;
$$;

REVOKE ALL ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_search_post_counts()
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_search_post_counts()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
