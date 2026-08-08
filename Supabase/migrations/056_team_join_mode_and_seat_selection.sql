-- 056_team_join_mode_and_seat_selection.sql
-- 组队加入策略 + 选座字段

ALTER TABLE public.team_posts
  ADD COLUMN IF NOT EXISTS join_mode TEXT NOT NULL DEFAULT 'approval';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'team_posts_join_mode_check'
  ) THEN
    ALTER TABLE public.team_posts
      ADD CONSTRAINT team_posts_join_mode_check
      CHECK (join_mode IN ('approval', 'auto'));
  END IF;
END
$$;

ALTER TABLE public.team_members
  ADD COLUMN IF NOT EXISTS preferred_seat INTEGER;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'team_members_preferred_seat_check'
  ) THEN
    ALTER TABLE public.team_members
      ADD CONSTRAINT team_members_preferred_seat_check
      CHECK (preferred_seat IS NULL OR preferred_seat >= 1);
  END IF;
END
$$;

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
  t.event_time,
  t.join_mode
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
