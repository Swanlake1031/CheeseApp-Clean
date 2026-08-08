-- 102_critical_security_boundaries.sql
--
-- Critical remediation C1-C3:
-- - close SECURITY DEFINER default grants and bind end-user RPCs to auth.uid()
-- - make profiles owner-private and expose one column-limited, block-aware view
-- - prevent anonymous Forum identity and private-post leakage through views,
--   search, geo feeds, public sharing, reactions, comments, and service-role reads
--
-- This migration is intentionally additive. It preserves rows and identifiers,
-- does not rewrite migration history, and keeps existing client RPC signatures
-- except for the intentionally narrow public Forum share result.

BEGIN;

-- New functions must be explicitly granted. Supabase's historical defaults
-- granted every new public function to all API roles.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

-- =========================================================
-- C2: one private self-profile table and one public contract
-- =========================================================

DROP POLICY IF EXISTS "Profiles public read" ON public.profiles;
DROP POLICY IF EXISTS "公开资料可以被所有人读取" ON public.profiles;
DROP POLICY IF EXISTS "Profiles owner read" ON public.profiles;

CREATE POLICY "Profiles owner read"
ON public.profiles
FOR SELECT
TO authenticated
USING (id = auth.uid());

REVOKE ALL ON TABLE public.profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;

DROP VIEW IF EXISTS public.profile_public_view;

CREATE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  p.id,
  COALESCE(NULLIF(BTRIM(p.full_name), ''), '用户') AS full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.gender,
  p.occupation,
  p.verified,
  p.school_id,
  p.campus_id,
  p.is_official,
  g.country_name,
  g.region,
  g.city
FROM public.profiles p
LEFT JOIN public.user_geo_profiles g ON g.user_id = p.id
WHERE p.deactivated_at IS NULL
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        p.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks b
          WHERE (b.blocker_id = auth.uid() AND b.blocked_id = p.id)
             OR (b.blocker_id = p.id AND b.blocked_id = auth.uid())
        )
      )
    )
  );

-- This is the intentionally narrow definer view: callers have no raw
-- profiles/user_geo_profiles SELECT, while the view itself exposes only the
-- reviewed columns and enforces the bilateral block predicate above.
ALTER VIEW public.profile_public_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.profile_public_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.profile_public_view TO authenticated, service_role;

-- Views that previously depended on unrestricted profile-table SELECT now use
-- the single public profile contract. Private posts are filtered explicitly so
-- service-role consumers cannot bypass the boundary.

CREATE OR REPLACE VIEW public.rent_posts_view AS
SELECT
  r.id,
  r.price,
  r.location,
  r.latitude,
  r.longitude,
  r.bedrooms,
  r.bathrooms,
  r.specs,
  r.property_type,
  r.is_available,
  r.available_from,
  r.lease_duration,
  r.utilities_included,
  r.pets_allowed,
  r.parking_available,
  r.laundry_type,
  r.amenities,
  tier.effective_highlight_type AS highlight_type,
  r.pinned_until,
  r.view_count,
  r.like_count,
  r.comment_count,
  r.save_count,
  public.calculate_hot_score(
    r.view_count, r.like_count, r.comment_count, r.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
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
      WHERE pi.post_id = r.id
    ),
    '[]'::JSON
  ) AS images,
  r.size,
  p.school_id,
  school.name AS school_name,
  r.distance_to_school_km,
  r.expires_at,
  (r.expires_at IS NOT NULL AND r.expires_at <= NOW()) AS is_expired
FROM public.rent_posts r
JOIN public.posts p ON p.id = r.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
JOIN public.schools school ON school.id = p.school_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN r.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND r.pinned_until IS NOT NULL
      AND r.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE r.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND p.is_private = FALSE
  AND (r.expires_at IS NULL OR r.expires_at > NOW());

ALTER VIEW public.rent_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.rent_posts_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.rent_posts_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.secondhand_posts_view AS
SELECT
  s.id,
  s.price,
  s.original_price,
  s.is_negotiable,
  s.is_free,
  s.category,
  s.condition,
  s.pickup_location,
  s.can_ship,
  s.shipping_fee,
  s.quantity,
  s.sold_count,
  tier.effective_highlight_type AS highlight_type,
  s.pinned_until,
  s.view_count,
  s.like_count,
  s.comment_count,
  s.save_count,
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
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
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
  (s.expires_at IS NOT NULL AND s.expires_at <= NOW()) AS is_expired
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
  AND p.is_private = FALSE
  AND (s.expires_at IS NULL OR s.expires_at > NOW());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

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
  pr.full_name AS author_name,
  school.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.rent_posts r ON r.id = p.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
JOIN public.schools school ON school.id = p.school_id
WHERE p.type = 'rent'
  AND p.status = 'active'
  AND p.is_private = FALSE

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
  pr.full_name AS author_name,
  school.name AS school_name,
  (
    SELECT pi.url
    FROM public.post_images pi
    WHERE pi.post_id = p.id
    ORDER BY pi.order_index ASC NULLS LAST, pi.created_at ASC
    LIMIT 1
  ) AS image_url
