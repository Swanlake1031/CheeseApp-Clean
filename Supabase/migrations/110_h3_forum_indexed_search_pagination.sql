-- H3 Phase G follow-up: Forum's dedicated search surface needs its board filter
-- applied before pagination, so it owns a narrow ID/rank cursor contract.

CREATE OR REPLACE FUNCTION public.search_forum_post_ids_page(
  p_query TEXT,
  p_board_id UUID DEFAULT NULL,
  p_after_rank_score DOUBLE PRECISION DEFAULT NULL,
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS TABLE (
  id UUID,
  rank_score DOUBLE PRECISION,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
  v_query TEXT := LOWER(COALESCE(BTRIM(p_query), ''));
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF v_query = '' THEN
    RAISE EXCEPTION 'forum search query is required' USING ERRCODE = '22023';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 50' USING ERRCODE = '22023';
  END IF;

  IF (
    (p_after_rank_score IS NULL)::INTEGER
    + (p_after_created_at IS NULL)::INTEGER
    + (p_after_id IS NULL)::INTEGER
  ) NOT IN (0, 3) THEN
    RAISE EXCEPTION 'forum search cursor must be complete' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH input AS (
    SELECT plainto_tsquery('simple', v_query) AS text_query
  ),
  ranked AS (
    SELECT
      p.id,
      p.created_at,
      (
        CASE WHEN LOWER(p.title) = v_query THEN 100 ELSE 0 END
        + CASE WHEN LOWER(p.title) LIKE v_query || '%' THEN 20 ELSE 0 END
        + 10 * ts_rank_cd(
            to_tsvector(
              'simple',
              COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')
            ),
            input.text_query
          )
        + 5 * GREATEST(
            similarity(LOWER(p.title), v_query),
            similarity(
              LOWER(COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')),
              v_query
            ),
            similarity(LOWER(board.name), v_query)
          )
        + LEAST(
            public.calculate_hot_score(
              f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at
            ),
            10000
          ) * 0.000001
      )::DOUBLE PRECISION AS rank_score
    FROM public.posts p
    JOIN public.forum_posts f ON f.id = p.id
    JOIN public.forum_boards board ON board.id = f.board_id
    JOIN public.profile_public_view profile ON profile.id = p.user_id
    CROSS JOIN input
    WHERE p.type = 'forum'
      AND p.status = 'active'
      AND p.is_private = FALSE
      AND (p_board_id IS NULL OR f.board_id = p_board_id)
      AND (
        to_tsvector(
          'simple',
          COALESCE(p.title, '') || ' ' || COALESCE(p.description, '')
        ) @@ input.text_query
        OR (COALESCE(p.title, '') || ' ' || COALESCE(p.description, ''))
          ILIKE '%' || v_query || '%'
        OR COALESCE(board.name, '') ILIKE '%' || v_query || '%'
      )
  )
  SELECT ranked.id, ranked.rank_score, ranked.created_at
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

REVOKE ALL ON FUNCTION public.search_forum_post_ids_page(
  TEXT, UUID, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_forum_post_ids_page(
  TEXT, UUID, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
