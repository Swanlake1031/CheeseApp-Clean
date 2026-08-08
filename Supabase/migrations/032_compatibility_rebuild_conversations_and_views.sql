-- 032_compatibility_rebuild_conversations_and_views.sql
-- Forward-compatible guard migration:
-- 1) Rebuild get_user_conversations(UUID) with the new return signature.
-- 2) Re-apply ride/team views with stable column ordering (append-only).

-- ============================================
-- Conversation function (signature-safe rebuild)
-- ============================================
DROP FUNCTION IF EXISTS public.get_user_conversations(UUID);

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
SET search_path = public, auth, extensions
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END AS other_user_id,
    CASE
      WHEN c.user1_id = p_user_id THEN COALESCE(NULLIF(p2.full_name, ''), split_part(p2.email, '@', 1), '用户')
      ELSE COALESCE(NULLIF(p1.full_name, ''), split_part(p1.email, '@', 1), '用户')
    END AS other_user_name,
    CASE WHEN c.user1_id = p_user_id THEN p2.avatar_url ELSE p1.avatar_url END AS other_user_avatar,
    c.related_post_id,
    c.last_message_at,
    c.last_message_preview,
    CASE WHEN c.user1_id = p_user_id THEN c.user1_unread_count ELSE c.user2_unread_count END AS unread_count,
    public.is_mutual_follow(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    ) AS can_chat_freely,
    public.is_mutual_follow(
      p_user_id,
      CASE WHEN c.user1_id = p_user_id THEN c.user2_id ELSE c.user1_id END
    ) AS is_mutual_follow
  FROM public.conversations c
  JOIN public.profiles p1 ON p1.id = c.user1_id
  JOIN public.profiles p2 ON p2.id = c.user2_id
  WHERE c.user1_id = p_user_id OR c.user2_id = p_user_id
  ORDER BY c.last_message_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_conversations(UUID)
  TO authenticated, service_role;

-- ============================================
-- ride_posts_view (stable column order)
-- ============================================
CREATE OR REPLACE VIEW public.ride_posts_view AS
SELECT
  r.id,
  r.departure_location,
  r.departure_lat,
  r.departure_lng,
  r.destination_location,
  r.destination_lat,
  r.destination_lng,
  r.departure_time,
  r.is_flexible,
  r.role,
  r.total_seats,
  r.available_seats,
  r.price_per_seat,
  r.is_free,
  r.contact_method,
  r.contact_info,
  r.has_luggage_space,
  r.pets_allowed,
  r.smoking_allowed,
  r.notes,
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
  CASE
    WHEN r.role = 'driver' AND r.available_seats <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  CASE
    WHEN r.departure_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired,
  r.luggage_amount,
  r.vehicle_type
FROM public.ride_posts r
JOIN public.posts p ON r.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
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
  AND r.departure_time > (NOW() - INTERVAL '1 hour');

-- ============================================
-- team_posts_view (stable column order)
-- ============================================
CREATE OR REPLACE VIEW public.team_posts_view AS
SELECT
  t.id,
  t.category,
  t.course_name,
  t.professor,
  t.team_size,
  t.current_members,
  t.spots_available,
  t.skills_needed,
  t.skills_offered,
  t.deadline,
  t.commitment_hours,
  t.is_remote,
  t.meeting_location,
  t.has_compensation,
  t.compensation_details,
  tier.effective_highlight_type AS highlight_type,
  t.pinned_until,
  t.view_count,
  t.like_count,
  t.comment_count,
  t.save_count,
  public.calculate_hot_score(t.view_count, t.like_count, t.comment_count, t.save_count, p.created_at) AS hot_score,
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
  CASE
    WHEN t.spots_available <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  CASE
    WHEN t.deadline IS NOT NULL AND t.deadline < CURRENT_DATE THEN TRUE
    WHEN t.event_time IS NOT NULL AND t.event_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired,
  t.event_time
FROM public.team_posts t
JOIN public.posts p ON t.id = p.id
JOIN public.profiles pr ON p.user_id = pr.id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN t.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND t.pinned_until IS NOT NULL
      AND t.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE t.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active';

NOTIFY pgrst, 'reload schema';