FROM public.posts p
JOIN public.secondhand_posts sh ON sh.id = p.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
JOIN public.schools school ON school.id = p.school_id
WHERE p.type = 'secondhand'
  AND p.status = 'active'
  AND p.is_private = FALSE;

ALTER VIEW public.geo_feed_posts_v1 SET (security_invoker = true);
REVOKE ALL ON TABLE public.geo_feed_posts_v1 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.geo_feed_posts_v1 TO service_role;

CREATE OR REPLACE VIEW public.group_messages_view AS
SELECT
  gm.id,
  gm.group_id,
  gm.sender_id,
  gm.content,
  gm.message_type,
  gm.metadata,
  gm.is_deleted,
  gm.created_at,
  COALESCE(pr.full_name, '已注销') AS sender_name,
  pr.avatar_url AS sender_avatar
FROM public.group_messages gm
LEFT JOIN public.profile_public_view pr ON pr.id = gm.sender_id;

ALTER VIEW public.group_messages_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.group_messages_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.group_messages_view TO authenticated, service_role;

-- =========================================================
-- C3: anonymous Forum identity and private content boundary
-- =========================================================

DROP FUNCTION IF EXISTS public.get_public_forum_share_post(UUID);

CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id,
  f.board_id,
  board.slug AS board_slug,
  board.name AS board_name,
  board.icon AS board_icon,
  board.allows_anonymous_posts AS board_allows_anonymous,
  f.allow_comments,
  f.is_pinned,
  f.is_locked,
  f.like_count,
  f.comment_count,
  tier.effective_highlight_type AS highlight_type,
  f.pinned_until,
  f.view_count,
  f.save_count,
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
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.created_at,
  p.updated_at,
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
  (p.user_id = auth.uid()) AS viewer_owns_post
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
  AND p.is_private = FALSE
  AND board.status <> 'archived';

-- The base posts policy intentionally hides anonymous Forum rows from ordinary
-- non-owners. This reviewed definer view is the only general read path for
-- those rows and masks identity before returning them.
ALTER VIEW public.forum_posts_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.forum_posts_view FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.forum_posts_view TO authenticated, service_role;

