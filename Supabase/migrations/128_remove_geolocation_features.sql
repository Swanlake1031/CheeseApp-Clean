-- 128_remove_geolocation_features.sql
-- Retire device/IP geolocation, map coordinates, distance ranking, and the
-- location-derived Secondhand pickup field from the active product schema.
--
-- Destructive data impact:
--   * deletes user_geo_profiles (including raw/masked IP and inferred region);
--   * deletes stored profile/post/campus coordinates and Secondhand pickup text.
-- Rollback limits: deleted location/IP data is not reconstructed by rollback.
-- Backup requirement: take a production database backup before applying.
-- Production order: ship a compatible app that no longer calls geo RPCs first,
-- then apply this migration. This repository task does not deploy production.

BEGIN;

-- Stop active readers and writers before removing their storage.
DROP FUNCTION IF EXISTS public.get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
);
DROP FUNCTION IF EXISTS public.c1_internal_get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
);
DROP FUNCTION IF EXISTS public.update_profile_last_known_geo(
  DOUBLE PRECISION, DOUBLE PRECISION
);
DROP FUNCTION IF EXISTS public.upsert_user_geo_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);
DROP FUNCTION IF EXISTS public.public_user_geo_summary_rows();
DROP FUNCTION IF EXISTS public.sync_rent_anchor_distance_only();
DROP FUNCTION IF EXISTS public.sync_rent_post_geo_mirror();
DROP FUNCTION IF EXISTS public.sync_ride_anchor_distance_and_estimate_state();
DROP FUNCTION IF EXISTS public.sync_ride_post_geo_mirror();
DROP FUNCTION IF EXISTS public.set_ride_drive_estimate(UUID, NUMERIC, NUMERIC);
DROP VIEW IF EXISTS public.geo_feed_posts_v1;

DROP TRIGGER IF EXISTS trg_posts_geo_from_profile ON public.posts;
DROP TRIGGER IF EXISTS trg_touch_profile_location_updated_at ON public.profiles;
DROP TRIGGER IF EXISTS trg_secondhand_paid_geo ON public.secondhand_posts;
DROP TRIGGER IF EXISTS trg_forum_paid_geo ON public.forum_posts;

DROP FUNCTION IF EXISTS public.sync_post_geo_from_profile();
DROP FUNCTION IF EXISTS public.touch_profile_location_updated_at();
DROP FUNCTION IF EXISTS public.enforce_paid_post_geo();
DROP FUNCTION IF EXISTS public.compute_post_school_anchor_distance_km(
  UUID, DOUBLE PRECISION, DOUBLE PRECISION
);

-- Preserve the established public-profile view shape while severing its geo/IP
-- source. Compatibility columns are always NULL and are no longer written,
-- searched, or decoded by the current app.
CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  profile.gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::TEXT AS country_name,
  NULL::TEXT AS region,
  NULL::TEXT AS city
FROM public.profiles profile
WHERE profile.deactivated_at IS NULL
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks block_row
          WHERE (block_row.blocker_id = auth.uid() AND block_row.blocked_id = profile.id)
             OR (block_row.blocker_id = profile.id AND block_row.blocked_id = auth.uid())
        )
      )
    )
  );

