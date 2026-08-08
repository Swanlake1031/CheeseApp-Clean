BEGIN;

-- Public feed views continue to hide private posts from everyone except the
-- authenticated owner. This lets the owner reopen a hidden post from Profile
-- without exposing it to other users.
CREATE OR REPLACE VIEW public.secondhand_posts_view AS
SELECT
  s.id, s.price, s.original_price, s.is_negotiable, s.is_free,
  s.category, s.condition, s.can_ship, s.shipping_fee,
  s.quantity, s.sold_count,
  tier.effective_highlight_type AS highlight_type,
  s.pinned_until, s.view_count, s.like_count, s.comment_count, s.save_count,
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
  p.user_id, p.title, p.description, p.status, p.is_anonymous,
  p.created_at, p.updated_at,
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
  (s.expires_at IS NOT NULL AND s.expires_at <= NOW()) AS is_expired,
  CASE WHEN p.is_anonymous THEN FALSE ELSE pr.is_mcmaster_verified END
    AS user_mcmaster_verified
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
  AND (p.is_private = FALSE OR p.user_id = auth.uid())
  AND (s.expires_at IS NULL OR s.expires_at > NOW());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id, f.board_id, board.slug AS board_slug, board.name AS board_name,
  board.icon AS board_icon,
  board.allows_anonymous_posts AS board_allows_anonymous,
  f.allow_comments, f.is_pinned, f.is_locked, f.like_count, f.comment_count,
  tier.effective_highlight_type AS highlight_type, f.pinned_until,
  f.view_count, f.save_count,
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
  p.title, p.description, p.status, p.is_anonymous, p.created_at, p.updated_at,
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
  (p.user_id = auth.uid()) AS viewer_owns_post,
  CASE
    WHEN p.is_anonymous THEN FALSE
    ELSE pr.is_mcmaster_verified
  END AS user_mcmaster_verified
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
  AND (p.is_private = FALSE OR p.user_id = auth.uid())
  AND board.status <> 'archived';

ALTER VIEW public.forum_posts_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.forum_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.forum_posts_view TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