CREATE FUNCTION public.get_public_forum_share_post(p_post_id UUID)
RETURNS TABLE (
  id UUID,
  title TEXT,
  description TEXT,
  board_name TEXT,
  is_anonymous BOOLEAN,
  images JSON,
  created_at TIMESTAMPTZ,
  user_name TEXT,
  user_avatar TEXT,
  like_count INTEGER,
  comment_count INTEGER,
  view_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT
    p.id,
    p.title,
    p.description,
    board.name AS board_name,
    p.is_anonymous,
    COALESCE(
      (
        SELECT json_agg(
          json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
          ORDER BY pi.order_index
        )
        FROM public.post_images pi
        WHERE pi.post_id = p.id
      ),
      '[]'::JSON
    ) AS images,
    p.created_at,
    CASE WHEN p.is_anonymous THEN NULL ELSE COALESCE(NULLIF(BTRIM(pr.full_name), ''), '用户') END,
    CASE WHEN p.is_anonymous THEN NULL ELSE pr.avatar_url END,
    f.like_count,
    f.comment_count,
    f.view_count
  FROM public.posts p
  JOIN public.forum_posts f ON f.id = p.id
  JOIN public.forum_boards board ON board.id = f.board_id
  JOIN public.profiles pr ON pr.id = p.user_id
  WHERE p.id = p_post_id
    AND p.type = 'forum'
    AND p.status = 'active'
    AND p.is_private = FALSE
    AND board.status <> 'archived'
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_public_forum_share_post(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_forum_share_post(UUID)
  TO anon, authenticated, service_role;

-- A boolean visibility primitive lets RLS policies authorize reactions to an
-- anonymous Forum post without exposing its base posts.user_id row.
CREATE OR REPLACE FUNCTION public.can_view_post(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.posts post
      WHERE post.id = p_post_id
        AND post.status = 'active'
        AND (
          post.user_id = auth.uid()
          OR (
            post.is_private = FALSE
            AND (
              auth.role() = 'service_role'
              OR NOT public.is_user_blocked(auth.uid(), post.user_id)
            )
          )
        )
        AND (
          post.type <> 'forum'
          OR EXISTS (
            SELECT 1
            FROM public.forum_posts forum_detail
            JOIN public.forum_boards board ON board.id = forum_detail.board_id
            WHERE forum_detail.id = post.id
              AND board.status <> 'archived'
          )
        )
    );
$$;

-- The legacy Forum-detail policy queried posts, while the posts policy queried
-- Forum details for moderator access. Route the detail-table check through the
-- reviewed definer primitive so neither RLS policy recursively invokes the
-- other table's policy.
DROP POLICY IF EXISTS "论坛帖子公开可见" ON public.forum_posts;
CREATE POLICY "Visible Forum details are readable"
ON public.forum_posts
FOR SELECT
TO authenticated
USING (
  public.can_view_post(forum_posts.id)
  OR public.can_manage_forum_board(forum_posts.board_id, auth.uid())
);

-- Comments and reactions are direct lookup surfaces. Make visibility depend on
-- the referenced post instead of on possession of a post UUID.
DROP POLICY IF EXISTS "活跃帖子公开可见" ON public.posts;
CREATE POLICY "Active non-blocked posts are readable"
ON public.posts
FOR SELECT
TO authenticated
USING (
  status = 'active'
  AND (
    user_id = auth.uid()
    OR (
      type = 'forum'
      AND EXISTS (
        SELECT 1
        FROM public.forum_posts forum_detail
        WHERE forum_detail.id = posts.id
          AND public.can_manage_forum_board(forum_detail.board_id, auth.uid())
      )
    )
    OR (
      is_private = FALSE
      AND NOT public.is_user_blocked(auth.uid(), user_id)
      AND (type <> 'forum' OR is_anonymous = FALSE)
    )
  )
);

DROP POLICY IF EXISTS "评论公开可见" ON public.comments;
DROP POLICY IF EXISTS "登录用户可以发表评论" ON public.comments;

CREATE POLICY "Visible post comments are readable"
ON public.comments
FOR SELECT
TO authenticated
USING (
  is_deleted = FALSE
  AND public.can_view_post(comments.post_id)
);

CREATE POLICY "Users can comment on visible posts"
ON public.comments
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND public.can_view_post(comments.post_id)
);

DROP POLICY IF EXISTS "点赞记录公开可见" ON public.likes;
DROP POLICY IF EXISTS "用户可以点赞" ON public.likes;

CREATE POLICY "Visible target likes are readable"
ON public.likes
FOR SELECT
TO authenticated
USING (
  (
    target_type = 'post'
    AND public.can_view_post(likes.target_id)
  )
  OR (
    target_type = 'comment'
    AND EXISTS (
      SELECT 1
      FROM public.comments c
      WHERE c.id = likes.target_id
        AND c.is_deleted = FALSE
        AND public.can_view_post(c.post_id)
    )
  )
);

CREATE POLICY "Users can like visible targets"
ON public.likes
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND (
    (
      target_type = 'post'
      AND public.can_view_post(likes.target_id)
    )
    OR (
      target_type = 'comment'
      AND EXISTS (
        SELECT 1
        FROM public.comments c
        WHERE c.id = likes.target_id
          AND c.is_deleted = FALSE
          AND public.can_view_post(c.post_id)
      )
    )
  )
);

DROP POLICY IF EXISTS "用户可以添加收藏" ON public.favorites;
DROP POLICY IF EXISTS "用户只能查看自己的收藏" ON public.favorites;
CREATE POLICY "Users can read visible favorites"
ON public.favorites
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  AND public.can_view_post(favorites.post_id)
);

CREATE POLICY "Users can favorite visible posts"
ON public.favorites
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND public.can_view_post(favorites.post_id)
);

DROP POLICY IF EXISTS "Users can read follows" ON public.user_follows;
CREATE POLICY "Users can read non-blocked follows"
ON public.user_follows
FOR SELECT
TO authenticated
USING (
  auth.uid() IS NOT NULL
  AND NOT public.is_user_blocked(auth.uid(), follower_id)
  AND NOT public.is_user_blocked(auth.uid(), following_id)
);

REVOKE ALL ON TABLE public.comments, public.likes, public.favorites,
  public.posts, public.forum_posts, public.post_images, public.user_follows
FROM anon;

-- =========================================================
-- C1: bind caller identity and remove client-callable internals
-- =========================================================

