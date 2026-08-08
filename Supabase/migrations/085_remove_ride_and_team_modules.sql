-- 085_remove_ride_and_team_modules.sql
-- Remove the retired Ride/Carpooling and Team-Up product modules from the live schema.
--
-- Destructive data impact:
-- - Deletes posts.type IN ('ride', 'team') and their related detail rows.
-- - Deletes Team-Up sourced chat groups.
-- - Drops ride/team/carpool tables, views, functions, policies, indexes, and profile columns.
--
-- Production procedure:
-- 1) Take a verified database backup before applying.
-- 2) Apply this migration after app clients that no longer route to Ride/Team are deployed.
-- 3) Rollback requires restoring the backup or creating a forward migration that recreates the
--    removed schema and backfills data from an external archive.

BEGIN;

-- Remove user-facing data for retired modules before tightening the shared posts contract.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_groups'
      AND column_name = 'source_type'
  ) THEN
    DELETE FROM public.chat_groups
    WHERE source_type = 'team';
  END IF;
END $$;

UPDATE public.messages
SET metadata = (metadata - 'team_join_card') - 'ride_invite_card'
WHERE metadata ? 'team_join_card'
   OR metadata ? 'ride_invite_card';

UPDATE public.group_messages
SET metadata = (metadata - 'team_join_card') - 'ride_invite_card'
WHERE metadata ? 'team_join_card'
   OR metadata ? 'ride_invite_card';

