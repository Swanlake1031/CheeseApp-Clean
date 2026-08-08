-- 083_remove_legacy_ride_from_geo_feed.sql
-- Ride provider carpools now live in carpool_route_templates / carpool_trip_instances.
-- Keep Home Geo Feed from returning legacy posts.id values for ride.

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
WHERE p.type = 'secondhand'

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
  t.highlight_type,
  t.pinned_until,
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
JOIN public.team_posts t ON t.id = p.id
JOIN public.profiles pr ON pr.id = p.user_id
JOIN public.schools s ON s.id = p.school_id
WHERE p.type = 'team';

ALTER VIEW IF EXISTS public.geo_feed_posts_v1 SET (security_invoker = true);