CREATE OR REPLACE FUNCTION public.create_rent_post(
  p_user_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_price NUMERIC,
  p_location TEXT,
  p_bedrooms INTEGER DEFAULT NULL,
  p_bathrooms NUMERIC DEFAULT NULL,
  p_specs TEXT DEFAULT NULL,
  p_property_type TEXT DEFAULT 'apartment',
  p_available_from DATE DEFAULT NULL,
  p_lease_duration TEXT DEFAULT NULL,
  p_utilities_included BOOLEAN DEFAULT FALSE,
  p_pets_allowed BOOLEAN DEFAULT FALSE,
  p_is_anonymous BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_post_id UUID;
  v_school_id UUID;
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  SELECT school_id INTO v_school_id
  FROM public.profiles
  WHERE id = v_me;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  INSERT INTO public.posts (
    user_id, school_id, type, title, description, is_anonymous
  )
  VALUES (
    v_me, v_school_id, 'rent', p_title, p_description, p_is_anonymous
  )
  RETURNING id INTO v_post_id;

  INSERT INTO public.rent_posts (
    id, price, location, bedrooms, bathrooms, specs, property_type,
    available_from, lease_duration, utilities_included, pets_allowed
  )
  VALUES (
    v_post_id, p_price, p_location, p_bedrooms, p_bathrooms, p_specs,
    p_property_type, p_available_from, p_lease_duration,
    p_utilities_included, p_pets_allowed
  );

  RETURN v_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_secondhand_post(
  p_user_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_original_price NUMERIC DEFAULT NULL,
  p_is_negotiable BOOLEAN DEFAULT TRUE,
  p_is_free BOOLEAN DEFAULT FALSE,
  p_pickup_location TEXT DEFAULT NULL,
  p_can_ship BOOLEAN DEFAULT FALSE,
  p_quantity INTEGER DEFAULT 1,
  p_is_anonymous BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_post_id UUID;
  v_school_id UUID;
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  SELECT school_id INTO v_school_id
  FROM public.profiles
  WHERE id = v_me;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  INSERT INTO public.posts (
    user_id, school_id, type, title, description, is_anonymous
  )
  VALUES (
    v_me, v_school_id, 'secondhand', p_title, p_description, p_is_anonymous
  )
  RETURNING id INTO v_post_id;

  INSERT INTO public.secondhand_posts (
    id, price, original_price, is_negotiable, is_free,
    category, condition, pickup_location, can_ship, quantity
  )
  VALUES (
    v_post_id, p_price, p_original_price, p_is_negotiable, p_is_free,
    p_category, p_condition, p_pickup_location, p_can_ship, p_quantity
  );

  RETURN v_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_mutual_follow_profiles(
  p_user_id UUID,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id, p.full_name, p.avatar_url, p.university
  FROM public.user_follows f_out
  JOIN public.user_follows f_back
    ON f_out.following_id = f_back.follower_id
   AND f_out.follower_id = f_back.following_id
  JOIN public.profile_public_view p ON p.id = f_out.following_id
  WHERE auth.uid() IS NOT NULL
    AND p_user_id = auth.uid()
    AND f_out.follower_id = auth.uid()
    AND p.id <> auth.uid()
  ORDER BY p.full_name, p.id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
END;
$$;

CREATE OR REPLACE FUNCTION public.get_blocked_users(p_user_id UUID)
RETURNS TABLE (
  blocked_user_id UUID,
  blocked_user_name TEXT,
  blocked_user_avatar TEXT,
  blocked_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    block_row.blocked_id,
    COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户'),
    profile.avatar_url,
    block_row.blocked_at
  FROM public.user_blocks block_row
  JOIN public.profiles profile ON profile.id = block_row.blocked_id
  WHERE block_row.blocker_id = auth.uid()
  ORDER BY block_row.blocked_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_chat_group_members(p_group_id UUID)
RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  avatar_url TEXT,
  role TEXT,
  joined_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_group_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.chat_group_members own_membership
    WHERE own_membership.group_id = p_group_id
      AND own_membership.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Only group members can view group member list'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    membership.user_id,
    COALESCE(profile.full_name, '用户'),
    profile.avatar_url,
    membership.role,
    membership.created_at
  FROM public.chat_group_members membership
  LEFT JOIN public.profile_public_view profile ON profile.id = membership.user_id
  WHERE membership.group_id = p_group_id
  ORDER BY
    CASE WHEN membership.role = 'owner' THEN 0 ELSE 1 END,
    membership.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_or_create_conversation(
  p_user_id UUID,
  p_other_user_id UUID,
  p_related_post_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_conversation_id UUID;
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  IF p_other_user_id IS NULL OR p_other_user_id = v_me THEN
    RAISE EXCEPTION 'A different recipient is required';
  END IF;

  IF v_me < p_other_user_id THEN
    v_user1_id := v_me;
    v_user2_id := p_other_user_id;
  ELSE
    v_user1_id := p_other_user_id;
    v_user2_id := v_me;
  END IF;

  SELECT id INTO v_conversation_id
  FROM public.conversations
  WHERE user1_id = v_user1_id AND user2_id = v_user2_id
  LIMIT 1;

  IF v_conversation_id IS NOT NULL THEN
    IF p_related_post_id IS NOT NULL THEN
      UPDATE public.conversations
      SET related_post_id = COALESCE(related_post_id, p_related_post_id),
          updated_at = NOW()
      WHERE id = v_conversation_id;
    END IF;
    RETURN v_conversation_id;
  END IF;

  IF public.is_user_blocked(v_me, p_other_user_id) THEN
    RAISE EXCEPTION 'Cannot create conversation while either user is blocked';
  END IF;

  INSERT INTO public.conversations (user1_id, user2_id, related_post_id)
  VALUES (v_user1_id, v_user2_id, p_related_post_id)
  RETURNING id INTO v_conversation_id;

  RETURN v_conversation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_messages_as_read(
  p_conversation_id UUID,
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  SELECT user1_id, user2_id
  INTO v_user1_id, v_user2_id
  FROM public.conversations
  WHERE id = p_conversation_id
  FOR UPDATE;

  IF NOT FOUND OR (v_me <> v_user1_id AND v_me <> v_user2_id) THEN
    RETURN;
  END IF;

  UPDATE public.messages
  SET is_read = TRUE, read_at = NOW()
  WHERE conversation_id = p_conversation_id
    AND sender_id <> v_me
    AND is_read = FALSE;

  IF v_me = v_user1_id THEN
    UPDATE public.conversations
    SET user1_unread_count = 0, updated_at = NOW()
    WHERE id = p_conversation_id;
  ELSE
    UPDATE public.conversations
    SET user2_unread_count = 0, updated_at = NOW()
    WHERE id = p_conversation_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_post_view(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_post_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.posts p
    WHERE p.id = p_post_id
      AND p.status = 'active'
      AND (
        p.user_id = v_me
        OR (
          p.is_private = FALSE
          AND NOT public.is_user_blocked(v_me, p.user_id)
        )
      )
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.view_history (user_id, post_id, viewed_at)
  VALUES (v_me, p_post_id, NOW())
  ON CONFLICT (user_id, post_id)
  DO UPDATE SET viewed_at = EXCLUDED.viewed_at;

  UPDATE public.posts
  SET view_count = COALESCE(view_count, 0) + 1
  WHERE id = p_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_favorite_posts(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  post_id UUID,
  post_type TEXT,
  title TEXT,
  description TEXT,
  price NUMERIC,
  subtitle TEXT,
  cover_image TEXT,
  saved_at TIMESTAMPTZ,
  author_id UUID,
  author_name TEXT,
  author_avatar TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    p.id,
    p.type,
    p.title,
    p.description,
    CASE WHEN p.type = 'rent' THEN r.price
         WHEN p.type = 'secondhand' THEN s.price END,
    CASE WHEN p.type = 'rent' THEN COALESCE(r.location, '')
         WHEN p.type = 'secondhand' THEN COALESCE(s.condition, '')
         ELSE '' END,
    (
      SELECT pi.url
      FROM public.post_images pi
      WHERE pi.post_id = p.id
      ORDER BY pi.order_index ASC
      LIMIT 1
    ),
    favorite.created_at,
    p.user_id,
    COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户'),
    profile.avatar_url
  FROM public.favorites favorite
  JOIN public.posts p ON p.id = favorite.post_id
  JOIN public.profiles profile ON profile.id = p.user_id
  LEFT JOIN public.rent_posts r ON r.id = p.id
  LEFT JOIN public.secondhand_posts s ON s.id = p.id
  WHERE auth.uid() IS NOT NULL
    AND favorite.user_id = auth.uid()
    AND p.type IN ('rent', 'secondhand')
    AND p.status = 'active'
    AND p.is_private = FALSE
    AND NOT public.is_user_blocked(auth.uid(), p.user_id)
  ORDER BY favorite.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 300));
$$;

CREATE OR REPLACE FUNCTION public.get_profile_social_summary(p_target_user_id UUID)
RETURNS TABLE (
  follower_count INTEGER,
  following_count INTEGER,
  am_following BOOLEAN,
  follows_me BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_target_user_id IS NULL
     OR (
       p_target_user_id <> v_me
       AND public.is_user_blocked(v_me, p_target_user_id)
     )
  THEN
    RETURN QUERY SELECT 0, 0, FALSE, FALSE, FALSE;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.user_follows follow_row
      WHERE follow_row.following_id = p_target_user_id
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.user_follows follow_row
      WHERE follow_row.follower_id = p_target_user_id
    ), 0),
    EXISTS (
      SELECT 1
      FROM public.user_follows follow_row
      WHERE follow_row.follower_id = v_me
        AND follow_row.following_id = p_target_user_id
    ),
    EXISTS (
      SELECT 1
      FROM public.user_follows follow_row
      WHERE follow_row.follower_id = p_target_user_id
        AND follow_row.following_id = v_me
    ),
    public.is_mutual_follow(v_me, p_target_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_conversations(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  related_post_id UUID,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  unread_count INTEGER,
  can_chat_freely BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    conversation.id,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user2_id
      ELSE conversation.user1_id
    END,
    CASE
      WHEN conversation.user1_id = v_me
      THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
      ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
    END,
    CASE
      WHEN conversation.user1_id = v_me THEN profile2.avatar_url
      ELSE profile1.avatar_url
    END,
    conversation.related_post_id,
    conversation.last_message_at,
    conversation.last_message_preview,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user1_unread_count
      ELSE conversation.user2_unread_count
    END,
    public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    ),
    public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
  FROM public.conversations conversation
  LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
  LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
  WHERE (conversation.user1_id = v_me OR conversation.user2_id = v_me)
    AND NOT public.is_user_blocked(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
  ORDER BY conversation.last_message_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_message_requests(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  other_user_id UUID,
  other_user_name TEXT,
  other_user_avatar TEXT,
  related_post_id UUID,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  unread_count INTEGER,
  can_chat_freely BOOLEAN,
  is_mutual_follow BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    conversation.id,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user2_id
      ELSE conversation.user1_id
    END,
    CASE
      WHEN conversation.user1_id = v_me
      THEN COALESCE(NULLIF(profile2.full_name, ''), '已注销')
      ELSE COALESCE(NULLIF(profile1.full_name, ''), '已注销')
    END,
    CASE
      WHEN conversation.user1_id = v_me THEN profile2.avatar_url
      ELSE profile1.avatar_url
    END,
    conversation.related_post_id,
    conversation.last_message_at,
    conversation.last_message_preview,
    CASE
      WHEN conversation.user1_id = v_me THEN conversation.user1_unread_count
      ELSE conversation.user2_unread_count
    END,
    FALSE,
    FALSE
  FROM public.conversations conversation
  LEFT JOIN public.profiles profile1 ON profile1.id = conversation.user1_id
  LEFT JOIN public.profiles profile2 ON profile2.id = conversation.user2_id
  WHERE (conversation.user1_id = v_me OR conversation.user2_id = v_me)
    AND NOT public.is_user_blocked(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
    AND NOT public.is_mutual_follow(
      v_me,
      CASE
        WHEN conversation.user1_id = v_me THEN conversation.user2_id
        ELSE conversation.user1_id
      END
    )
    AND EXISTS (
      SELECT 1
      FROM public.messages incoming
      WHERE incoming.conversation_id = conversation.id
        AND incoming.sender_id = CASE
          WHEN conversation.user1_id = v_me THEN conversation.user2_id
          ELSE conversation.user1_id
        END
        AND COALESCE(incoming.is_deleted, FALSE) = FALSE
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.messages outgoing
      WHERE outgoing.conversation_id = conversation.id
        AND outgoing.sender_id = v_me
        AND COALESCE(outgoing.is_deleted, FALSE) = FALSE
    )
  ORDER BY conversation.last_message_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER,
  unread_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    chat_group.id,
    chat_group.name,
    chat_group.avatar_url,
    COALESCE(last_message.created_at, chat_group.updated_at),
    last_message.preview,
    COALESCE(member_stats.member_count, 1),
    COALESCE(unread_stats.unread_count, 0)
  FROM public.chat_groups chat_group
  JOIN public.chat_group_members own_membership
    ON own_membership.group_id = chat_group.id
   AND own_membership.user_id = auth.uid()
  LEFT JOIN LATERAL (
    SELECT
      message.created_at,
      CASE
        WHEN message.message_type = 'image' THEN 'Photo'
        ELSE LEFT(message.content, 120)
      END AS preview
    FROM public.group_messages message
    WHERE message.group_id = chat_group.id
      AND COALESCE(message.is_deleted, FALSE) = FALSE
    ORDER BY message.created_at DESC
    LIMIT 1
  ) last_message ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS member_count
    FROM public.chat_group_members member
    WHERE member.group_id = chat_group.id
  ) member_stats ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS unread_count
    FROM public.group_messages message
    LEFT JOIN public.user_chat_group_settings settings
      ON settings.user_id = auth.uid()
     AND settings.group_id = chat_group.id
    WHERE message.group_id = chat_group.id
      AND message.sender_id <> auth.uid()
      AND COALESCE(message.is_deleted, FALSE) = FALSE
      AND message.created_at > COALESCE(settings.last_read_at, '-infinity'::TIMESTAMPTZ)
  ) unread_stats ON TRUE
  ORDER BY COALESCE(last_message.created_at, chat_group.updated_at) DESC;
END;
$$;

-- Keep the large, already-tested geo query intact behind a non-callable
-- internal name; the public compatibility wrapper binds its viewer to auth.uid().
ALTER FUNCTION public.get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) RENAME TO c1_internal_get_geo_feed;

CREATE FUNCTION public.get_geo_feed(
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
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_viewer_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN public.c1_internal_get_geo_feed(
    v_me,
    p_module,
    p_page_size,
    p_cursor,
    p_anchor_lat,
    p_anchor_lng,
    p_nearby_radius_km,
    p_pinned_local_radius_km,
    p_pinned_slots
  );
END;
$$;

-- SQL/RLS helpers remain callable only where policy evaluation needs them, and
-- reject arbitrary third-party identity probes.
CREATE OR REPLACE FUNCTION public.is_blocked_by(
  p_blocker_id UUID,
  p_viewer_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND p_viewer_id = auth.uid())
  )
  AND p_blocker_id IS NOT NULL
  AND p_viewer_id IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM public.user_blocks b
    WHERE b.blocker_id = p_blocker_id
      AND b.blocked_id = p_viewer_id
  );
$$;

CREATE OR REPLACE FUNCTION public.is_user_blocked(
  p_user_a UUID,
  p_user_b UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND auth.uid() IN (p_user_a, p_user_b))
  )
  AND p_user_a IS NOT NULL
  AND p_user_b IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM public.user_blocks b
    WHERE (b.blocker_id = p_user_a AND b.blocked_id = p_user_b)
       OR (b.blocker_id = p_user_b AND b.blocked_id = p_user_a)
  );
$$;

CREATE OR REPLACE FUNCTION public.is_chat_group_member(
  p_group_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND COALESCE(p_user_id, auth.uid()) = auth.uid())
  )
  AND EXISTS (
    SELECT 1
    FROM public.chat_group_members member
    WHERE member.group_id = p_group_id
      AND member.user_id = COALESCE(p_user_id, auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.is_chat_group_owner(
  p_group_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND COALESCE(p_user_id, auth.uid()) = auth.uid())
  )
  AND EXISTS (
    SELECT 1
    FROM public.chat_groups chat_group
    WHERE chat_group.id = p_group_id
      AND chat_group.owner_id = COALESCE(p_user_id, auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.is_forum_admin(
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND COALESCE(p_user_id, auth.uid()) = auth.uid())
  )
  AND EXISTS (
    SELECT 1
    FROM public.forum_admins admin_row
    WHERE admin_row.user_id = COALESCE(p_user_id, auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manage_forum_board(
  p_board_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND COALESCE(p_user_id, auth.uid()) = auth.uid())
  )
  AND (
    public.is_forum_admin(COALESCE(p_user_id, auth.uid()))
    OR EXISTS (
      SELECT 1
      FROM public.forum_board_memberships membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id = COALESCE(p_user_id, auth.uid())
        AND membership.role IN ('moderator', 'admin')
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.can_administer_forum_board(
  p_board_id UUID,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT (
    auth.role() = 'service_role'
    OR (auth.uid() IS NOT NULL AND COALESCE(p_user_id, auth.uid()) = auth.uid())
  )
  AND (
    public.is_forum_admin(COALESCE(p_user_id, auth.uid()))
    OR EXISTS (
      SELECT 1
      FROM public.forum_board_memberships membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id = COALESCE(p_user_id, auth.uid())
        AND membership.role = 'admin'
    )
  );
$$;

-- The client-visible profile search now derives from the single public profile
-- contract. Keep nullable legacy geo columns in the result shape, but never
-- return masked IP data.
CREATE OR REPLACE FUNCTION public.search_profiles(
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT,
  bio TEXT,
  ip_masked TEXT,
  region TEXT,
  country_name TEXT,
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
    NULL::TEXT AS ip_masked,
    profile.region,
    profile.country_name,
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
REVOKE ALL ON FUNCTION public.is_mutual_follow(UUID, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_mutual_follow(UUID, UUID)
  TO authenticated, service_role;

-- Search is security-invoker, but service-role callers bypass RLS. Each branch
-- therefore independently asserts the active/non-private contract.
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
SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH input AS (
    SELECT
      LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text,
      LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all')) AS category_key,
      GREATEST(1, LEAST(COALESCE(p_limit, 80), 200)) AS result_limit
  ),
  rent_results AS (
    SELECT
      rent.id AS id,
      'rent'::TEXT AS category,
      rent.title AS title,
      ('$' || TRIM(TO_CHAR(rent.price, 'FM999999990.00')) || '/mo - '
        || COALESCE(rent.location, ''))::TEXT AS subtitle,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = rent.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      rent.created_at AS created_at,
      COALESCE(rent.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(rent.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(rent.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.rent_posts_view rent
    CROSS JOIN input
    WHERE input.category_key IN ('all', 'rent')
      AND (
        input.query_text = ''
        OR (COALESCE(rent.title, '') || ' ' || COALESCE(rent.location, ''))
          ILIKE '%' || input.query_text || '%'
      )
  ),
  secondhand_results AS (
    SELECT
      item.id AS id,
      'market'::TEXT AS category,
      item.title AS title,
      ('$' || TRIM(TO_CHAR(item.price, 'FM999999990.00')) || ' - '
        || COALESCE(item.condition, ''))::TEXT AS subtitle,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = item.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      item.created_at AS created_at,
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
      forum.id AS id,
      'forum'::TEXT AS category,
      forum.title AS title,
      COALESCE(NULLIF(forum.description, ''), forum.board_name)::TEXT AS subtitle,
      (
        SELECT image.url
        FROM public.post_images image
        WHERE image.post_id = forum.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      forum.created_at AS created_at,
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
    SELECT * FROM rent_results
    UNION ALL SELECT * FROM secondhand_results
    UNION ALL SELECT * FROM forum_results
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
  ORDER BY result.highlight_rank, result.hot_score DESC, result.created_at DESC NULLS LAST
  LIMIT (SELECT result_limit FROM input);
$$;

REVOKE ALL ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_hot_rent_posts(INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_hot_rent_posts(INTEGER)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_hot_secondhand_posts(INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_hot_secondhand_posts(INTEGER)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_hot_forum_posts(INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_hot_forum_posts(INTEGER)
  TO authenticated, service_role;

-- Retired ghost from migration 088: the defaulted INTEGER overload survived
-- the earlier no-argument DROP and now targets a removed table.
DROP FUNCTION IF EXISTS public.increment_spring_lamp(INTEGER);

-- No public contract uses this table-wide definer helper anymore.
DROP FUNCTION IF EXISTS public.public_user_geo_summary_rows();

-- These trigger entry points call the now service-only sync function. Run them
-- as their postgres owner so DML callers never need direct sync privileges.
ALTER FUNCTION public.trg_sync_post_metrics_from_comments() SECURITY DEFINER;
ALTER FUNCTION public.trg_sync_post_metrics_from_favorites() SECURITY DEFINER;
ALTER FUNCTION public.trg_sync_post_metrics_from_likes() SECURITY DEFINER;
ALTER FUNCTION public.trg_sync_post_metrics_from_posts() SECURITY DEFINER;

-- Fix unsafe/missing search paths on every remaining public definer function.
DO $definer_paths$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      namespace.nspname,
      procedure.proname,
      pg_get_function_identity_arguments(procedure.oid) AS identity_arguments
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prosecdef
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path = pg_catalog, public, auth, extensions, pg_temp',
      fn.nspname,
      fn.proname,
      fn.identity_arguments
    );
  END LOOP;
END;
$definer_paths$;

-- Start from a deny-by-default execution matrix for every active definer.
DO $definer_grants$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      namespace.nspname,
      procedure.proname,
      pg_get_function_identity_arguments(procedure.oid) AS identity_arguments
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prosecdef
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated, service_role',
      fn.nspname,
      fn.proname,
      fn.identity_arguments
    );
  END LOOP;
END;
$definer_grants$;

-- Trigger entry points and the queue insertion primitive are implementation
-- details even when they are SECURITY INVOKER. Trigger execution does not
-- require API roles to retain direct EXECUTE.
DO $trigger_grants$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      namespace.nspname,
      procedure.proname,
      pg_get_function_identity_arguments(procedure.oid) AS identity_arguments
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prorettype = 'trigger'::REGTYPE
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated, service_role',
      fn.nspname,
      fn.proname,
      fn.identity_arguments
    );
  END LOOP;
END;
$trigger_grants$;

REVOKE ALL ON FUNCTION public.enqueue_push_notification_job(
  UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;

-- End-user SECURITY DEFINER RPCs. Each derives auth.uid(), validates a supplied
-- user id, or accepts only a non-identity resource id.
GRANT EXECUTE ON FUNCTION public.complete_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_chat_group(TEXT, UUID[])
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_rent_post(
  UUID, TEXT, TEXT, NUMERIC, TEXT, INTEGER, NUMERIC, TEXT, TEXT, DATE, TEXT,
  BOOLEAN, BOOLEAN, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_secondhand_post(
  UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, BOOLEAN, BOOLEAN, TEXT,
  BOOLEAN, INTEGER, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_my_account() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_course_review(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_push_token(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_blocked_users(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_chat_group_members(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_course_catalog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_course_review_snapshot(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_post(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_mutual_follow_profiles(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_favorite_posts(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_or_create_conversation(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_profile_social_summary(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_message_requests(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_chat_group(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_post_view(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.recover_owned_group_membership(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_profile_last_known_geo(
  DOUBLE PRECISION, DOUBLE PRECISION
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_user_geo_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_user_notification_preferences(
  BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_user_push_token(TEXT, TEXT, TEXT)
  TO authenticated;

-- RLS helpers: client-callable only for authenticated evaluation, with identity
-- checks in their bodies. Service role remains available for trusted operations.
GRANT EXECUTE ON FUNCTION public.is_blocked_by(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_user_blocked(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_chat_group_member(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_chat_group_owner(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_forum_admin(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_manage_forum_board(UUID, UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_administer_forum_board(UUID, UUID)
  TO authenticated, service_role;

-- Trusted backend / maintenance only.
GRANT EXECUTE ON FUNCTION public.claim_push_notification_jobs(INTEGER, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.configure_cheese_official_msaf_post(UUID)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.normalize_expired_highlights()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_all_post_metrics()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.request_push_dispatch(TEXT, BOOLEAN)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_post_metrics(UUID)
  TO service_role;

-- The anonymous public-share RPC is the sole intentional anon definer grant.
GRANT EXECUTE ON FUNCTION public.get_public_forum_share_post(UUID)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
