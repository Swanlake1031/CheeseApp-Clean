-- 106_rent_transactional_publishing_and_media_cleanup.sql
--
-- H2 Phase D:
-- - publish one complete Rent post through an idempotent transaction;
-- - finalize only pre-recorded, successfully uploaded media identities;
-- - make image replacement/removal and post deletion cleanup observable.
--
-- URL-only writes remain temporarily available for older supported clients.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_rent_publish_status(
  p_post_id UUID
)
RETURNS TABLE (
  post_id UUID,
  is_complete BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    post.id,
    EXISTS (
      SELECT 1
      FROM public.rent_posts listing
      WHERE listing.id = post.id
    )
  FROM public.posts post
  WHERE post.id = p_post_id
    AND post.user_id = auth.uid()
    AND post.type = 'rent';
$$;

CREATE OR REPLACE FUNCTION public.publish_rent_post(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_location TEXT,
  p_bedrooms INTEGER,
  p_bathrooms NUMERIC,
  p_specs TEXT,
  p_size NUMERIC,
  p_property_type TEXT,
  p_available_from DATE,
  p_utilities_included BOOLEAN,
  p_pets_allowed BOOLEAN,
  p_parking_available BOOLEAN,
  p_laundry_type TEXT,
  p_amenities JSONB,
  p_latitude NUMERIC,
  p_longitude NUMERIC,
  p_distance_to_school_km NUMERIC,
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
  v_listing public.rent_posts%ROWTYPE;
  v_expected_media_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Rent title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'Rent price must be positive' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(BTRIM(p_location), '') IS NULL THEN
    RAISE EXCEPTION 'Rent location cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_property_type NOT IN ('studio', 'apartment', 'house', 'condo', 'room') THEN
    RAISE EXCEPTION 'Unsupported Rent property type' USING ERRCODE = '22023';
  END IF;
  IF p_bedrooms IS NULL OR p_bedrooms < 0
     OR p_bathrooms IS NULL OR p_bathrooms < 0 THEN
    RAISE EXCEPTION 'Rent room counts must be nonnegative' USING ERRCODE = '22023';
  END IF;
  IF p_laundry_type IS NOT NULL
     AND p_laundry_type NOT IN ('in_unit', 'in_building', 'none') THEN
    RAISE EXCEPTION 'Unsupported laundry type' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
  FROM public.posts
  WHERE id = p_post_id;

  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_me
       OR v_existing.type IS DISTINCT FROM 'rent' THEN
      RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_listing
    FROM public.rent_posts
    WHERE id = p_post_id;

    IF NOT FOUND
       OR v_existing.title IS DISTINCT FROM BTRIM(p_title)
       OR COALESCE(v_existing.description, '') IS DISTINCT FROM BTRIM(p_description)
       OR v_existing.is_anonymous IS DISTINCT FROM p_is_anonymous
       OR v_existing.is_private IS DISTINCT FROM p_is_private
       OR v_listing.price IS DISTINCT FROM p_price
       OR v_listing.location IS DISTINCT FROM BTRIM(p_location)
       OR v_listing.bedrooms IS DISTINCT FROM p_bedrooms
       OR v_listing.bathrooms IS DISTINCT FROM p_bathrooms
       OR v_listing.specs IS DISTINCT FROM NULLIF(BTRIM(p_specs), '')
       OR v_listing.size IS DISTINCT FROM p_size
       OR v_listing.property_type IS DISTINCT FROM p_property_type
       OR v_listing.available_from IS DISTINCT FROM p_available_from
       OR v_listing.utilities_included IS DISTINCT FROM p_utilities_included
       OR v_listing.pets_allowed IS DISTINCT FROM p_pets_allowed
       OR v_listing.parking_available IS DISTINCT FROM p_parking_available
       OR v_listing.laundry_type IS DISTINCT FROM p_laundry_type
       OR COALESCE(v_listing.amenities, '[]'::JSONB)
          IS DISTINCT FROM COALESCE(p_amenities, '[]'::JSONB)
       OR v_listing.latitude IS DISTINCT FROM p_latitude
       OR v_listing.longitude IS DISTINCT FROM p_longitude
       OR v_listing.expires_at IS DISTINCT FROM p_expires_at
       OR EXISTS (
         SELECT 1
         FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status <> 'finalized'
       )
       OR (
         SELECT COUNT(*)
         FROM public.post_images image
         WHERE image.post_id = p_post_id
       ) IS DISTINCT FROM (
         SELECT COUNT(*)
         FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
       )
       OR EXISTS (
         SELECT 1
         FROM public.post_media_staging stage
         WHERE stage.operation_id = p_operation_id
           AND stage.owner_id = v_me
           AND stage.status = 'finalized'
           AND NOT EXISTS (
             SELECT 1
             FROM public.post_images image
             WHERE image.id = stage.id
               AND image.post_id = p_post_id
               AND image.bucket = stage.bucket
               AND image.object_path = stage.object_path
               AND image.url = stage.url
               AND image.order_index = stage.order_index
           )
       )
    THEN
      RAISE EXCEPTION 'Rent publish idempotency conflict'
        USING ERRCODE = '23505';
    END IF;

    RETURN p_post_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND (
        stage.owner_id IS DISTINCT FROM v_me
        OR stage.post_id IS DISTINCT FROM p_post_id
        OR stage.post_type IS DISTINCT FROM 'rent'
      )
  ) THEN
    RAISE EXCEPTION 'Rent media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'rent'
      AND stage.status <> 'uploaded'
  ) THEN
    RAISE EXCEPTION 'Rent media upload is incomplete'
      USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*) INTO v_expected_media_count
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'rent'
    AND stage.status = 'uploaded';

  SELECT profile.school_id INTO v_school_id
  FROM public.profiles profile
  WHERE profile.id = v_me;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  INSERT INTO public.posts (
    id, user_id, school_id, type, title, description, status,
    is_anonymous, is_private
  )
  VALUES (
    p_post_id, v_me, v_school_id, 'rent', BTRIM(p_title),
    NULLIF(BTRIM(p_description), ''), 'active', p_is_anonymous, p_is_private
  );

  INSERT INTO public.rent_posts (
    id, price, location, latitude, longitude, bedrooms, bathrooms, specs,
    size, property_type, is_available, available_from, utilities_included,
    pets_allowed, parking_available, laundry_type, amenities,
    distance_to_school_km, expires_at
  )
  VALUES (
    p_post_id, p_price, BTRIM(p_location), p_latitude, p_longitude,
    p_bedrooms, p_bathrooms, NULLIF(BTRIM(p_specs), ''), p_size,
    p_property_type, TRUE, p_available_from, p_utilities_included,
    p_pets_allowed, p_parking_available, p_laundry_type,
    COALESCE(p_amenities, '[]'::JSONB), p_distance_to_school_km, p_expires_at
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
    AND stage.post_type = 'rent'
    AND stage.status = 'uploaded'
  ORDER BY stage.order_index;

  IF (
    SELECT COUNT(*)
    FROM public.post_images image
    WHERE image.post_id = p_post_id
  ) IS DISTINCT FROM v_expected_media_count THEN
    RAISE EXCEPTION 'Rent image metadata finalization failed'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.post_media_staging
  SET status = 'finalized', finalized_at = NOW()
  WHERE operation_id = p_operation_id
    AND owner_id = v_me
    AND post_id = p_post_id
    AND post_type = 'rent'
    AND status = 'uploaded';

  UPDATE public.post_media_cleanup_backlog cleanup
  SET
    status = 'resolved',
    reason = 'published',
    resolved_at = NOW(),
    last_error_code = NULL
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND cleanup.source_staging_id = stage.id
    AND cleanup.owner_id = v_me;

  RETURN p_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_rent_post_with_media(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_location TEXT,
  p_bedrooms INTEGER,
  p_bathrooms NUMERIC,
  p_size NUMERIC,
  p_property_type TEXT,
  p_available_from DATE,
  p_utilities_included BOOLEAN,
  p_pets_allowed BOOLEAN,
  p_parking_available BOOLEAN,
  p_amenities JSONB,
  p_keep_image_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_image RECORD;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Rent title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_price IS NULL OR p_price <= 0 THEN
    RAISE EXCEPTION 'Rent price must be positive' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(BTRIM(p_location), '') IS NULL THEN
    RAISE EXCEPTION 'Rent location cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF p_property_type NOT IN ('studio', 'apartment', 'house', 'condo', 'room') THEN
    RAISE EXCEPTION 'Unsupported Rent property type' USING ERRCODE = '22023';
  END IF;
  IF p_bedrooms IS NULL OR p_bedrooms < 0
     OR p_bathrooms IS NULL OR p_bathrooms < 0 THEN
    RAISE EXCEPTION 'Rent room counts must be nonnegative' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.posts post
    JOIN public.rent_posts listing ON listing.id = post.id
    WHERE post.id = p_post_id
      AND post.user_id = v_me
      AND post.type = 'rent'
  ) THEN
    RAISE EXCEPTION 'Rent post not found or not editable'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM UNNEST(COALESCE(p_keep_image_ids, ARRAY[]::UUID[])) keep_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.post_images image
      WHERE image.id = keep_id
        AND image.post_id = p_post_id
    )
  ) THEN
    RAISE EXCEPTION 'Retained image does not belong to the Rent post'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND (
        stage.owner_id IS DISTINCT FROM v_me
        OR stage.post_id IS DISTINCT FROM p_post_id
        OR stage.post_type IS DISTINCT FROM 'rent'
      )
  ) THEN
    RAISE EXCEPTION 'Rent media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'rent'
      AND stage.status NOT IN ('uploaded', 'finalized')
  ) THEN
    RAISE EXCEPTION 'Rent media upload is incomplete'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.posts
  SET
    title = BTRIM(p_title),
    description = NULLIF(BTRIM(p_description), ''),
    is_private = p_is_private
  WHERE id = p_post_id
    AND user_id = v_me
    AND type = 'rent';

  UPDATE public.rent_posts
  SET
    price = p_price,
    location = BTRIM(p_location),
    bedrooms = p_bedrooms,
    bathrooms = p_bathrooms,
    specs = p_bedrooms || ' bed ' || p_bathrooms || ' bath',
    size = p_size,
    property_type = p_property_type,
    available_from = p_available_from,
    utilities_included = p_utilities_included,
    pets_allowed = p_pets_allowed,
    parking_available = p_parking_available,
    amenities = COALESCE(p_amenities, '[]'::JSONB)
  WHERE id = p_post_id;

  FOR v_image IN
    SELECT image.*
    FROM public.post_images image
    WHERE image.post_id = p_post_id
      AND image.id <> ALL(COALESCE(p_keep_image_ids, ARRAY[]::UUID[]))
      AND NOT EXISTS (
        SELECT 1
        FROM public.post_media_staging stage
        WHERE stage.operation_id = p_operation_id
          AND stage.id = image.id
          AND stage.status = 'finalized'
      )
  LOOP
    IF v_image.bucket IS NOT NULL AND v_image.object_path IS NOT NULL THEN
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id, post_image_id, post_id, bucket, object_path, stored_url,
        status, reason
      )
      VALUES (
        v_me, v_image.id, p_post_id, v_image.bucket, v_image.object_path,
        v_image.url, 'pending', 'rent_image_removed'
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO UPDATE SET
        status = 'pending',
        reason = EXCLUDED.reason,
        resolved_at = NULL;
    ELSE
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id, post_image_id, post_id, stored_url, status, reason,
        candidate_count
      )
      VALUES (
        v_me, v_image.id, p_post_id, v_image.url, 'unresolved',
        COALESCE(
          (
            SELECT reconciliation.reason
            FROM public.post_image_reconciliation_backlog reconciliation
            WHERE reconciliation.post_image_id = v_image.id
          ),
          'legacy_object_path_unresolved'
        ),
        COALESCE(
          (
            SELECT reconciliation.candidate_count
            FROM public.post_image_reconciliation_backlog reconciliation
            WHERE reconciliation.post_image_id = v_image.id
          ),
          0
        )
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO NOTHING;
    END IF;
  END LOOP;

  DELETE FROM public.post_images image
  WHERE image.post_id = p_post_id
    AND image.id <> ALL(COALESCE(p_keep_image_ids, ARRAY[]::UUID[]))
    AND NOT EXISTS (
      SELECT 1
      FROM public.post_media_staging stage
      WHERE stage.operation_id = p_operation_id
        AND stage.id = image.id
        AND stage.status = 'finalized'
    );

  INSERT INTO public.post_images (
    id, post_id, url, order_index, bucket, object_path
  )
  SELECT
    stage.id,
    p_post_id,
    stage.url,
    (
      SELECT COUNT(*)
      FROM public.post_images retained
      WHERE retained.post_id = p_post_id
    ) + stage.order_index,
    stage.bucket,
    stage.object_path
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'rent'
    AND stage.status IN ('uploaded', 'finalized')
  ON CONFLICT (id)
  DO UPDATE SET
    post_id = EXCLUDED.post_id,
    url = EXCLUDED.url,
    order_index = EXCLUDED.order_index,
    bucket = EXCLUDED.bucket,
    object_path = EXCLUDED.object_path;

  UPDATE public.post_media_staging
  SET status = 'finalized', finalized_at = COALESCE(finalized_at, NOW())
  WHERE operation_id = p_operation_id
    AND owner_id = v_me
    AND post_id = p_post_id
    AND post_type = 'rent'
    AND status = 'uploaded';

  UPDATE public.post_media_cleanup_backlog cleanup
  SET
    status = 'resolved',
    reason = 'published',
    resolved_at = NOW(),
    last_error_code = NULL
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND cleanup.source_staging_id = stage.id
    AND cleanup.owner_id = v_me;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_rent_post_with_media(
  p_post_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_image RECORD;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.posts post
    WHERE post.id = p_post_id
      AND post.user_id = v_me
      AND post.type = 'rent'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM public.post_media_cleanup_backlog cleanup
      WHERE cleanup.post_id = p_post_id
        AND cleanup.owner_id = v_me
    ) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Rent post not found or not deletable'
      USING ERRCODE = '42501';
  END IF;

  FOR v_image IN
    SELECT image.*
    FROM public.post_images image
    WHERE image.post_id = p_post_id
  LOOP
    IF v_image.bucket IS NOT NULL AND v_image.object_path IS NOT NULL THEN
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id, post_image_id, post_id, bucket, object_path, stored_url,
        status, reason
      )
      VALUES (
        v_me, v_image.id, p_post_id, v_image.bucket, v_image.object_path,
        v_image.url, 'pending', 'rent_post_deleted'
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO UPDATE SET
        status = 'pending',
        reason = EXCLUDED.reason,
        resolved_at = NULL;
    ELSE
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id, post_image_id, post_id, stored_url, status, reason,
        candidate_count
      )
      VALUES (
        v_me, v_image.id, p_post_id, v_image.url, 'unresolved',
        COALESCE(
          (
            SELECT reconciliation.reason
            FROM public.post_image_reconciliation_backlog reconciliation
            WHERE reconciliation.post_image_id = v_image.id
          ),
          'legacy_object_path_unresolved'
        ),
        COALESCE(
          (
            SELECT reconciliation.candidate_count
            FROM public.post_image_reconciliation_backlog reconciliation
            WHERE reconciliation.post_image_id = v_image.id
          ),
          0
        )
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO NOTHING;
    END IF;
  END LOOP;

  DELETE FROM public.posts
  WHERE id = p_post_id
    AND user_id = v_me
    AND type = 'rent';
END;
$$;

REVOKE ALL ON FUNCTION public.get_rent_publish_status(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.publish_rent_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC,
  TEXT, NUMERIC, TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, TEXT, JSONB, NUMERIC,
  NUMERIC, NUMERIC, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_rent_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC, NUMERIC,
  TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, JSONB, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_rent_post_with_media(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_rent_publish_status(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_rent_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC,
  TEXT, NUMERIC, TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, TEXT, JSONB, NUMERIC,
  NUMERIC, NUMERIC, TIMESTAMPTZ
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_rent_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC, NUMERIC,
  TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, JSONB, UUID[]
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_rent_post_with_media(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
