-- 084_unified_post_search_rpc.sql
-- Keep cross-module post search out of the Swift client.

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
  group_results AS (
    SELECT
      t.id,
      'groups'::TEXT AS category,
      t.title,
      COALESCE(NULLIF(t.description, ''), 'Looking for teammates')::TEXT AS subtitle,
      NULL::TEXT AS preview_image_url,
      t.created_at,
      COALESCE(t.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(t.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(t.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.team_posts_view t
    CROSS JOIN input i
    WHERE i.category_key IN ('all', 'groups')
      AND (
        i.query_text = ''
        OR (COALESCE(t.title, '') || ' ' || COALESCE(t.description, '')) ILIKE '%' || i.query_text || '%'
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
  carpool_rows AS (
    SELECT DISTINCT ON (rt.id)
      rt.id,
      'carpool'::TEXT AS category,
      COALESCE(c.label, c.origin_city || ' -> ' || c.dest_city)::TEXT AS title,
      (TO_CHAR(ti.trip_date, 'Mon DD') || ' ' || LEFT(ti.depart_time::TEXT, 5) || ' - $' || TRIM(TO_CHAR(rt.driver_full_route_price_cad, 'FM999999990.00')) || '/seat')::TEXT AS subtitle,
      NULL::TEXT AS preview_image_url,
      (ti.trip_date::TIMESTAMP + ti.depart_time)::TIMESTAMPTZ AS created_at,
      0::DOUBLE PRECISION AS hot_score,
      'normal'::TEXT AS highlight_type,
      2::INTEGER AS highlight_rank
    FROM public.carpool_route_templates rt
    JOIN public.carpool_trip_instances ti
      ON ti.route_template_id = rt.id
    JOIN public.carpool_corridors c
      ON c.id = rt.corridor_id
    CROSS JOIN input i
    WHERE i.category_key IN ('all', 'carpool')
      AND rt.is_active = TRUE
      AND c.is_active = TRUE
      AND ti.seats_remaining > 0
      AND ti.status::TEXT IN ('scheduled', 'confirmed')
      AND ti.trip_date >= CURRENT_DATE
      AND (
        i.query_text = ''
        OR (COALESCE(c.label, '') || ' ' || COALESCE(c.origin_city, '') || ' ' || COALESCE(c.dest_city, '') || ' ' || COALESCE(rt.driver_note, '')) ILIKE '%' || i.query_text || '%'
      )
    ORDER BY rt.id, ti.trip_date ASC, ti.depart_time ASC
  ),
  combined AS (
    SELECT * FROM rent_results
    UNION ALL SELECT * FROM secondhand_results
    UNION ALL SELECT * FROM carpool_rows
    UNION ALL SELECT * FROM group_results
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

NOTIFY pgrst, 'reload schema';
