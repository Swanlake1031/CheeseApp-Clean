-- 107_h3_feature_feed_keyset_pagination.sql
--
-- H3 Phase E: bounded, deterministic keyset pages for the three active
-- post feeds. Existing views remain as compatibility read contracts.

BEGIN;

CREATE INDEX IF NOT EXISTS posts_type_created_id_page_idx
  ON public.posts(type, created_at DESC, id DESC)
  WHERE status = 'active' AND is_private = FALSE;

CREATE INDEX IF NOT EXISTS forum_posts_board_pinned_hot_id_page_idx
  ON public.forum_posts(board_id, is_pinned DESC, hot_score DESC, id DESC);

CREATE INDEX IF NOT EXISTS forum_posts_pinned_hot_id_page_idx
  ON public.forum_posts(is_pinned DESC, hot_score DESC, id DESC);

CREATE OR REPLACE FUNCTION public.get_forum_posts_page(
  p_board_id UUID DEFAULT NULL,
  p_sort TEXT DEFAULT 'latest',
  p_after_is_pinned BOOLEAN DEFAULT NULL,
  p_after_hot_score DOUBLE PRECISION DEFAULT NULL,
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS SETOF public.forum_posts_view
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_sort NOT IN ('latest', 'hottest') THEN
    RAISE EXCEPTION 'Unsupported Forum page sort' USING ERRCODE = '22023';
  END IF;
  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'Forum page limit must be between 1 and 50'
      USING ERRCODE = '22023';
  END IF;
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'Forum cursor is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_after_created_at IS NOT NULL AND p_after_is_pinned IS NULL THEN
    RAISE EXCEPTION 'Forum cursor is missing pinned state'
      USING ERRCODE = '22023';
  END IF;
  IF p_sort = 'hottest'
     AND p_after_created_at IS NOT NULL
     AND p_after_hot_score IS NULL THEN
    RAISE EXCEPTION 'Forum hottest cursor is missing score'
      USING ERRCODE = '22023';
  END IF;

  IF p_sort = 'latest' THEN
    RETURN QUERY
    SELECT feed.*
    FROM public.forum_posts_view feed
    WHERE (p_board_id IS NULL OR feed.board_id = p_board_id)
      AND (
        p_after_created_at IS NULL
        OR (
          COALESCE(feed.is_pinned, FALSE),
          feed.created_at,
          feed.id
        ) < (
          p_after_is_pinned,
          p_after_created_at,
          p_after_id
        )
      )
    ORDER BY
      COALESCE(feed.is_pinned, FALSE) DESC,
      feed.created_at DESC,
      feed.id DESC
    LIMIT p_limit;
  ELSE
    RETURN QUERY
    SELECT feed.*
    FROM public.forum_posts_view feed
    WHERE (p_board_id IS NULL OR feed.board_id = p_board_id)
      AND (
        p_after_created_at IS NULL
        OR (
          COALESCE(feed.is_pinned, FALSE),
          COALESCE(feed.hot_score, 0),
          feed.created_at,
          feed.id
        ) < (
          p_after_is_pinned,
          p_after_hot_score,
          p_after_created_at,
          p_after_id
        )
      )
    ORDER BY
      COALESCE(feed.is_pinned, FALSE) DESC,
      COALESCE(feed.hot_score, 0) DESC,
      feed.created_at DESC,
      feed.id DESC
    LIMIT p_limit;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_secondhand_posts_page(
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS SETOF public.secondhand_posts_view
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'Secondhand page limit must be between 1 and 50'
      USING ERRCODE = '22023';
  END IF;
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'Secondhand cursor is incomplete' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT feed.*
  FROM public.secondhand_posts_view feed
  WHERE p_after_created_at IS NULL
     OR (feed.created_at, feed.id) < (p_after_created_at, p_after_id)
  ORDER BY feed.created_at DESC, feed.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_rent_posts_page(
  p_after_distance_km DOUBLE PRECISION DEFAULT NULL,
  p_after_distance_is_null BOOLEAN DEFAULT NULL,
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS SETOF JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'Rent page limit must be between 1 and 50'
      USING ERRCODE = '22023';
  END IF;
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'Rent cursor is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_after_created_at IS NOT NULL AND p_after_distance_is_null IS NULL THEN
    RAISE EXCEPTION 'Rent cursor is missing distance state'
      USING ERRCODE = '22023';
  END IF;
  IF p_after_distance_is_null = FALSE AND p_after_distance_km IS NULL THEN
    RAISE EXCEPTION 'Rent cursor is missing distance'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH viewer_anchor AS (
    SELECT campus.geo
    FROM public.profiles profile
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = profile.school_id
     AND campus.is_default = TRUE
    WHERE profile.id = auth.uid()
    LIMIT 1
  ),
  candidates AS (
    SELECT
      feed,
      feed.id AS page_id,
      feed.created_at AS page_created_at,
      CASE
        WHEN post.geo IS NULL OR anchor.geo IS NULL THEN NULL
        ELSE extensions.ST_Distance(post.geo, anchor.geo) / 1000.0
      END AS page_distance_km
    FROM public.rent_posts_view feed
    JOIN public.posts post ON post.id = feed.id
    LEFT JOIN viewer_anchor anchor ON TRUE
  )
  SELECT
    to_jsonb(candidate.feed)
      || jsonb_build_object(
        'page_distance_km',
        candidate.page_distance_km
      )
  FROM candidates candidate
  WHERE
    p_after_created_at IS NULL
    OR (
      p_after_distance_is_null = FALSE
      AND (
        candidate.page_distance_km > p_after_distance_km
        OR (
          candidate.page_distance_km = p_after_distance_km
          AND (candidate.page_created_at, candidate.page_id)
              < (p_after_created_at, p_after_id)
        )
        OR candidate.page_distance_km IS NULL
      )
    )
    OR (
      p_after_distance_is_null = TRUE
      AND candidate.page_distance_km IS NULL
      AND (candidate.page_created_at, candidate.page_id)
          < (p_after_created_at, p_after_id)
    )
  ORDER BY
    candidate.page_distance_km ASC NULLS LAST,
    candidate.page_created_at DESC,
    candidate.page_id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_forum_posts_page(
  UUID, TEXT, BOOLEAN, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_rent_posts_page(
  DOUBLE PRECISION, BOOLEAN, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_forum_posts_page(
  UUID, TEXT, BOOLEAN, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_rent_posts_page(
  DOUBLE PRECISION, BOOLEAN, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
