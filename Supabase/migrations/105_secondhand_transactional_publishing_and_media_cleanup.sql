-- 105_secondhand_transactional_publishing_and_media_cleanup.sql
--
-- H2 Phase C:
-- - publish one complete Secondhand listing through an idempotent transaction;
-- - finalize only pre-recorded, successfully uploaded media identities;
-- - make image replacement/removal and post deletion cleanup observable.
--
-- The secured legacy create_secondhand_post RPC and URL-only post_images writes
-- remain temporarily available for older supported clients. A later forward
-- migration may remove those paths only after the minimum app version advances.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_secondhand_publish_status(
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
      FROM public.secondhand_posts listing
      WHERE listing.id = post.id
    )
    AND EXISTS (
      SELECT 1
      FROM public.post_images image
      WHERE image.post_id = post.id
    )
  FROM public.posts post
  WHERE post.id = p_post_id
    AND post.user_id = auth.uid()
    AND post.type = 'secondhand';
$$;

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
  p_pickup_location TEXT,
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
  IF p_category NOT IN (
    'furniture', 'electronics', 'academic', 'clothing',
    'appliances', 'sports', 'beauty', 'other'
  ) THEN
    RAISE EXCEPTION 'Unsupported Secondhand category' USING ERRCODE = '22023';
  END IF;
  IF p_condition NOT IN ('new', 'like_new', 'good', 'fair', 'poor') THEN
    RAISE EXCEPTION 'Unsupported Secondhand condition' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
  FROM public.posts
  WHERE id = p_post_id;

  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_me
       OR v_existing.type IS DISTINCT FROM 'secondhand' THEN
      RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_listing
    FROM public.secondhand_posts
    WHERE id = p_post_id;

    IF NOT FOUND
       OR v_existing.title IS DISTINCT FROM BTRIM(p_title)
       OR COALESCE(v_existing.description, '') IS DISTINCT FROM BTRIM(p_description)
       OR v_existing.is_anonymous IS DISTINCT FROM p_is_anonymous
       OR v_existing.is_private IS DISTINCT FROM p_is_private
       OR v_listing.price IS DISTINCT FROM p_price
       OR v_listing.category IS DISTINCT FROM p_category
       OR v_listing.condition IS DISTINCT FROM p_condition
       OR v_listing.is_negotiable IS DISTINCT FROM p_is_negotiable
       OR v_listing.pickup_location IS DISTINCT FROM NULLIF(BTRIM(p_pickup_location), '')
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
      RAISE EXCEPTION 'Secondhand publish idempotency conflict'
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
        OR stage.post_type IS DISTINCT FROM 'secondhand'
      )
  ) THEN
    RAISE EXCEPTION 'Secondhand media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
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
    p_post_id, v_me, v_school_id, 'secondhand', BTRIM(p_title),
    NULLIF(BTRIM(p_description), ''), 'active', p_is_anonymous, p_is_private
  );

  INSERT INTO public.secondhand_posts (
    id, price, is_negotiable, is_free, category, condition,
    pickup_location, can_ship, quantity, expires_at
  )
  VALUES (
    p_post_id, p_price, p_is_negotiable, FALSE, p_category, p_condition,
    NULLIF(BTRIM(p_pickup_location), ''), FALSE, 1, p_expires_at
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
    SELECT COUNT(*)
    FROM public.post_images image
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

CREATE OR REPLACE FUNCTION public.update_secondhand_post_with_media(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
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
  v_resulting_image_count INTEGER;
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
  IF p_condition NOT IN ('new', 'like_new', 'good', 'fair', 'poor') THEN
    RAISE EXCEPTION 'Unsupported Secondhand condition' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.posts post
    JOIN public.secondhand_posts listing ON listing.id = post.id
    WHERE post.id = p_post_id
      AND post.user_id = v_me
      AND post.type = 'secondhand'
  ) THEN
    RAISE EXCEPTION 'Secondhand post not found or not editable'
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
    RAISE EXCEPTION 'Retained image does not belong to the Secondhand post'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
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
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'secondhand'
      AND stage.status NOT IN ('uploaded', 'finalized')
  ) THEN
    RAISE EXCEPTION 'Secondhand media upload is incomplete'
      USING ERRCODE = '23514';
  END IF;

  SELECT
    CARDINALITY(COALESCE(p_keep_image_ids, ARRAY[]::UUID[]))
    + (
      SELECT COUNT(*)
      FROM public.post_media_staging stage
      WHERE stage.operation_id = p_operation_id
        AND stage.owner_id = v_me
        AND stage.post_id = p_post_id
        AND stage.post_type = 'secondhand'
        AND stage.status IN ('uploaded', 'finalized')
    )
  INTO v_resulting_image_count;

  IF v_resulting_image_count < 1 THEN
    RAISE EXCEPTION 'Secondhand listing requires at least one image'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.posts
  SET
    title = BTRIM(p_title),
    description = NULLIF(BTRIM(p_description), ''),
    is_private = p_is_private
  WHERE id = p_post_id
    AND user_id = v_me
    AND type = 'secondhand';

  UPDATE public.secondhand_posts
  SET
    price = p_price,
    condition = p_condition,
    is_negotiable = p_is_negotiable
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
        v_image.url, 'pending', 'secondhand_image_removed'
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
    AND stage.post_type = 'secondhand'
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
    AND post_type = 'secondhand'
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

CREATE OR REPLACE FUNCTION public.delete_secondhand_post_with_media(
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
      AND post.type = 'secondhand'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM public.post_media_cleanup_backlog cleanup
      WHERE cleanup.post_id = p_post_id
        AND cleanup.owner_id = v_me
    ) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Secondhand post not found or not deletable'
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
        v_image.url, 'pending', 'secondhand_post_deleted'
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
    AND type = 'secondhand';
END;
$$;

REVOKE ALL ON FUNCTION public.get_secondhand_publish_status(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT, BOOLEAN,
  TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, BOOLEAN, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_secondhand_post_with_media(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_secondhand_publish_status(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT, BOOLEAN,
  TEXT, TIMESTAMPTZ
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, BOOLEAN, UUID[]
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_secondhand_post_with_media(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
