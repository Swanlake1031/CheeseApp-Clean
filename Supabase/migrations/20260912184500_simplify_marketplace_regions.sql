-- Match the launch Marketplace area list while keeping the previous app build
-- compatible. Existing listings remain available and are mapped conservatively.

BEGIN;

ALTER TABLE public.secondhand_posts
  DROP CONSTRAINT secondhand_posts_marketplace_region_check;

UPDATE public.secondhand_posts
SET marketplace_region = CASE marketplace_region
  WHEN 'greater_toronto_area' THEN 'toronto'
  WHEN 'hamilton' THEN 'hamilton'
  ELSE 'outside'
END;

ALTER TABLE public.secondhand_posts
  ALTER COLUMN marketplace_region SET DEFAULT 'outside';

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_marketplace_region_check
  CHECK (marketplace_region IN (
    'toronto', 'north_york', 'hamilton', 'oakville',
    'etobicoke', 'richmond', 'outside'
  ));

CREATE OR REPLACE FUNCTION public.get_secondhand_posts_page(
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
DECLARE
  v_region TEXT;
BEGIN
  v_region := CASE lower(btrim(p_marketplace_region))
    WHEN 'toronto' THEN 'toronto'
    WHEN 'north_york' THEN 'north_york'
    WHEN 'northyork' THEN 'north_york'
    WHEN 'hamilton' THEN 'hamilton'
    WHEN 'oakville' THEN 'oakville'
    WHEN 'etobicoke' THEN 'etobicoke'
    WHEN 'richmond' THEN 'richmond'
    WHEN 'outside' THEN 'outside'
    WHEN 'greater_toronto_area' THEN 'toronto'
    WHEN 'waterloo_region' THEN 'outside'
    WHEN 'guelph' THEN 'outside'
    WHEN 'ottawa' THEN 'outside'
    WHEN 'montreal' THEN 'outside'
    WHEN 'metro_vancouver' THEN 'outside'
    WHEN 'calgary' THEN 'outside'
    WHEN 'edmonton' THEN 'outside'
    WHEN 'halifax' THEN 'outside'
    WHEN 'winnipeg' THEN 'outside'
    WHEN 'oshawa_durham' THEN 'outside'
    WHEN 'kingston' THEN 'outside'
    WHEN 'peterborough' THEN 'outside'
    WHEN 'niagara_region' THEN 'outside'
    WHEN 'thunder_bay' THEN 'outside'
    WHEN 'other_canada' THEN 'outside'
    WHEN 'united_states' THEN 'outside'
    ELSE NULL
  END;

  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'Secondhand page limit must be between 1 and 50'
      USING ERRCODE = '22023';
  END IF;
  IF (p_after_created_at IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'Secondhand cursor is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_marketplace_region IS NOT NULL AND v_region IS NULL THEN
    RAISE EXCEPTION 'Unsupported Marketplace region' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT feed.*
  FROM public.secondhand_posts_view feed
  WHERE (v_region IS NULL OR feed.marketplace_region = v_region)
    AND (
      p_after_created_at IS NULL
      OR (feed.created_at, feed.id) < (p_after_created_at, p_after_id)
    )
  ORDER BY feed.created_at DESC, feed.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_secondhand_post_with_mentions(
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
  v_region TEXT;
BEGIN
  v_region := CASE lower(btrim(COALESCE(p_marketplace_region, 'outside')))
    WHEN 'toronto' THEN 'toronto'
    WHEN 'north_york' THEN 'north_york'
    WHEN 'northyork' THEN 'north_york'
    WHEN 'hamilton' THEN 'hamilton'
    WHEN 'oakville' THEN 'oakville'
    WHEN 'etobicoke' THEN 'etobicoke'
    WHEN 'richmond' THEN 'richmond'
    WHEN 'outside' THEN 'outside'
    WHEN 'greater_toronto_area' THEN 'toronto'
    WHEN 'waterloo_region' THEN 'outside'
    WHEN 'guelph' THEN 'outside'
    WHEN 'ottawa' THEN 'outside'
    WHEN 'montreal' THEN 'outside'
    WHEN 'metro_vancouver' THEN 'outside'
    WHEN 'calgary' THEN 'outside'
    WHEN 'edmonton' THEN 'outside'
    WHEN 'halifax' THEN 'outside'
    WHEN 'winnipeg' THEN 'outside'
    WHEN 'oshawa_durham' THEN 'outside'
    WHEN 'kingston' THEN 'outside'
    WHEN 'peterborough' THEN 'outside'
    WHEN 'niagara_region' THEN 'outside'
    WHEN 'thunder_bay' THEN 'outside'
    WHEN 'other_canada' THEN 'outside'
    WHEN 'united_states' THEN 'outside'
    ELSE NULL
  END;

  IF v_region IS NULL THEN
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

NOTIFY pgrst, 'reload schema';

COMMIT;
