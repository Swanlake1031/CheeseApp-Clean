-- Remove the PL/pgSQL ambiguity between the `id` output parameter and the
-- post_media_staging.id column when a retry removes a previously staged image.
--
-- This is intentionally a forward-only function replacement. The RPC
-- signature, privileges, authorization checks, and behavior remain unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.prepare_post_media_operation(
  p_operation_id UUID,
  p_post_id UUID,
  p_post_type TEXT,
  p_media JSONB
)
RETURNS TABLE (
  id UUID,
  operation_id UUID,
  post_id UUID,
  bucket TEXT,
  object_path TEXT,
  url TEXT,
  order_index INTEGER,
  status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_item RECORD;
  v_existing RECORD;
  v_prefix TEXT;
  v_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_post_id IS NULL THEN
    RAISE EXCEPTION 'Media operation and post IDs are required' USING ERRCODE = '22004';
  END IF;
  IF p_post_type NOT IN ('forum', 'secondhand', 'rent') THEN
    RAISE EXCEPTION 'Unsupported post type' USING ERRCODE = '22023';
  END IF;
  IF p_media IS NULL OR jsonb_typeof(p_media) <> 'array' THEN
    RAISE EXCEPTION 'Media payload must be an array' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(p_media);
  IF v_count > 6 THEN
    RAISE EXCEPTION 'At most six post images are supported' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.posts post
    WHERE post.id = p_post_id
      AND (post.user_id IS DISTINCT FROM v_me OR post.type IS DISTINCT FROM p_post_type)
  ) THEN
    RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_media)
      AS media(bucket TEXT, object_path TEXT, url TEXT, order_index INTEGER)
    GROUP BY media.order_index
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Media order indexes must be unique' USING ERRCODE = '23505';
  END IF;

  v_prefix :=
    LOWER(v_me::TEXT) || '/posts/' || LOWER(p_post_id::TEXT) || '/'
    || LOWER(p_operation_id::TEXT) || '/';

  -- A retry may change the selected image count. Retire paths that are no
  -- longer present, but keep their exact cleanup obligation.
  FOR v_existing IN
    SELECT stage.*
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.status <> 'finalized'
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(p_media)
          AS media(bucket TEXT, object_path TEXT, url TEXT, order_index INTEGER)
        WHERE media.order_index = stage.order_index
      )
  LOOP
    INSERT INTO public.post_media_cleanup_backlog (
      owner_id, post_id, source_staging_id, bucket, object_path, stored_url,
      status, reason
    )
    VALUES (
      v_me, p_post_id, v_existing.id, v_existing.bucket,
      v_existing.object_path, v_existing.url, 'pending',
      'publish_selection_changed'
    )
    ON CONFLICT ON CONSTRAINT post_media_cleanup_source_staging_key
    DO UPDATE SET
      status = 'pending',
      reason = EXCLUDED.reason,
      resolved_at = NULL;

    UPDATE public.post_media_staging AS stage_to_retire
    SET status = 'cleanup_pending'
    WHERE stage_to_retire.id = v_existing.id;
  END LOOP;

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_media)
      AS media(bucket TEXT, object_path TEXT, url TEXT, order_index INTEGER)
    ORDER BY media.order_index
  LOOP
    IF v_item.bucket IS DISTINCT FROM 'post-images' THEN
      RAISE EXCEPTION 'Post images must use the post-images bucket'
        USING ERRCODE = '22023';
    END IF;
    IF NULLIF(BTRIM(v_item.object_path), '') IS NULL
       OR v_item.object_path NOT LIKE v_prefix || '%' THEN
      RAISE EXCEPTION 'Post image path is outside the authenticated operation prefix'
        USING ERRCODE = '42501';
    END IF;
    IF NULLIF(BTRIM(v_item.url), '') IS NULL THEN
      RAISE EXCEPTION 'Post image URL is required' USING ERRCODE = '22023';
    END IF;
    IF v_item.order_index IS NULL OR v_item.order_index < 0 OR v_item.order_index >= 6 THEN
      RAISE EXCEPTION 'Post image order index is invalid' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.post_media_staging (
      operation_id, owner_id, post_id, post_type, bucket, object_path, url,
      order_index, status
    )
    VALUES (
      p_operation_id, v_me, p_post_id, p_post_type, v_item.bucket,
      v_item.object_path, v_item.url, v_item.order_index, 'planned'
    )
    ON CONFLICT ON CONSTRAINT post_media_staging_operation_id_order_index_key
    DO UPDATE SET
      bucket = EXCLUDED.bucket,
      object_path = EXCLUDED.object_path,
      url = EXCLUDED.url,
      post_id = EXCLUDED.post_id,
      post_type = EXCLUDED.post_type,
      status = CASE
        WHEN public.post_media_staging.status = 'finalized' THEN 'finalized'
        ELSE 'planned'
      END;

    -- A prior failed attempt may have queued this deterministic path. Reusing
    -- it for a retry cancels that old cleanup obligation before upload.
    UPDATE public.post_media_cleanup_backlog cleanup
    SET
      status = 'resolved',
      reason = 'reused_by_retry',
      resolved_at = NOW(),
      last_error_code = NULL
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.order_index = v_item.order_index
      AND cleanup.source_staging_id = stage.id
      AND cleanup.owner_id = v_me;
  END LOOP;

  RETURN QUERY
  SELECT
    stage.id,
    stage.operation_id,
    stage.post_id,
    stage.bucket,
    stage.object_path,
    stage.url,
    stage.order_index,
    stage.status
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.status <> 'cleanup_pending'
  ORDER BY stage.order_index;
END;
$$;

COMMIT;
