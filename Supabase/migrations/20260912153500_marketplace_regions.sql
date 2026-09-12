-- Add manually selected Marketplace regions without restoring GPS or PostGIS.
-- Existing listings are assigned from their author's school city where
-- possible; uncertain rows remain available under other_canada.

BEGIN;

ALTER TABLE public.secondhand_posts
  ADD COLUMN marketplace_region TEXT NOT NULL DEFAULT 'other_canada';

UPDATE public.secondhand_posts listing
SET marketplace_region = CASE lower(btrim(COALESCE(school.city, '')))
  WHEN 'toronto' THEN 'greater_toronto_area'
  WHEN 'hamilton' THEN 'hamilton'
  WHEN 'waterloo' THEN 'waterloo_region'
  WHEN 'guelph' THEN 'guelph'
  WHEN 'ottawa' THEN 'ottawa'
  WHEN 'montréal' THEN 'montreal'
  WHEN 'montreal' THEN 'montreal'
  WHEN 'vancouver' THEN 'metro_vancouver'
  WHEN 'burnaby' THEN 'metro_vancouver'
  WHEN 'calgary' THEN 'calgary'
  WHEN 'edmonton' THEN 'edmonton'
  WHEN 'halifax' THEN 'halifax'
  WHEN 'winnipeg' THEN 'winnipeg'
  WHEN 'oshawa' THEN 'oshawa_durham'
  WHEN 'kingston' THEN 'kingston'
  WHEN 'peterborough' THEN 'peterborough'
  WHEN 'st. catharines' THEN 'niagara_region'
  WHEN 'thunder bay' THEN 'thunder_bay'
  ELSE 'other_canada'
END
FROM public.posts post_row
LEFT JOIN public.schools school ON school.id = post_row.school_id
WHERE post_row.id = listing.id;

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_marketplace_region_check
  CHECK (marketplace_region IN (
    'greater_toronto_area', 'hamilton', 'waterloo_region', 'guelph',
    'ottawa', 'montreal', 'metro_vancouver', 'calgary', 'edmonton',
    'halifax', 'winnipeg', 'oshawa_durham', 'kingston', 'peterborough',
    'niagara_region', 'thunder_bay', 'other_canada', 'united_states'
  ));

CREATE INDEX secondhand_posts_marketplace_region_id_idx
  ON public.secondhand_posts (marketplace_region, id);

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
    AS user_mcmaster_verified,
  p.is_private,
  s.marketplace_region
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
  AND (p.is_private = FALSE OR p.user_id = auth.uid());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER
);

CREATE FUNCTION public.get_secondhand_posts_page(
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24,
  p_marketplace_region TEXT DEFAULT NULL
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
  IF p_marketplace_region IS NOT NULL
     AND p_marketplace_region NOT IN (
       'greater_toronto_area', 'hamilton', 'waterloo_region', 'guelph',
       'ottawa', 'montreal', 'metro_vancouver', 'calgary', 'edmonton',
       'halifax', 'winnipeg', 'oshawa_durham', 'kingston', 'peterborough',
       'niagara_region', 'thunder_bay', 'other_canada', 'united_states'
     ) THEN
    RAISE EXCEPTION 'Unsupported Marketplace region' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT feed.*
  FROM public.secondhand_posts_view feed
  WHERE (p_marketplace_region IS NULL
         OR feed.marketplace_region = p_marketplace_region)
    AND (
      p_after_created_at IS NULL
      OR (feed.created_at, feed.id) < (p_after_created_at, p_after_id)
    )
  ORDER BY feed.created_at DESC, feed.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_secondhand_posts_page(
  TIMESTAMPTZ, UUID, INTEGER, TEXT
) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, NUMERIC, TEXT,
  TEXT, BOOLEAN, UUID[]
);

CREATE FUNCTION public.publish_secondhand_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_original_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[],
  p_marketplace_region TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
  v_expires_at TIMESTAMPTZ;
  v_region TEXT := COALESCE(p_marketplace_region, 'other_canada');
BEGIN
  IF v_region NOT IN (
    'greater_toronto_area', 'hamilton', 'waterloo_region', 'guelph',
    'ottawa', 'montreal', 'metro_vancouver', 'calgary', 'edmonton',
    'halifax', 'winnipeg', 'oshawa_durham', 'kingston', 'peterborough',
    'niagara_region', 'thunder_bay', 'other_canada', 'united_states'
  ) THEN
    RAISE EXCEPTION 'Unsupported Marketplace region' USING ERRCODE = '22023';
  END IF;
  IF p_original_price IS NOT NULL
     AND (p_original_price < 0 OR p_original_price < p_price) THEN
    RAISE EXCEPTION 'Original price must not be below the selling price'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.secondhand_posts listing
    WHERE listing.id = p_post_id
      AND listing.marketplace_region IS DISTINCT FROM v_region
  ) THEN
    RAISE EXCEPTION 'Secondhand publish idempotency conflict'
      USING ERRCODE = '23505';
  END IF;

  SELECT market.expires_at INTO v_expires_at
  FROM public.secondhand_posts market
  WHERE market.id = p_post_id;
  v_expires_at := COALESCE(
    v_expires_at,
    clock_timestamp() + INTERVAL '1 month'
  );

  v_post_id := public.publish_secondhand_post(
    p_post_id, p_operation_id, p_title, p_description,
    p_is_anonymous, p_is_private, p_price, p_category,
    p_condition, p_is_negotiable, v_expires_at
  );

  UPDATE public.secondhand_posts
  SET original_price = p_original_price,
      expires_at = v_expires_at,
      marketplace_region = v_region
  WHERE id = v_post_id;

  PERFORM public.sync_content_mentions(
    'secondhand', v_post_id, NULL, p_mentioned_user_ids
  );
  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, NUMERIC, TEXT,
  TEXT, BOOLEAN, UUID[], TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, NUMERIC, TEXT,
  TEXT, BOOLEAN, UUID[], TEXT
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