ALTER VIEW public.profile_public_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.profile_public_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.profile_public_view TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.search_profiles(TEXT, INTEGER);
CREATE FUNCTION public.search_profiles(
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT,
  bio TEXT,
  is_following BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  WITH input AS (
    SELECT COALESCE(NULLIF(BTRIM(p_query), ''), '') AS query_text
  )
  SELECT
    profile.id,
    profile.full_name,
    profile.avatar_url,
    profile.university,
    profile.bio,
    EXISTS (
      SELECT 1
      FROM public.user_follows follow_row
      WHERE follow_row.follower_id = auth.uid()
        AND follow_row.following_id = profile.id
    ),
    EXISTS (
      SELECT 1
      FROM public.user_follows outgoing
      JOIN public.user_follows incoming
        ON incoming.follower_id = outgoing.following_id
       AND incoming.following_id = outgoing.follower_id
      WHERE outgoing.follower_id = auth.uid()
        AND outgoing.following_id = profile.id
    )
  FROM public.profile_public_view profile
  CROSS JOIN input
  WHERE auth.uid() IS NOT NULL
    AND (
      input.query_text = ''
      OR profile.full_name ILIKE '%' || input.query_text || '%'
      OR COALESCE(profile.university, '') ILIKE '%' || input.query_text || '%'
    )
  ORDER BY profile.full_name, profile.id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
$$;

REVOKE ALL ON FUNCTION public.search_profiles(TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_profiles(TEXT, INTEGER)
  TO authenticated, service_role;

-- Remove the IP/geolocation store only after profile_public_view no longer
-- depends on it.
DROP TABLE IF EXISTS public.user_geo_profiles;
DROP FUNCTION IF EXISTS public.touch_user_geo_profiles_updated_at();
DROP FUNCTION IF EXISTS public.mask_ip_text(TEXT);

-- Replace the Secondhand public view before dropping its location-derived
-- pickup column.
DROP FUNCTION IF EXISTS public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
);
-- This RPC returns the composite row type owned by secondhand_posts_view, so it
-- must be removed explicitly before the view can be replaced. Recreate it below
-- with the same location-free result contract and ordering semantics.
DROP FUNCTION IF EXISTS public.get_hot_secondhand_posts(INTEGER);
DROP FUNCTION IF EXISTS public.search_posts(TEXT, TEXT, INTEGER);
DROP VIEW IF EXISTS public.secondhand_posts_view;
DROP INDEX IF EXISTS public.secondhand_posts_attributes_search_trgm_idx;
ALTER TABLE public.secondhand_posts DROP COLUMN IF EXISTS pickup_location;

CREATE INDEX secondhand_posts_attributes_search_trgm_idx
  ON public.secondhand_posts USING GIN (
    (
      COALESCE(category, '') || ' '
      || COALESCE(condition, '')
    ) extensions.gin_trgm_ops
  );

CREATE VIEW public.secondhand_posts_view AS
SELECT
  listing.id,
  listing.price,
  listing.original_price,
  listing.is_negotiable,
  listing.is_free,
  listing.category,
  listing.condition,
  listing.can_ship,
  listing.shipping_fee,
  listing.quantity,
  listing.sold_count,
  tier.effective_highlight_type AS highlight_type,
  listing.pinned_until,
  listing.view_count,
  listing.like_count,
  listing.comment_count,
  listing.save_count,
  public.calculate_hot_score(
    listing.view_count, listing.like_count, listing.comment_count,
    listing.save_count, post.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  post.user_id,
  post.title,
  post.description,
  post.status,
  post.is_anonymous,
  post.created_at,
  post.updated_at,
  profile.full_name AS user_name,
  profile.avatar_url AS user_avatar,
  profile.university AS user_university,
  profile.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object(
          'id', image.id,
          'url', image.url,
          'order_index', image.order_index
        )
        ORDER BY image.order_index
      )
      FROM public.post_images image
      WHERE image.post_id = listing.id
    ),
    '[]'::JSON
  ) AS images,
  CASE
    WHEN listing.original_price IS NOT NULL AND listing.original_price > 0
    THEN ROUND((1 - listing.price / listing.original_price) * 100)
    ELSE NULL
  END AS discount_percent,
  listing.expires_at,
  (listing.expires_at IS NOT NULL AND listing.expires_at <= NOW()) AS is_expired
FROM public.secondhand_posts listing
JOIN public.posts post ON post.id = listing.id
JOIN public.profile_public_view profile ON profile.id = post.user_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN listing.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND listing.pinned_until IS NOT NULL
      AND listing.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE listing.highlight_type
  END AS effective_highlight_type
) tier
WHERE post.status = 'active'
  AND post.is_private = FALSE
  AND (listing.expires_at IS NULL OR listing.expires_at > NOW());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

CREATE FUNCTION public.get_hot_secondhand_posts(
  p_limit INTEGER DEFAULT 20
)
RETURNS SETOF public.secondhand_posts_view
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT *
  FROM public.secondhand_posts_view
  ORDER BY highlight_rank ASC, hot_score DESC, created_at DESC
  LIMIT GREATEST(p_limit, 1);
$$;