-- Rebuild shared messaging helpers so retired invite-card metadata no longer has live logic.
CREATE OR REPLACE FUNCTION public.can_send_direct_message(
  p_conversation_id UUID,
  p_sender_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public, auth
AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
  v_other UUID;
  v_sender_sent_count INTEGER;
  v_other_replied BOOLEAN;
BEGIN
  SELECT c.user1_id, c.user2_id
    INTO v_user1, v_user2
  FROM public.conversations c
  WHERE c.id = p_conversation_id;

  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_sender_id <> v_user1 AND p_sender_id <> v_user2 THEN
    RETURN FALSE;
  END IF;

  v_other := CASE WHEN p_sender_id = v_user1 THEN v_user2 ELSE v_user1 END;

  IF public.is_user_blocked(p_sender_id, v_other) THEN
    RETURN FALSE;
  END IF;

  IF public.is_mutual_follow(p_sender_id, v_other) THEN
    RETURN TRUE;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.sender_id = v_other
      AND COALESCE(m.is_deleted, FALSE) = FALSE
  )
    INTO v_other_replied;

  IF v_other_replied THEN
    RETURN TRUE;
  END IF;

  SELECT COUNT(*)
    INTO v_sender_sent_count
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND m.sender_id = p_sender_id
    AND COALESCE(m.is_deleted, FALSE) = FALSE;

  RETURN v_sender_sent_count < 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.push_message_preview(
  p_message_type TEXT,
  p_content TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_metadata JSONB := COALESCE(p_metadata, '{}'::jsonb);
  v_content TEXT;
BEGIN
  v_content := LEFT(
    REGEXP_REPLACE(
      COALESCE(NULLIF(BTRIM(COALESCE(p_content, '')), ''), '给你发来了一条消息'),
      '\s+',
      ' ',
      'g'
    ),
    120
  );

  IF LOWER(COALESCE(p_message_type, '')) = 'image' THEN
    RETURN '发来了一张图片';
  END IF;

  IF v_metadata ? 'post_contact_card' THEN
    RETURN '发来了一张帖子联系卡';
  END IF;

  IF v_metadata ? 'shared_post_card' THEN
    RETURN '分享了一篇帖子';
  END IF;

  RETURN v_content;
END;
$$;

GRANT EXECUTE ON FUNCTION public.push_message_preview(TEXT, TEXT, JSONB)
  TO authenticated, service_role;

DELETE FROM public.posts
WHERE type IN ('ride', 'team');

-- Drop feature RPCs and helpers before dropping tables/views they reference.
DROP FUNCTION IF EXISTS public.create_ride_post(UUID, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TEXT, INTEGER, NUMERIC, BOOLEAN, BOOLEAN, TEXT, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS public.update_available_seats() CASCADE;
DROP FUNCTION IF EXISTS public.get_hot_ride_posts(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.next_ride_recurrence_departure(TIMESTAMPTZ, TIMESTAMPTZ, SMALLINT[]) CASCADE;
DROP FUNCTION IF EXISTS public.advance_recurring_ride_posts(TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS public.sync_ride_anchor_distance_and_estimate_state() CASCADE;
DROP FUNCTION IF EXISTS public.sync_ride_post_geo_mirror() CASCADE;
DROP FUNCTION IF EXISTS public.set_ride_drive_estimate(UUID, NUMERIC, NUMERIC) CASCADE;

DROP FUNCTION IF EXISTS public.create_team_post(UUID, TEXT, TEXT, TEXT, INTEGER, TEXT[], TEXT, TEXT, DATE, BOOLEAN, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS public.update_team_members_count() CASCADE;
DROP FUNCTION IF EXISTS public.get_hot_team_posts(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.cleanup_expired_team_activity_data() CASCADE;
DROP FUNCTION IF EXISTS public.create_or_sync_team_chat_group(UUID) CASCADE;

DROP FUNCTION IF EXISTS public.search_carpool_trip_instances(TEXT, TEXT, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_user_owns_route_template(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_user_drives_trip(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_user_booked_trip(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_round_to_half_cad(NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_build_price_map(TEXT[], NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS public.refresh_carpool_profile_stats(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_reviews_refresh_stats() CASCADE;
DROP FUNCTION IF EXISTS public.carpool_bookings_adjust_seats() CASCADE;
DROP FUNCTION IF EXISTS public.carpool_lookup_booking_price(UUID, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.carpool_bookings_apply_server_price() CASCADE;

DROP VIEW IF EXISTS public.ride_estimate_recalc_queue CASCADE;
DROP VIEW IF EXISTS public.ride_posts_view CASCADE;
DROP VIEW IF EXISTS public.team_posts_manage_view CASCADE;
DROP VIEW IF EXISTS public.team_posts_view CASCADE;
DROP VIEW IF EXISTS public.carpool_regions_view CASCADE;

DROP INDEX IF EXISTS public.chat_groups_source_type_post_idx;
DROP INDEX IF EXISTS public.chat_groups_source_sort_idx;
ALTER TABLE public.chat_groups
  DROP CONSTRAINT IF EXISTS chat_groups_source_type_check,
  DROP COLUMN IF EXISTS source_sort_at,
  DROP COLUMN IF EXISTS source_post_id,
  DROP COLUMN IF EXISTS source_type;

DROP TABLE IF EXISTS public.carpool_route_reports CASCADE;
DROP TABLE IF EXISTS public.carpool_route_favorites CASCADE;
DROP TABLE IF EXISTS public.carpool_reviews CASCADE;
DROP TABLE IF EXISTS public.carpool_bookings CASCADE;
DROP TABLE IF EXISTS public.carpool_trip_instances CASCADE;
DROP TABLE IF EXISTS public.carpool_route_template_hubs CASCADE;
DROP TABLE IF EXISTS public.carpool_route_templates CASCADE;
DROP TABLE IF EXISTS public.carpool_corridor_hubs CASCADE;
DROP TABLE IF EXISTS public.carpool_corridors CASCADE;
DROP TABLE IF EXISTS public.carpool_custom_hubs CASCADE;
DROP TABLE IF EXISTS public.carpool_hubs CASCADE;

DROP TABLE IF EXISTS public.ride_participants CASCADE;
DROP TABLE IF EXISTS public.team_members CASCADE;
DROP TABLE IF EXISTS public.ride_posts CASCADE;
DROP TABLE IF EXISTS public.team_posts CASCADE;

ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS carpool_role,
  DROP COLUMN IF EXISTS carpool_rating_avg,
  DROP COLUMN IF EXISTS carpool_trip_count,
  DROP COLUMN IF EXISTS school_email,
  DROP COLUMN IF EXISTS school_email_verified;

DROP TYPE IF EXISTS public.carpool_booking_status CASCADE;
DROP TYPE IF EXISTS public.carpool_trip_status CASCADE;
DROP TYPE IF EXISTS public.carpool_template_recurrence CASCADE;
DROP TYPE IF EXISTS public.carpool_custom_hub_status CASCADE;
DROP TYPE IF EXISTS public.carpool_hub_priority CASCADE;
DROP TYPE IF EXISTS public.carpool_hub_type CASCADE;
DROP TYPE IF EXISTS public.carpool_user_role CASCADE;

-- Tighten posts.type to the remaining product modules.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.posts'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%type%'
      AND (
        pg_get_constraintdef(oid) ILIKE '%ride%'
        OR pg_get_constraintdef(oid) ILIKE '%team%'
      )
  LOOP
    EXECUTE format('ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.posts
  DROP CONSTRAINT IF EXISTS posts_type_allowed_check;

ALTER TABLE public.posts
  ADD CONSTRAINT posts_type_allowed_check
  CHECK (type IN ('rent', 'secondhand', 'forum')) NOT VALID;

ALTER TABLE public.posts
  VALIDATE CONSTRAINT posts_type_allowed_check;

-- Shared feed/search RPCs now only know about Rent, Second-hand, and Forum.
CREATE OR REPLACE VIEW public.geo_feed_posts_v1 AS
SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  r.highlight_type,
  r.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.rent_posts r ON r.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'rent'

UNION ALL

SELECT
  p.id AS post_id,
  p.user_id AS author_id,
  p.type AS module,
  p.school_id,
  p.geo,
  p.title,
  p.description,
  p.status,
  p.created_at,
  sh.highlight_type,
  sh.pinned_until,
  COALESCE(NULLIF(pr.full_name, ''), split_part(pr.email, '@', 1), '用户') AS author_name,
  s.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.secondhand_posts sh ON sh.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'secondhand';

ALTER VIEW IF EXISTS public.geo_feed_posts_v1 SET (security_invoker = true);

CREATE OR REPLACE FUNCTION public.search_posts(
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
SET search_path = public
AS $$
  WITH input AS (
    SELECT
      LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text,
      LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all')) AS category_key,
      GREATEST(1, LEAST(COALESCE(p_limit, 80), 200)) AS result_limit
  ),
  rent_results AS (
    SELECT
      r.id,
      'rent'::TEXT AS category,
      r.title,
      ('$' || TRIM(TO_CHAR(r.price, 'FM999999990.00')) || '/mo - ' || COALESCE(r.location, ''))::TEXT AS subtitle,
      (
        SELECT pi.url
        FROM public.post_images pi
        WHERE pi.post_id = r.id
        ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      r.created_at,
      COALESCE(r.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(r.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(r.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.rent_posts_view r
    CROSS JOIN input i
    WHERE i.category_key IN ('all', 'rent')
      AND (
        i.query_text = ''
        OR (COALESCE(r.title, '') || ' ' || COALESCE(r.location, '')) ILIKE '%' || i.query_text || '%'
      )
  ),
  secondhand_results AS (
    SELECT
      s.id,
      'market'::TEXT AS category,
      s.title,
      ('$' || TRIM(TO_CHAR(s.price, 'FM999999990.00')) || ' - ' || COALESCE(s.condition, ''))::TEXT AS subtitle,
      (
        SELECT pi.url
        FROM public.post_images pi
        WHERE pi.post_id = s.id
        ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      s.created_at,
      COALESCE(s.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(s.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(s.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.secondhand_posts_view s
    CROSS JOIN input i
    WHERE i.category_key IN ('all', 'market')
      AND (
        i.query_text = ''
        OR (COALESCE(s.title, '') || ' ' || COALESCE(s.category, '') || ' ' || COALESCE(s.condition, '')) ILIKE '%' || i.query_text || '%'
      )
  ),
  forum_results AS (
    SELECT
      f.id,
      'forum'::TEXT AS category,
      f.title,
      COALESCE(NULLIF(f.description, ''), COALESCE(f.comment_count, 0)::TEXT || ' comments')::TEXT AS subtitle,
      (
        SELECT pi.url
        FROM public.post_images pi
        WHERE pi.post_id = f.id
        ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      f.created_at,
      COALESCE(f.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(f.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(f.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.forum_posts_view f
    CROSS JOIN input i
    WHERE i.category_key IN ('all', 'forum')
      AND (
        i.query_text = ''
        OR (COALESCE(f.title, '') || ' ' || COALESCE(f.description, '') || ' ' || COALESCE(f.category, '')) ILIKE '%' || i.query_text || '%'
      )
  ),
  combined AS (
    SELECT * FROM rent_results
    UNION ALL SELECT * FROM secondhand_results
    UNION ALL SELECT * FROM forum_results
  )
  SELECT
    combined.id,
    combined.category,
    combined.title,
    combined.subtitle,
    combined.preview_image_url,
    combined.created_at,
    combined.hot_score,
    combined.highlight_type,
    combined.highlight_rank
  FROM combined
  CROSS JOIN input i
  ORDER BY
    combined.highlight_rank ASC,
    combined.hot_score DESC,
    combined.created_at DESC NULLS LAST
  LIMIT (SELECT result_limit FROM input);
$$;

GRANT EXECUTE ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_geo_feed(
  p_viewer_user_id UUID,
  p_module TEXT,
  p_page_size INTEGER DEFAULT 20,
  p_cursor JSONB DEFAULT NULL,
  p_anchor_lat DOUBLE PRECISION DEFAULT NULL,
  p_anchor_lng DOUBLE PRECISION DEFAULT NULL,
  p_nearby_radius_km DOUBLE PRECISION DEFAULT NULL,
  p_pinned_local_radius_km DOUBLE PRECISION DEFAULT 25,
  p_pinned_slots INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = on
AS $$
DECLARE
  v_module TEXT := lower(COALESCE(p_module, ''));
  v_page_size INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 20), 50));
  v_viewer_school_id UUID;
  v_viewer_campus_id UUID;
  v_profile_geo extensions.geography;
  v_sort_anchor extensions.geography;
  v_school_anchor extensions.geography;
  v_nearby_radius_km DOUBLE PRECISION;
  v_nearby_radius_m DOUBLE PRECISION;
  v_cursor_layer INTEGER;
  v_cursor_distance_key BIGINT;
  v_cursor_created_at TIMESTAMPTZ;
  v_cursor_id UUID;
  v_recent_pool_limit INTEGER := 2800;
  v_same_school_pool_limit INTEGER := 1600;
  v_pinned_pool_limit INTEGER := 400;
  v_pinned_local JSONB := '[]'::jsonb;
  v_pinned_more JSONB := '[]'::jsonb;
  v_organic JSONB := '[]'::jsonb;
  v_next_cursor JSONB;
BEGIN
  IF v_module NOT IN ('rent', 'secondhand') THEN
    RAISE EXCEPTION 'Unsupported module: %', p_module;
  END IF;

  SELECT p.school_id, p.campus_id, p.last_known_geo
  INTO v_viewer_school_id, v_viewer_campus_id, v_profile_geo
  FROM public.profiles p
  WHERE p.id = p_viewer_user_id;

  IF v_viewer_school_id IS NULL THEN
    RAISE EXCEPTION 'viewer profile has no school_id';
  END IF;

  IF p_anchor_lat IS NOT NULL AND p_anchor_lng IS NOT NULL THEN
    v_sort_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(p_anchor_lng, p_anchor_lat),
      4326
    )::extensions.geography;
  ELSIF v_profile_geo IS NOT NULL THEN
    v_sort_anchor := v_profile_geo;
  END IF;

  IF v_viewer_campus_id IS NOT NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    WHERE c.id = v_viewer_campus_id
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    WHERE c.school_id = v_viewer_school_id
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    SELECT c.geo INTO v_school_anchor
    FROM public.school_campuses c
    JOIN public.schools s ON s.id = c.school_id
    WHERE s.name = 'McMaster University'
      AND c.is_default = TRUE
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    v_school_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(-79.9192, 43.2609),
      4326
    )::extensions.geography;
  END IF;

  SELECT COALESCE(p_nearby_radius_km, s.default_radius_km, 25)
  INTO v_nearby_radius_km
  FROM public.schools s
  WHERE s.id = v_viewer_school_id;

  v_nearby_radius_m := COALESCE(v_nearby_radius_km, 25) * 1000.0;

  v_cursor_layer := COALESCE((p_cursor ->> 'layer')::INTEGER, NULL);
  v_cursor_distance_key := COALESCE(
    (p_cursor ->> 'distance_sort_key')::BIGINT,
    ROUND((p_cursor ->> 'distance_sort')::DOUBLE PRECISION)::BIGINT,
    NULL
  );
  v_cursor_created_at := COALESCE((p_cursor ->> 'created_at')::TIMESTAMPTZ, NULL);
  v_cursor_id := COALESCE((p_cursor ->> 'id')::UUID, NULL);

  WITH recent_candidates AS (
    SELECT p.id AS post_id
    FROM public.posts p
    WHERE p.type = v_module
      AND p.status = 'active'
    ORDER BY p.created_at DESC
    LIMIT v_recent_pool_limit
  ),
  same_school_candidates AS (
    SELECT p.id AS post_id
    FROM public.posts p
    WHERE p.type = v_module
      AND p.status = 'active'
      AND p.school_id = v_viewer_school_id
    ORDER BY p.created_at DESC
    LIMIT v_same_school_pool_limit
  ),
  pinned_seed AS (
    SELECT g.post_id
    FROM public.geo_feed_posts_v1 g
    WHERE g.module = v_module
      AND g.status = 'active'
      AND g.highlight_type = 'pinned'::public.post_highlight_type
      AND g.pinned_until IS NOT NULL
      AND g.pinned_until > NOW()
    ORDER BY g.pinned_until DESC, g.created_at DESC
    LIMIT v_pinned_pool_limit
  ),
  candidate_ids AS (
    SELECT post_id FROM recent_candidates
    UNION
    SELECT post_id FROM same_school_candidates
    UNION
    SELECT post_id FROM pinned_seed
  ),
  base AS (
    SELECT
      g.post_id,
      g.author_id,
      g.module,
      g.school_id,
      g.geo,
      g.title,
      g.description,
      g.status,
      g.created_at,
      g.highlight_type,
      g.pinned_until,
      g.author_name,
      g.school_name,
      g.image_url,
      COALESCE(g.geo, campus.geo) AS effective_geo,
      campus.geo AS school_anchor,
      r.distance_to_school_km AS rent_cached_distance_to_school_km,
      COALESCE(r.view_count, sh.view_count, 0)::double precision AS view_count
    FROM public.geo_feed_posts_v1 g
    JOIN candidate_ids cid
      ON cid.post_id = g.post_id
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = g.school_id
     AND campus.is_default = TRUE
    LEFT JOIN public.rent_posts r
      ON g.module = 'rent'
     AND r.id = g.post_id
    LEFT JOIN public.secondhand_posts sh
      ON g.module = 'secondhand'
     AND sh.id = g.post_id
    WHERE g.module = v_module
      AND g.status = 'active'
  ),
  school_scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN FALSE
        ELSE extensions.ST_DWithin(b.school_anchor, v_school_anchor, v_nearby_radius_m)
      END AS is_nearby_school,
      CASE
        WHEN b.school_anchor IS NULL OR v_school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.school_anchor, v_school_anchor)
      END AS school_anchor_distance_m
    FROM base b
  ),
  scored AS (
    SELECT
      b.*,
      CASE
        WHEN b.module = 'rent'
          AND b.school_id = v_viewer_school_id
          AND b.highlight_type = 'pinned'::public.post_highlight_type
          AND b.pinned_until IS NOT NULL
          AND b.pinned_until > NOW() THEN 1
        WHEN b.module = 'rent'
          AND b.school_id = v_viewer_school_id THEN 2
        WHEN b.module = 'rent'
          AND b.school_id <> v_viewer_school_id
          AND b.highlight_type = 'pinned'::public.post_highlight_type
          AND b.pinned_until IS NOT NULL
          AND b.pinned_until > NOW() THEN 3
        WHEN b.module = 'rent' THEN 4
        WHEN b.school_id = v_viewer_school_id THEN 1
        WHEN b.is_nearby_school THEN 2
        ELSE 3
      END AS layer,
      CASE
        WHEN b.effective_geo IS NULL THEN 999999999.0
        WHEN b.module = 'rent' OR b.school_id = v_viewer_school_id OR b.is_nearby_school THEN
          CASE
            WHEN v_sort_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_sort_anchor)
            WHEN v_school_anchor IS NOT NULL THEN extensions.ST_Distance(b.effective_geo, v_school_anchor)
            ELSE 999999999.0
          END
        ELSE 999999999.0
      END AS distance_sort_m,
      CASE
        WHEN b.module = 'rent' AND b.rent_cached_distance_to_school_km IS NOT NULL
          THEN (b.rent_cached_distance_to_school_km::double precision * 1000.0)
        WHEN b.effective_geo IS NULL OR b.school_anchor IS NULL THEN 999999999.0
        ELSE extensions.ST_Distance(b.effective_geo, b.school_anchor)
      END AS distance_to_school_m
    FROM school_scored b
  ),
  pinned_candidates AS (
    SELECT *
    FROM scored
    WHERE v_module <> 'rent'
      AND highlight_type = 'pinned'::public.post_highlight_type
      AND pinned_until IS NOT NULL
      AND pinned_until > NOW()
  ),
  pinned_local_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE distance_sort_m <= (COALESCE(p_pinned_local_radius_km, 25) * 1000)
    ORDER BY distance_sort_m ASC, view_count DESC, pinned_until DESC, created_at DESC, post_id DESC
    LIMIT GREATEST(1, COALESCE(p_pinned_slots, 3))
  ),
  pinned_more_rows AS (
    SELECT *
    FROM pinned_candidates
    WHERE post_id NOT IN (SELECT post_id FROM pinned_local_rows)
    ORDER BY view_count DESC, created_at DESC, post_id DESC
    LIMIT 50
  ),
  organic_pool AS (
    SELECT
      s.*,
      x.distance_sort_raw,
      ROUND(x.distance_sort_raw)::BIGINT AS distance_sort_key
    FROM scored s
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN s.layer IN (1, 2) AND s.distance_sort_m <= v_nearby_radius_m
          THEN ((1000000000.0 - LEAST(COALESCE(s.view_count, 0), 999999999.0)) * 1000000.0) + LEAST(s.distance_sort_m, 999999.0)
        WHEN s.module = 'rent' THEN s.distance_to_school_m
        WHEN s.layer IN (1, 2) THEN s.distance_sort_m
        ELSE s.school_anchor_distance_m
      END AS distance_sort_raw
    ) x
    WHERE NOT (
      v_module <> 'rent'
      AND s.highlight_type = 'pinned'::public.post_highlight_type
      AND s.pinned_until IS NOT NULL
      AND s.pinned_until > NOW()
    )
  ),
  organic_ranked AS (
    SELECT *
    FROM organic_pool o
    WHERE v_cursor_layer IS NULL
      OR (
        o.layer > v_cursor_layer
        OR (o.layer = v_cursor_layer AND o.distance_sort_key > v_cursor_distance_key)
        OR (o.layer = v_cursor_layer AND o.distance_sort_key = v_cursor_distance_key AND o.created_at < v_cursor_created_at)
        OR (o.layer = v_cursor_layer AND o.distance_sort_key = v_cursor_distance_key AND o.created_at = v_cursor_created_at AND o.post_id < v_cursor_id)
      )
    ORDER BY o.layer ASC, o.distance_sort_key ASC, o.created_at DESC, o.post_id DESC
    LIMIT v_page_size
  ),
  organic_last AS (
    SELECT *
    FROM organic_ranked
    ORDER BY layer DESC, distance_sort_key DESC, created_at ASC, post_id ASC
    LIMIT 1
  )
  SELECT
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', p.post_id,
            'author_id', p.author_id,
            'module', p.module,
            'school_id', p.school_id,
            'school_name', p.school_name,
            'title', p.title,
            'description', p.description,
            'author_name', p.author_name,
            'created_at', p.created_at,
            'image_url', p.image_url,
            'distance_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'lat', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(p.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(p.effective_geo::extensions.geometry) END,
            'highlight_type', p.highlight_type,
            'pinned_until', p.pinned_until,
            'is_paid', (
              p.highlight_type = 'pinned'::public.post_highlight_type
              AND p.pinned_until IS NOT NULL
              AND p.pinned_until > NOW()
            ),
            'view_count', p.view_count
          )
          ORDER BY p.distance_sort_m ASC, p.view_count DESC, p.created_at DESC
        )
        FROM pinned_local_rows p
      ),
      '[]'::jsonb
    ),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', p.post_id,
            'author_id', p.author_id,
            'module', p.module,
            'school_id', p.school_id,
            'school_name', p.school_name,
            'title', p.title,
            'description', p.description,
            'author_name', p.author_name,
            'created_at', p.created_at,
            'image_url', p.image_url,
            'distance_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((p.distance_to_school_m / 1000.0)::numeric, 2),
            'lat', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(p.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN p.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(p.effective_geo::extensions.geometry) END,
            'highlight_type', p.highlight_type,
            'pinned_until', p.pinned_until,
            'is_paid', (
              p.highlight_type = 'pinned'::public.post_highlight_type
              AND p.pinned_until IS NOT NULL
              AND p.pinned_until > NOW()
            ),
            'view_count', p.view_count
          )
          ORDER BY p.view_count DESC, p.created_at DESC
        )
        FROM pinned_more_rows p
      ),
      '[]'::jsonb
    ),
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', o.post_id,
            'author_id', o.author_id,
            'module', o.module,
            'school_id', o.school_id,
            'school_name', o.school_name,
            'title', o.title,
            'description', o.description,
            'author_name', o.author_name,
            'created_at', o.created_at,
            'image_url', o.image_url,
            'distance_km', ROUND((o.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_to_school_km', ROUND((o.distance_to_school_m / 1000.0)::numeric, 2),
            'distance_sort', o.distance_sort_key,
            'distance_sort_raw', o.distance_sort_raw,
            'layer', o.layer,
            'lat', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_Y(o.effective_geo::extensions.geometry) END,
            'lng', CASE WHEN o.effective_geo IS NULL THEN NULL ELSE extensions.ST_X(o.effective_geo::extensions.geometry) END,
            'highlight_type', o.highlight_type,
            'pinned_until', o.pinned_until,
            'is_paid', (
              o.highlight_type = 'pinned'::public.post_highlight_type
              AND o.pinned_until IS NOT NULL
              AND o.pinned_until > NOW()
            ),
            'view_count', o.view_count
          )
          ORDER BY o.layer ASC, o.distance_sort_key ASC, o.created_at DESC, o.post_id DESC
        )
        FROM organic_ranked o
      ),
      '[]'::jsonb
    ),
    (
      SELECT CASE
        WHEN EXISTS (SELECT 1 FROM organic_ranked) THEN
          jsonb_build_object(
            'layer', ol.layer,
            'distance_sort', ol.distance_sort_key,
            'distance_sort_key', ol.distance_sort_key,
            'created_at', ol.created_at,
            'id', ol.post_id
          )
        ELSE NULL
      END
      FROM organic_last ol
    )
  INTO v_pinned_local, v_pinned_more, v_organic, v_next_cursor;

  RETURN jsonb_build_object(
    'module', v_module,
    'viewer_school_id', v_viewer_school_id,
    'nearby_radius_km', v_nearby_radius_km,
    'pinned_local', COALESCE(v_pinned_local, '[]'::jsonb),
    'pinned_more', COALESCE(v_pinned_more, '[]'::jsonb),
    'organic', COALESCE(v_organic, '[]'::jsonb),
    'next_cursor', v_next_cursor
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_geo_feed(UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER)
  TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.get_user_chat_groups(UUID);

CREATE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER,
  unread_count INTEGER
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    g.id,
    g.name,
    g.avatar_url,
    COALESCE(last_msg.created_at, g.updated_at) AS last_message_at,
    last_msg.preview AS last_message_preview,
    COALESCE(member_stats.member_count, 1) AS member_count,
    COALESCE(unread_stats.unread_count, 0) AS unread_count
  FROM public.chat_groups g
  JOIN public.chat_group_members me
    ON me.group_id = g.id
   AND me.user_id = p_user_id
  LEFT JOIN LATERAL (
    SELECT
      gm.created_at,
      CASE
        WHEN gm.message_type = 'image' THEN 'Photo'
        ELSE LEFT(gm.content, 120)
      END AS preview
    FROM public.group_messages gm
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
    ORDER BY gm.created_at DESC
    LIMIT 1
  ) last_msg ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS member_count
    FROM public.chat_group_members gm
    WHERE gm.group_id = g.id
  ) member_stats ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INT AS unread_count
    FROM public.group_messages gm
    LEFT JOIN public.user_chat_group_settings settings
      ON settings.user_id = p_user_id
     AND settings.group_id = g.id
    WHERE gm.group_id = g.id
      AND gm.sender_id <> p_user_id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
      AND gm.created_at > COALESCE(settings.last_read_at, '-infinity'::timestamptz)
  ) unread_stats ON TRUE
  ORDER BY COALESCE(last_msg.created_at, g.updated_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_group_message_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_sender_name TEXT;
  v_group_name TEXT;
  v_body_preview TEXT;
  v_body TEXT;
  v_member RECORD;
  v_message_enabled BOOLEAN;
BEGIN
  IF NEW.sender_id IS NULL OR COALESCE(NEW.is_deleted, FALSE) = TRUE THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(g.name, ''), '群聊新消息')
  INTO v_group_name
  FROM public.chat_groups g
  WHERE g.id = NEW.group_id;

  IF v_group_name IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(p.full_name, ''), SPLIT_PART(p.email, '@', 1), '有人')
    INTO v_sender_name
  FROM public.profiles p
  WHERE p.id = NEW.sender_id;

  v_body_preview := public.push_message_preview(NEW.message_type, NEW.content, NEW.metadata);
  v_body := LEFT(
    COALESCE(NULLIF(BTRIM(COALESCE(v_sender_name, '')), ''), '有人') || ': ' || v_body_preview,
    240
  );

  FOR v_member IN
    SELECT gm.user_id
    FROM public.chat_group_members gm
    WHERE gm.group_id = NEW.group_id
      AND gm.user_id <> NEW.sender_id
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.user_chat_group_settings ugs
      WHERE ugs.user_id = v_member.user_id
        AND ugs.group_id = NEW.group_id
        AND ugs.is_muted = TRUE
    ) THEN
      CONTINUE;
    END IF;

    IF NOT public.has_active_push_tokens(v_member.user_id) THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(unp.message_enabled, TRUE)
      INTO v_message_enabled
    FROM public.user_notification_preferences unp
    WHERE unp.user_id = v_member.user_id;

    IF NOT FOUND THEN
      v_message_enabled := TRUE;
    END IF;

    IF v_message_enabled IS NOT TRUE THEN
      CONTINUE;
    END IF;

    PERFORM public.enqueue_push_notification_job(
      p_recipient_user_id := v_member.user_id,
      p_kind := 'group_message',
      p_title := v_group_name,
      p_body := v_body,
      p_payload := jsonb_strip_nulls(
        jsonb_build_object(
          'cheese_destination', 'group_conversation',
          'notification_kind', 'group_message',
          'group_id', NEW.group_id,
          'message_id', NEW.id,
          'sender_id', NEW.sender_id
        )
      ),
      p_source_type := 'group_messages',
      p_source_key := NEW.id::text || ':' || v_member.user_id::text,
      p_thread_id := NEW.group_id::text,
      p_collapse_key := NEW.group_id::text
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_group_message_push ON public.group_messages;
CREATE TRIGGER trg_enqueue_group_message_push
AFTER INSERT ON public.group_messages
FOR EACH ROW
WHEN (COALESCE(NEW.is_deleted, FALSE) = FALSE)
EXECUTE FUNCTION public.enqueue_group_message_push();

CREATE OR REPLACE FUNCTION public.normalize_expired_highlights()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total INTEGER := 0;
  v_affected INTEGER := 0;
BEGIN
  UPDATE public.rent_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.secondhand_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.forum_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  RETURN v_total;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_post_metrics(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_type TEXT;
  v_created_at TIMESTAMPTZ;
  v_view_count INTEGER;
  v_like_count INTEGER;
  v_comment_count INTEGER;
  v_save_count INTEGER;
  v_hot_score DOUBLE PRECISION;
BEGIN
  SELECT p.type, p.created_at, COALESCE(p.view_count, 0)
    INTO v_type, v_created_at, v_view_count
  FROM public.posts p
  WHERE p.id = p_post_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::INTEGER
    INTO v_like_count
  FROM public.likes l
  WHERE l.target_type = 'post'
    AND l.target_id = p_post_id;

  SELECT COUNT(*)::INTEGER
    INTO v_comment_count
  FROM public.comments c
  WHERE c.post_id = p_post_id
    AND c.is_deleted = FALSE;

  SELECT COUNT(*)::INTEGER
    INTO v_save_count
  FROM public.favorites f
  WHERE f.post_id = p_post_id;

  v_hot_score := public.calculate_hot_score(
    v_view_count,
    v_like_count,
    v_comment_count,
    v_save_count,
    v_created_at
  );

  IF v_type = 'rent' THEN
    UPDATE public.rent_posts r
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
            AND r.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE r.highlight_type
        END
    WHERE r.id = p_post_id;

  ELSIF v_type = 'secondhand' THEN
    UPDATE public.secondhand_posts s
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN s.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND s.pinned_until IS NOT NULL
            AND s.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE s.highlight_type
        END
    WHERE s.id = p_post_id;

  ELSIF v_type = 'forum' THEN
    UPDATE public.forum_posts f
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN f.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND f.pinned_until IS NOT NULL
            AND f.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE f.highlight_type
        END
    WHERE f.id = p_post_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_all_post_metrics()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  rec RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR rec IN
    SELECT id
    FROM public.posts
    WHERE type IN ('rent', 'secondhand', 'forum')
  LOOP
    PERFORM public.sync_post_metrics(rec.id);
    v_count := v_count + 1;
  END LOOP;

  PERFORM public.normalize_expired_highlights();

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_group_id UUID;
  v_now TIMESTAMPTZ := NOW();
  v_old_email TEXT;
  v_tombstone_email TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT email
  INTO v_old_email
  FROM auth.users
  WHERE id = v_user_id;

  v_tombstone_email := format(
    'deactivated+%s@deleted.cheeseapp.local',
    replace(v_user_id::text, '-', '')
  );

  FOR v_group_id IN
    SELECT gm.group_id
    FROM public.chat_group_members gm
    WHERE gm.user_id = v_user_id
  LOOP
    BEGIN
      PERFORM public.leave_chat_group(v_group_id);
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.chat_group_members
      WHERE group_id = v_group_id
        AND user_id = v_user_id;
    END;
  END LOOP;

  DELETE FROM public.user_chat_group_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_conversation_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_blocks
  WHERE blocker_id = v_user_id
     OR blocked_id = v_user_id;

  DELETE FROM public.user_reports
  WHERE reporter_id = v_user_id
     OR reported_user_id = v_user_id;

  DELETE FROM public.user_follows
  WHERE follower_id = v_user_id
     OR following_id = v_user_id;

  DELETE FROM public.comments
  WHERE user_id = v_user_id;

  DELETE FROM public.likes
  WHERE user_id = v_user_id;

  DELETE FROM public.favorites
  WHERE user_id = v_user_id;

  DELETE FROM public.view_history
  WHERE user_id = v_user_id;

  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  UPDATE public.profiles
  SET
    email = v_tombstone_email,
    full_name = '已注销',
    avatar_url = NULL,
    university = '已注销',
    bio = '此账号已注销',
    verified = FALSE,
    is_anonymous = FALSE,
    deactivated_at = v_now,
    updated_at = v_now
  WHERE id = v_user_id;

  UPDATE auth.users
  SET
    email = v_tombstone_email,
    phone = NULL,
    banned_until = v_now + INTERVAL '100 years',
    updated_at = v_now,
    raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
      || jsonb_build_object(
        'deactivated_at', v_now,
        'original_email', v_old_email
      )
  WHERE id = v_user_id;

  DELETE FROM auth.sessions
  WHERE user_id = v_user_id;

  DELETE FROM auth.identities
  WHERE user_id = v_user_id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.deactivate_my_account()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
