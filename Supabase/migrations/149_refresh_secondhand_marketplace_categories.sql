-- Refresh the second-hand marketplace category contract.
--
-- Existing data is preserved and normalized as follows:
--   furniture/appliances -> home_appliances
--   clothing             -> fashion_accessories
--   beauty               -> beauty_care
--   sports               -> sports_outdoors
--   electronics          -> digital_electronics
--   academic/books       -> books_academic
--
-- Rollback note:
--   The furniture/appliances merge is intentionally lossy. A rollback cannot
--   determine which of those two legacy values a normalized row used before.

BEGIN;

CREATE OR REPLACE FUNCTION public.normalize_secondhand_category(
  p_category TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT CASE lower(btrim(p_category))
    WHEN 'furniture' THEN 'home_appliances'
    WHEN 'appliances' THEN 'home_appliances'
    WHEN 'home_appliances' THEN 'home_appliances'
    WHEN 'daily_essentials' THEN 'daily_essentials'
    WHEN 'clothing' THEN 'fashion_accessories'
    WHEN 'fashion' THEN 'fashion_accessories'
    WHEN 'fashion_accessories' THEN 'fashion_accessories'
    WHEN 'beauty' THEN 'beauty_care'
    WHEN 'beauty_care' THEN 'beauty_care'
    WHEN 'sports' THEN 'sports_outdoors'
    WHEN 'sports_outdoors' THEN 'sports_outdoors'
    WHEN 'electronics' THEN 'digital_electronics'
    WHEN 'digital_electronics' THEN 'digital_electronics'
    WHEN 'academic' THEN 'books_academic'
    WHEN 'books' THEN 'books_academic'
    WHEN 'textbooks' THEN 'books_academic'
    WHEN 'books_academic' THEN 'books_academic'
    WHEN 'pets' THEN 'pet_supplies'
    WHEN 'pet_supplies' THEN 'pet_supplies'
    WHEN 'other' THEN 'other'
    ELSE lower(btrim(p_category))
  END
$$;

ALTER TABLE public.secondhand_posts
  DROP CONSTRAINT IF EXISTS secondhand_posts_category_check;

UPDATE public.secondhand_posts
SET category = public.normalize_secondhand_category(category);

ALTER TABLE public.secondhand_posts
  ADD CONSTRAINT secondhand_posts_category_check
  CHECK (category IN (
    'home_appliances',
    'daily_essentials',
    'fashion_accessories',
    'beauty_care',
    'sports_outdoors',
    'digital_electronics',
    'books_academic',
    'pet_supplies',
    'other'
  ));

CREATE OR REPLACE FUNCTION public.publish_secondhand_post(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_expires_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_school_id UUID;
  v_existing public.posts%ROWTYPE;
  v_listing public.secondhand_posts%ROWTYPE;
  v_expected_media_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Secondhand title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_price IS NULL OR p_price < 0 THEN
    RAISE EXCEPTION 'Secondhand price must be nonnegative' USING ERRCODE = '22023';
  END IF;

  p_category := public.normalize_secondhand_category(p_category);
  IF p_category NOT IN (
    'home_appliances', 'daily_essentials', 'fashion_accessories',
    'beauty_care', 'sports_outdoors', 'digital_electronics',
    'books_academic', 'pet_supplies', 'other'
  ) THEN
    RAISE EXCEPTION 'Unsupported Secondhand category' USING ERRCODE = '22023';
  END IF;
  IF p_condition NOT IN ('new', 'like_new', 'good', 'fair', 'poor') THEN
    RAISE EXCEPTION 'Unsupported Secondhand condition' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing FROM public.posts WHERE id = p_post_id;
  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_me
       OR v_existing.type IS DISTINCT FROM 'secondhand' THEN
      RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_listing FROM public.secondhand_posts WHERE id = p_post_id;
    IF NOT FOUND
       OR v_existing.title IS DISTINCT FROM BTRIM(p_title)
       OR COALESCE(v_existing.description, '') IS DISTINCT FROM BTRIM(p_description)
       OR v_existing.is_anonymous IS DISTINCT FROM p_is_anonymous
       OR v_existing.is_private IS DISTINCT FROM p_is_private
       OR v_listing.price IS DISTINCT FROM p_price
       OR v_listing.category IS DISTINCT FROM p_category
       OR v_listing.condition IS DISTINCT FROM p_condition
       OR v_listing.is_negotiable IS DISTINCT FROM p_is_negotiable
       OR v_listing.expires_at IS DISTINCT FROM p_expires_at
       OR EXISTS (
         SELECT 1 FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status <> 'finalized'
       )
       OR (
         SELECT COUNT(*) FROM public.post_images image
         WHERE image.post_id = p_post_id
       ) IS DISTINCT FROM (
         SELECT COUNT(*) FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
       )
       OR EXISTS (
         SELECT 1 FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
           AND NOT EXISTS (
             SELECT 1 FROM public.post_images image
             WHERE image.id = stage.id
               AND image.post_id = p_post_id
               AND image.bucket = stage.bucket
               AND image.object_path = stage.object_path
               AND image.url = stage.url
               AND image.order_index = stage.order_index
           )
       )
    THEN
      RAISE EXCEPTION 'Secondhand publish idempotency conflict'
        USING ERRCODE = '23505';
    END IF;
    RETURN p_post_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND (
        stage.owner_id IS DISTINCT FROM v_me
        OR stage.post_id IS DISTINCT FROM p_post_id
        OR stage.post_type IS DISTINCT FROM 'secondhand'
      )
  ) THEN
    RAISE EXCEPTION 'Secondhand media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'secondhand'
      AND stage.status <> 'uploaded'
  ) THEN
    RAISE EXCEPTION 'Secondhand media upload is incomplete'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*) INTO v_expected_media_count
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'secondhand'
    AND stage.status = 'uploaded';

  IF v_expected_media_count < 1 THEN
    RAISE EXCEPTION 'Secondhand listing requires at least one image'
      USING ERRCODE = '23514';
  END IF;

  SELECT profile.school_id INTO v_school_id
  FROM public.profiles profile WHERE profile.id = v_me;
  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  INSERT INTO public.posts (
    id, user_id, school_id, type, title, description, status,
    is_anonymous, is_private
  ) VALUES (
    p_post_id, v_me, v_school_id, 'secondhand', BTRIM(p_title),
    NULLIF(BTRIM(p_description), ''), 'active', p_is_anonymous, p_is_private
  );

  INSERT INTO public.secondhand_posts (
    id, price, is_negotiable, is_free, category, condition,
    can_ship, quantity, expires_at
  ) VALUES (
    p_post_id, p_price, p_is_negotiable, FALSE, p_category, p_condition,
    FALSE, 1, p_expires_at
  );

  INSERT INTO public.post_images (
    id, post_id, url, order_index, bucket, object_path
  )
  SELECT
    stage.id, p_post_id, stage.url, stage.order_index,
    stage.bucket, stage.object_path
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'secondhand'
    AND stage.status = 'uploaded'
  ORDER BY stage.order_index;

  IF (
    SELECT COUNT(*) FROM public.post_images image
    WHERE image.post_id = p_post_id
  ) IS DISTINCT FROM v_expected_media_count THEN
    RAISE EXCEPTION 'Secondhand image metadata finalization failed'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.post_media_staging
  SET status = 'finalized', finalized_at = NOW()
  WHERE operation_id = p_operation_id
    AND owner_id = v_me
    AND post_id = p_post_id
    AND post_type = 'secondhand'
    AND status = 'uploaded';

  UPDATE public.post_media_cleanup_backlog cleanup
  SET status = 'resolved', reason = 'published', resolved_at = NOW(),
      last_error_code = NULL
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND cleanup.source_staging_id = stage.id
    AND cleanup.owner_id = v_me;

  RETURN p_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_secondhand_post_with_media(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_original_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_keep_image_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  p_category := public.normalize_secondhand_category(p_category);
  IF p_category NOT IN (
    'home_appliances', 'daily_essentials', 'fashion_accessories',
    'beauty_care', 'sports_outdoors', 'digital_electronics',
    'books_academic', 'pet_supplies', 'other'
  ) THEN
    RAISE EXCEPTION 'Unsupported Secondhand category' USING ERRCODE = '22023';
  END IF;
  IF p_original_price IS NOT NULL
     AND (p_original_price < 0 OR p_original_price < p_price) THEN
    RAISE EXCEPTION 'Original price must not be below the selling price'
      USING ERRCODE = '22023';
  END IF;

  PERFORM public.update_secondhand_post_with_media(
    p_post_id, p_operation_id, p_title, p_description, p_is_private,
    p_price, p_condition, p_is_negotiable, p_keep_image_ids
  );

  UPDATE public.secondhand_posts
  SET original_price = p_original_price,
      category = p_category
  WHERE id = p_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.normalize_secondhand_category(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
