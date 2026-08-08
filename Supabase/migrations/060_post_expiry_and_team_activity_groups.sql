-- 060_post_expiry_and_team_activity_groups.sql
-- Rent/secondhand expiry + team-activity group chat linkage.

BEGIN;

-- =========================================================
-- Expiry columns for time-sensitive modules
-- =========================================================
ALTER TABLE public.rent_posts
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

ALTER TABLE public.secondhand_posts
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS rent_posts_expires_at_idx
  ON public.rent_posts(expires_at)
  WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS secondhand_posts_expires_at_idx
  ON public.secondhand_posts(expires_at)
  WHERE expires_at IS NOT NULL;

-- =========================================================
-- Team activity source metadata on chat groups
-- =========================================================
ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS source_type TEXT NOT NULL DEFAULT 'general',
  ADD COLUMN IF NOT EXISTS source_post_id UUID,
  ADD COLUMN IF NOT EXISTS source_sort_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chat_groups_source_type_check'
  ) THEN
    ALTER TABLE public.chat_groups
      ADD CONSTRAINT chat_groups_source_type_check
      CHECK (source_type IN ('general', 'team'));
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS chat_groups_source_type_post_idx
  ON public.chat_groups(source_type, source_post_id)
  WHERE source_post_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS chat_groups_source_sort_idx
  ON public.chat_groups(source_type, source_sort_at)
  WHERE source_type = 'team';

-- =========================================================
-- Auto create/sync team activity group chat and members
-- =========================================================
CREATE OR REPLACE FUNCTION public.create_or_sync_team_chat_group(p_team_id UUID)
RETURNS TABLE (
  group_id UUID,
  created BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_owner_id UUID;
  v_team_title TEXT;
  v_sort_at TIMESTAMPTZ;
  v_group_id UUID;
  v_created BOOLEAN := FALSE;
  v_is_approved_member BOOLEAN := FALSE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required';
  END IF;

  SELECT
    p.user_id,
    p.title,
    COALESCE(t.event_time, t.deadline::timestamptz, p.created_at)
  INTO
    v_owner_id,
    v_team_title,
    v_sort_at
  FROM public.team_posts t
  JOIN public.posts p ON p.id = t.id
  WHERE t.id = p_team_id
    AND p.type = 'team'
  LIMIT 1;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Team post not found';
  END IF;

  IF v_me <> v_owner_id THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.team_members tm
      WHERE tm.team_id = p_team_id
        AND tm.user_id = v_me
        AND tm.status = 'approved'
    ) INTO v_is_approved_member;

    IF NOT v_is_approved_member THEN
      RAISE EXCEPTION 'Only organizer or approved members can sync team activity group';
    END IF;
  END IF;

  SELECT g.id
  INTO v_group_id
  FROM public.chat_groups g
  WHERE g.source_type = 'team'
    AND g.source_post_id = p_team_id
  ORDER BY g.created_at ASC
  LIMIT 1;

  IF v_group_id IS NULL THEN
    INSERT INTO public.chat_groups (
      owner_id,
      name,
      source_type,
      source_post_id,
      source_sort_at
    )
    VALUES (
      v_owner_id,
      COALESCE(NULLIF(btrim(v_team_title), ''), '组队活动') || ' · 活动群',
      'team',
      p_team_id,
      v_sort_at
    )
    RETURNING id INTO v_group_id;
    v_created := TRUE;
  ELSE
    UPDATE public.chat_groups g
    SET
      source_sort_at = v_sort_at,
      source_post_id = p_team_id,
      source_type = 'team'
    WHERE g.id = v_group_id;
  END IF;

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  VALUES (v_group_id, v_owner_id, 'owner')
  ON CONFLICT (group_id, user_id) DO UPDATE
    SET role = 'owner';

  INSERT INTO public.chat_group_members (group_id, user_id, role)
  SELECT
    v_group_id,
    source_members.user_id,
    CASE WHEN source_members.user_id = v_owner_id THEN 'owner' ELSE 'member' END
  FROM (
    SELECT v_owner_id AS user_id
    UNION
    SELECT tm.user_id
    FROM public.team_members tm
    WHERE tm.team_id = p_team_id
      AND tm.status = 'approved'
  ) AS source_members
  ON CONFLICT (group_id, user_id) DO NOTHING;

  RETURN QUERY SELECT v_group_id, v_created;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_or_sync_team_chat_group(UUID)
  TO authenticated, service_role;

-- =========================================================
-- Group list RPC: include activity-group metadata + ordering
-- =========================================================
DROP FUNCTION IF EXISTS public.get_user_chat_groups(UUID);