REVOKE ALL ON FUNCTION public.get_hot_secondhand_posts(INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_hot_secondhand_posts(INTEGER)
  TO authenticated, service_role;

CREATE FUNCTION public.get_secondhand_posts_page(
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

REVOKE ALL ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;

CREATE FUNCTION public.search_posts(
  p_query TEXT DEFAULT '',
  p_category TEXT DEFAULT 'all',
  p_limit INTEGER DEFAULT 80
)
RETURNS TABLE (
  id UUID,
  category TEXT,
  title TEXT,
  subtitle TEXT,
  preview_image_url TEXT,
  created_at TIMESTAMPTZ,
  hot_score DOUBLE PRECISION,
  highlight_type TEXT,
  highlight_rank INTEGER
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH input AS (
    SELECT
      LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text,
      LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all')) AS category_key,
      GREATEST(1, LEAST(COALESCE(p_limit, 80), 200)) AS result_limit
  ),
  secondhand_results AS (
    SELECT
      item.id,
      'market'::TEXT AS category,
      item.title,
      ('$' || TRIM(TO_CHAR(item.price, 'FM999999990.00')) || ' - '
        || COALESCE(item.condition, ''))::TEXT AS subtitle,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = item.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      item.created_at,
      COALESCE(item.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(item.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(item.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.secondhand_posts_view item
    CROSS JOIN input
    WHERE input.category_key IN ('all', 'market')
      AND (
        input.query_text = ''
        OR (
          COALESCE(item.title, '') || ' ' || COALESCE(item.category, '') || ' '
          || COALESCE(item.condition, '')
        ) ILIKE '%' || input.query_text || '%'
      )
  ),
  forum_results AS (
    SELECT
      forum.id,
      'forum'::TEXT AS category,
      forum.title,
      COALESCE(NULLIF(forum.description, ''), forum.board_name)::TEXT AS subtitle,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = forum.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      forum.created_at,
      COALESCE(forum.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(forum.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(forum.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.forum_posts_view forum
    CROSS JOIN input
    WHERE input.category_key IN ('all', 'forum')
      AND (
        input.query_text = ''
        OR (
          COALESCE(forum.title, '') || ' ' || COALESCE(forum.description, '')
          || ' ' || forum.board_name
        ) ILIKE '%' || input.query_text || '%'
      )
  ),
  combined AS (
    SELECT * FROM secondhand_results
    UNION ALL
    SELECT * FROM forum_results
  )
  SELECT
    result.id,
    result.category,
    result.title,
    result.subtitle,
    result.preview_image_url,
    result.created_at,
    result.hot_score,
    result.highlight_type,
    result.highlight_rank
  FROM combined result
  CROSS JOIN input
  WHERE input.category_key IN ('all', 'market', 'forum')
  ORDER BY result.highlight_rank, result.hot_score DESC,
           result.created_at DESC NULLS LAST
  LIMIT (SELECT result_limit FROM input);
$$;

REVOKE ALL ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  TO authenticated, service_role;

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
        market.view_count, market.like_count, market.comment_count,
        market.save_count, post.created_at
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
      AND (market.expires_at IS NULL OR market.expires_at > NOW())
      AND (
        input.query_text = ''
        OR to_tsvector(
          'simple', COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        ) @@ input.text_query
        OR (COALESCE(post.title, '') || ' ' || COALESCE(post.description, ''))
          ILIKE '%' || input.query_text || '%'
        OR (COALESCE(market.category, '') || ' ' || COALESCE(market.condition, ''))
          ILIKE '%' || input.query_text || '%'
      )

    UNION ALL

    SELECT
      post.id,
      'forum'::TEXT AS category,
      post.title,
      COALESCE(NULLIF(post.description, ''), board.name)::TEXT AS subtitle,
      post.created_at,
      public.calculate_hot_score(
        forum.view_count, forum.like_count, forum.comment_count,
        forum.save_count, post.created_at
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
      SELECT image.url FROM public.post_images image
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
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;

-- Remove legacy and current publish contracts that carried pickup_location.
DROP FUNCTION IF EXISTS public.create_secondhand_post(
  UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, BOOLEAN, BOOLEAN,
  TEXT, BOOLEAN, INTEGER, BOOLEAN
);
DROP FUNCTION IF EXISTS public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TEXT, TIMESTAMPTZ, UUID[]
);
DROP FUNCTION IF EXISTS public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TEXT, TIMESTAMPTZ
);

CREATE FUNCTION public.publish_secondhand_post(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_expires_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_school_id UUID;
  v_existing public.posts%ROWTYPE;
  v_listing public.secondhand_posts%ROWTYPE;
  v_expected_media_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Secondhand title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_price IS NULL OR p_price < 0 THEN
    RAISE EXCEPTION 'Secondhand price must be nonnegative' USING ERRCODE = '22023';
  END IF;
  IF p_category NOT IN (
    'furniture', 'electronics', 'academic', 'clothing',
    'appliances', 'sports', 'beauty', 'other'
  ) THEN
    RAISE EXCEPTION 'Unsupported Secondhand category' USING ERRCODE = '22023';
  END IF;
  IF p_condition NOT IN ('new', 'like_new', 'good', 'fair', 'poor') THEN
    RAISE EXCEPTION 'Unsupported Secondhand condition' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing FROM public.posts WHERE id = p_post_id;
  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_me
       OR v_existing.type IS DISTINCT FROM 'secondhand' THEN
      RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_listing FROM public.secondhand_posts WHERE id = p_post_id;
    IF NOT FOUND
       OR v_existing.title IS DISTINCT FROM BTRIM(p_title)
       OR COALESCE(v_existing.description, '') IS DISTINCT FROM BTRIM(p_description)
       OR v_existing.is_anonymous IS DISTINCT FROM p_is_anonymous
       OR v_existing.is_private IS DISTINCT FROM p_is_private
       OR v_listing.price IS DISTINCT FROM p_price
       OR v_listing.category IS DISTINCT FROM p_category
       OR v_listing.condition IS DISTINCT FROM p_condition
       OR v_listing.is_negotiable IS DISTINCT FROM p_is_negotiable
       OR v_listing.expires_at IS DISTINCT FROM p_expires_at
       OR EXISTS (
         SELECT 1 FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status <> 'finalized'
       )
       OR (
         SELECT COUNT(*) FROM public.post_images image
         WHERE image.post_id = p_post_id
       ) IS DISTINCT FROM (
         SELECT COUNT(*) FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
       )
       OR EXISTS (
         SELECT 1 FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
           AND NOT EXISTS (
             SELECT 1 FROM public.post_images image
             WHERE image.id = stage.id
               AND image.post_id = p_post_id
               AND image.bucket = stage.bucket
               AND image.object_path = stage.object_path
               AND image.url = stage.url
               AND image.order_index = stage.order_index
           )
       )
    THEN
      RAISE EXCEPTION 'Secondhand publish idempotency conflict'
        USING ERRCODE = '23505';
    END IF;
    RETURN p_post_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND (
        stage.owner_id IS DISTINCT FROM v_me
        OR stage.post_id IS DISTINCT FROM p_post_id
        OR stage.post_type IS DISTINCT FROM 'secondhand'
      )
  ) THEN
    RAISE EXCEPTION 'Secondhand media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'secondhand'
      AND stage.status <> 'uploaded'
  ) THEN
    RAISE EXCEPTION 'Secondhand media upload is incomplete'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*) INTO v_expected_media_count
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'secondhand'
    AND stage.status = 'uploaded';

  IF v_expected_media_count < 1 THEN
    RAISE EXCEPTION 'Secondhand listing requires at least one image'
      USING ERRCODE = '23514';
  END IF;

  SELECT profile.school_id INTO v_school_id
  FROM public.profiles profile WHERE profile.id = v_me;
  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  INSERT INTO public.posts (
    id, user_id, school_id, type, title, description, status,
    is_anonymous, is_private
  ) VALUES (
    p_post_id, v_me, v_school_id, 'secondhand', BTRIM(p_title),
    NULLIF(BTRIM(p_description), ''), 'active', p_is_anonymous, p_is_private
  );

  INSERT INTO public.secondhand_posts (
    id, price, is_negotiable, is_free, category, condition,
    can_ship, quantity, expires_at
  ) VALUES (
    p_post_id, p_price, p_is_negotiable, FALSE, p_category, p_condition,
    FALSE, 1, p_expires_at
  );

  INSERT INTO public.post_images (
    id, post_id, url, order_index, bucket, object_path
  )
  SELECT
    stage.id, p_post_id, stage.url, stage.order_index,
    stage.bucket, stage.object_path
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'secondhand'
    AND stage.status = 'uploaded'
  ORDER BY stage.order_index;

  IF (
    SELECT COUNT(*) FROM public.post_images image
    WHERE image.post_id = p_post_id
  ) IS DISTINCT FROM v_expected_media_count THEN
    RAISE EXCEPTION 'Secondhand image metadata finalization failed'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.post_media_staging
  SET status = 'finalized', finalized_at = NOW()
  WHERE operation_id = p_operation_id
    AND owner_id = v_me
    AND post_id = p_post_id
    AND post_type = 'secondhand'
    AND status = 'uploaded';

  UPDATE public.post_media_cleanup_backlog cleanup
  SET status = 'resolved', reason = 'published', resolved_at = NOW(),
      last_error_code = NULL
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND cleanup.source_staging_id = stage.id
    AND cleanup.owner_id = v_me;

  RETURN p_post_id;
END;
$$;

CREATE FUNCTION public.publish_secondhand_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_expires_at TIMESTAMPTZ,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
BEGIN
  v_post_id := public.publish_secondhand_post(
    p_post_id, p_operation_id, p_title, p_description,
    p_is_anonymous, p_is_private, p_price, p_category,
    p_condition, p_is_negotiable, p_expires_at
  );

  PERFORM public.sync_content_mentions(
    'secondhand', v_post_id, NULL, p_mentioned_user_ids
  );
  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ
) TO authenticated;

REVOKE ALL ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ, UUID[]
) TO authenticated;

-- Finally remove coordinate storage. School/campus identity remains intact.
ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS last_known_geo,
  DROP COLUMN IF EXISTS location_updated_at;
ALTER TABLE public.posts DROP COLUMN IF EXISTS geo;
ALTER TABLE public.school_campuses DROP COLUMN IF EXISTS geo;
ALTER TABLE public.schools DROP COLUMN IF EXISTS default_radius_km;

-- No remaining product table or RPC uses spatial types. Drop the extension
-- without CASCADE so an unexpected spatial dependency blocks rollout instead
-- of being deleted silently.
DROP EXTENSION IF EXISTS postgis;

NOTIFY pgrst, 'reload schema';

COMMIT;