CREATE FUNCTION public.get_user_chat_groups(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  avatar_url TEXT,
  last_message_at TIMESTAMPTZ,
  last_message_preview TEXT,
  member_count INTEGER,
  unread_count INTEGER,
  source_type TEXT,
  source_post_id UUID,
  source_sort_at TIMESTAMPTZ,
  team_title TEXT,
  team_event_time TIMESTAMPTZ,
  team_deadline DATE,
  team_location TEXT
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
    COALESCE(unread_stats.unread_count, 0) AS unread_count,
    g.source_type,
    g.source_post_id,
    COALESCE(g.source_sort_at, tp.event_time, tp.deadline::timestamptz, g.created_at) AS source_sort_at,
    post_ref.title AS team_title,
    tp.event_time AS team_event_time,
    tp.deadline AS team_deadline,
    tp.meeting_location AS team_location
  FROM public.chat_groups g
  JOIN public.chat_group_members me
    ON me.group_id = g.id
   AND me.user_id = p_user_id
  LEFT JOIN public.user_chat_group_settings ugs
    ON ugs.group_id = g.id
   AND ugs.user_id = p_user_id
  LEFT JOIN public.team_posts tp
    ON g.source_type = 'team'
   AND g.source_post_id = tp.id
  LEFT JOIN public.posts post_ref
    ON post_ref.id = tp.id
  LEFT JOIN LATERAL (
    SELECT
      gm.created_at,
      CASE
        WHEN gm.message_type = 'image' THEN '📷 Photo'
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
    WHERE gm.group_id = g.id
      AND COALESCE(gm.is_deleted, FALSE) = FALSE
      AND gm.sender_id <> p_user_id
      AND gm.created_at > COALESCE(ugs.last_read_at, me.created_at, 'epoch'::timestamptz)
  ) unread_stats ON TRUE
  ORDER BY
    CASE WHEN g.source_type = 'team' THEN 0 ELSE 1 END,
    CASE
      WHEN g.source_type = 'team'
      THEN COALESCE(g.source_sort_at, tp.event_time, tp.deadline::timestamptz, g.created_at)
      ELSE NULL
    END ASC NULLS LAST,
    COALESCE(last_msg.created_at, g.updated_at) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_chat_groups(UUID)
  TO authenticated, service_role;

-- =========================================================
-- rent_posts_view: hide expired listings automatically
-- =========================================================
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
  public.calculate_hot_score(r.view_count, r.like_count, r.comment_count, r.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
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
    '[]'::json
  ) AS images,
  r.size,
  p.school_id,
  s.name AS school_name,
  r.distance_to_school_km,
  r.expires_at,
  CASE
    WHEN r.expires_at IS NOT NULL AND r.expires_at <= NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM public.rent_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
JOIN public.schools s ON s.id = p.school_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
      AND r.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE r.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND (r.expires_at IS NULL OR r.expires_at > NOW());

ALTER VIEW IF EXISTS public.rent_posts_view SET (security_invoker = true);

-- =========================================================
-- secondhand_posts_view: hide expired listings automatically
-- =========================================================
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
  public.calculate_hot_score(s.view_count, s.like_count, s.comment_count, s.save_count, p.created_at) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN ('urgent'::public.post_highlight_type, 'breaking'::public.post_highlight_type) THEN 1
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
    '[]'::json
  ) AS images,
  CASE
    WHEN s.original_price IS NOT NULL AND s.original_price > 0
    THEN ROUND((1 - s.price / s.original_price) * 100)
    ELSE NULL
  END AS discount_percent,
  s.expires_at,
  CASE
    WHEN s.expires_at IS NOT NULL AND s.expires_at <= NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM public.secondhand_posts s
JOIN public.posts p ON s.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN s.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND s.pinned_until IS NOT NULL
      AND s.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE s.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND (s.expires_at IS NULL OR s.expires_at > NOW())
  AND (
    auth.uid() = p.user_id
    OR NOT public.is_blocked_by(p.user_id, auth.uid())
  );

ALTER VIEW IF EXISTS public.secondhand_posts_view SET (security_invoker = true);

-- =========================================================
-- Team manage view (active + archived/inactive for post owner)
-- =========================================================
CREATE OR REPLACE VIEW public.team_posts_manage_view AS
SELECT
  t.id,
  t.category,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.created_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  CASE WHEN p.status = 'inactive' THEN TRUE ELSE FALSE END AS is_archived
FROM public.team_posts t
JOIN public.posts p ON p.id = t.id
JOIN public.profiles pr ON pr.id = p.user_id
WHERE p.type = 'team'
  AND p.status IN ('active', 'inactive');

ALTER VIEW IF EXISTS public.team_posts_manage_view SET (security_invoker = true);

NOTIFY pgrst, 'reload schema';

COMMIT;
