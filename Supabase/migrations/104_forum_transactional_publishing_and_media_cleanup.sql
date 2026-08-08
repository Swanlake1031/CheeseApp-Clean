-- 104_forum_transactional_publishing_and_media_cleanup.sql
--
-- H2 Phase B:
-- - retain exact Storage identities for every new post image;
-- - stage upload identities before bytes are uploaded;
-- - publish Forum base/detail/image metadata in one transaction;
-- - keep Storage cleanup observable and retryable;
-- - preserve nullable identity columns for legacy URL-only rows.
--
-- This migration is intentionally additive. Older supported clients may keep
-- inserting URL-only post_images rows until the compatibility window closes.

BEGIN;

ALTER TABLE public.post_images
  ADD COLUMN IF NOT EXISTS bucket TEXT,
  ADD COLUMN IF NOT EXISTS object_path TEXT;

ALTER TABLE public.post_images
  DROP CONSTRAINT IF EXISTS post_images_storage_identity_pair_check;

ALTER TABLE public.post_images
  ADD CONSTRAINT post_images_storage_identity_pair_check
  CHECK (
    (bucket IS NULL AND object_path IS NULL)
    OR
    (
      NULLIF(BTRIM(bucket), '') IS NOT NULL
      AND NULLIF(BTRIM(object_path), '') IS NOT NULL
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS post_images_known_storage_object_idx
  ON public.post_images(bucket, object_path)
  WHERE bucket IS NOT NULL AND object_path IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.post_media_staging (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id UUID NOT NULL,
  owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id UUID NOT NULL,
  post_type TEXT NOT NULL CHECK (post_type IN ('forum', 'secondhand', 'rent')),
  bucket TEXT NOT NULL,
  object_path TEXT NOT NULL,
  url TEXT NOT NULL,
  order_index INTEGER NOT NULL CHECK (order_index >= 0 AND order_index < 20),
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'uploaded', 'finalized', 'cleanup_pending', 'cleaned')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finalized_at TIMESTAMPTZ,
  UNIQUE(operation_id, order_index),
  UNIQUE(bucket, object_path)
);

CREATE INDEX IF NOT EXISTS post_media_staging_owner_status_idx
  ON public.post_media_staging(owner_id, status, updated_at);

CREATE INDEX IF NOT EXISTS post_media_staging_post_idx
  ON public.post_media_staging(post_id, operation_id, order_index);

CREATE TABLE IF NOT EXISTS public.post_media_cleanup_backlog (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_image_id UUID,
  post_id UUID NOT NULL,
  source_staging_id UUID,
  bucket TEXT,
  object_path TEXT,
  stored_url TEXT NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('pending', 'unresolved', 'resolved')),
  reason TEXT NOT NULL,
  candidate_count INTEGER CHECK (candidate_count IS NULL OR candidate_count >= 0),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  CONSTRAINT post_media_cleanup_source_staging_key UNIQUE (source_staging_id),
  CONSTRAINT post_media_cleanup_source_image_key UNIQUE (post_image_id),
  CHECK (
    (status = 'unresolved' AND bucket IS NULL AND object_path IS NULL)
    OR
    (status IN ('pending', 'resolved') AND bucket IS NOT NULL AND object_path IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS post_media_cleanup_owner_status_idx
  ON public.post_media_cleanup_backlog(owner_id, status, created_at, id);

CREATE INDEX IF NOT EXISTS post_media_cleanup_post_idx
  ON public.post_media_cleanup_backlog(post_id, status, created_at, id);

-- Service-role-only audit output populated by the reconciliation tool. It has
-- no foreign keys so an unresolved cleanup obligation survives post deletion.
CREATE TABLE IF NOT EXISTS public.post_image_reconciliation_backlog (
  post_image_id UUID PRIMARY KEY,
  post_id UUID NOT NULL,
  stored_url TEXT NOT NULL,
  reconciliation_status TEXT NOT NULL
    CHECK (reconciliation_status IN ('matched', 'unresolved')),
  reason TEXT NOT NULL,
  candidate_count INTEGER NOT NULL CHECK (candidate_count >= 0),
  bucket TEXT,
  object_path TEXT,
  reconciled_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    (reconciliation_status = 'matched' AND bucket IS NOT NULL AND object_path IS NOT NULL)
    OR
    (reconciliation_status = 'unresolved' AND bucket IS NULL AND object_path IS NULL)
  )
);

ALTER TABLE public.post_media_staging ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_media_cleanup_backlog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_image_reconciliation_backlog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners can read their post media staging" ON public.post_media_staging;
CREATE POLICY "Owners can read their post media staging"
ON public.post_media_staging
FOR SELECT
TO authenticated
USING (owner_id = auth.uid());

DROP POLICY IF EXISTS "Owners can read their post media cleanup backlog"
  ON public.post_media_cleanup_backlog;
CREATE POLICY "Owners can read their post media cleanup backlog"
ON public.post_media_cleanup_backlog
FOR SELECT
TO authenticated
USING (owner_id = auth.uid());

REVOKE ALL ON TABLE
  public.post_media_staging,
  public.post_media_cleanup_backlog,
  public.post_image_reconciliation_backlog
FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE
  public.post_media_staging,
  public.post_media_cleanup_backlog
TO authenticated;

GRANT ALL ON TABLE
  public.post_media_staging,
  public.post_media_cleanup_backlog,
  public.post_image_reconciliation_backlog
TO service_role;

DROP TRIGGER IF EXISTS post_media_staging_set_updated_at
  ON public.post_media_staging;
CREATE TRIGGER post_media_staging_set_updated_at
BEFORE UPDATE ON public.post_media_staging
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS post_media_cleanup_backlog_set_updated_at
  ON public.post_media_cleanup_backlog;
CREATE TRIGGER post_media_cleanup_backlog_set_updated_at
BEFORE UPDATE ON public.post_media_cleanup_backlog
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS post_image_reconciliation_backlog_set_updated_at
  ON public.post_image_reconciliation_backlog;
CREATE TRIGGER post_image_reconciliation_backlog_set_updated_at
BEFORE UPDATE ON public.post_image_reconciliation_backlog
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

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

    UPDATE public.post_media_staging
    SET status = 'cleanup_pending'
    WHERE id = v_existing.id;
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

CREATE OR REPLACE FUNCTION public.mark_post_media_uploaded(
  p_operation_id UUID,
  p_order_index INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  UPDATE public.post_media_staging
  SET status = CASE WHEN status = 'finalized' THEN 'finalized' ELSE 'uploaded' END
  WHERE operation_id = p_operation_id
    AND order_index = p_order_index
    AND owner_id = v_me
    AND status IN ('planned', 'uploaded', 'finalized');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Media staging row not found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.abandon_post_media_operation(
  p_operation_id UUID,
  p_reason TEXT DEFAULT 'publish_failed'
)
RETURNS TABLE (
  cleanup_id UUID,
  bucket TEXT,
  object_path TEXT,
  stored_url TEXT,
  status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_stage RECORD;
  v_reason TEXT := CASE
    WHEN p_reason IN (
      'upload_failed',
      'publish_failed',
      'metadata_failed',
      'publication_failed',
      'cancelled'
    ) THEN p_reason
    ELSE 'publish_failed'
  END;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  FOR v_stage IN
    SELECT stage.*
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.status <> 'finalized'
  LOOP
    INSERT INTO public.post_media_cleanup_backlog (
      owner_id, post_id, source_staging_id, bucket, object_path, stored_url,
      status, reason
    )
    VALUES (
      v_me, v_stage.post_id, v_stage.id, v_stage.bucket,
      v_stage.object_path, v_stage.url, 'pending', v_reason
    )
    ON CONFLICT ON CONSTRAINT post_media_cleanup_source_staging_key
    DO UPDATE SET
      status = 'pending',
      reason = EXCLUDED.reason,
      resolved_at = NULL
    RETURNING id INTO cleanup_id;

    UPDATE public.post_media_staging
    SET status = 'cleanup_pending'
    WHERE id = v_stage.id;

    bucket := v_stage.bucket;
    object_path := v_stage.object_path;
    stored_url := v_stage.url;
    status := 'pending';
    RETURN NEXT;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_post_media_cleanup_attempt(
  p_cleanup_id UUID,
  p_succeeded BOOLEAN,
  p_error_code TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_stage_id UUID;
  v_error_code TEXT;
BEGIN
  v_error_code := CASE
    WHEN p_succeeded THEN NULL
    WHEN COALESCE(p_error_code, '') ~ '^[A-Za-z0-9_.:-]{1,120}$'
      THEN p_error_code
    ELSE 'storage_delete_failed'
  END;

  UPDATE public.post_media_cleanup_backlog
  SET
    status = CASE WHEN p_succeeded THEN 'resolved' ELSE 'pending' END,
    attempt_count = attempt_count + 1,
    last_error_code = v_error_code,
    resolved_at = CASE WHEN p_succeeded THEN NOW() ELSE NULL END
  WHERE id = p_cleanup_id
    AND owner_id = v_me
    AND status <> 'unresolved'
  RETURNING source_staging_id INTO v_stage_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cleanup obligation not found' USING ERRCODE = 'P0002';
  END IF;

  IF p_succeeded AND v_stage_id IS NOT NULL THEN
    UPDATE public.post_media_staging
    SET status = 'cleaned'
    WHERE id = v_stage_id
      AND owner_id = v_me
      AND status <> 'finalized';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_post_media_cleanup_backlog(
  p_post_id UUID DEFAULT NULL
)
RETURNS TABLE (
  cleanup_id UUID,
  post_image_id UUID,
  post_id UUID,
  bucket TEXT,
  object_path TEXT,
  stored_url TEXT,
  status TEXT,
  reason TEXT,
  candidate_count INTEGER,
  attempt_count INTEGER,
  last_error_code TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    cleanup.id,
    cleanup.post_image_id,
    cleanup.post_id,
    cleanup.bucket,
    cleanup.object_path,
    cleanup.stored_url,
    cleanup.status,
    cleanup.reason,
    cleanup.candidate_count,
    cleanup.attempt_count,
    cleanup.last_error_code,
    cleanup.created_at
  FROM public.post_media_cleanup_backlog cleanup
  WHERE cleanup.owner_id = auth.uid()
    AND cleanup.status <> 'resolved'
    AND (p_post_id IS NULL OR cleanup.post_id = p_post_id)
  ORDER BY cleanup.created_at, cleanup.id;
$$;

CREATE OR REPLACE FUNCTION public.get_forum_publish_status(
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
      FROM public.forum_posts forum
      WHERE forum.id = post.id
    )
  FROM public.posts post
  WHERE post.id = p_post_id
    AND post.user_id = auth.uid()
    AND post.type = 'forum';
$$;

CREATE OR REPLACE FUNCTION public.publish_forum_post(
  p_post_id UUID,
  p_operation_id UUID,
  p_board_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN DEFAULT FALSE,
  p_allow_comments BOOLEAN DEFAULT TRUE
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
  v_forum public.forum_posts%ROWTYPE;
  v_expected_media_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(BTRIM(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Forum post title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF NULLIF(BTRIM(p_description), '') IS NULL THEN
    RAISE EXCEPTION 'Forum post content cannot be empty' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
  FROM public.posts
  WHERE id = p_post_id;

  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_me
       OR v_existing.type IS DISTINCT FROM 'forum' THEN
      RAISE EXCEPTION 'Post identity is already in use' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_forum
    FROM public.forum_posts
    WHERE id = p_post_id;

    IF NOT FOUND
       OR v_existing.title IS DISTINCT FROM BTRIM(p_title)
       OR COALESCE(v_existing.description, '') IS DISTINCT FROM BTRIM(p_description)
       OR v_existing.is_anonymous IS DISTINCT FROM p_is_anonymous
       OR v_existing.is_private IS DISTINCT FROM p_is_private
       OR v_forum.board_id IS DISTINCT FROM p_board_id
       OR v_forum.allow_comments IS DISTINCT FROM p_allow_comments
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
      RAISE EXCEPTION 'Forum publish idempotency conflict' USING ERRCODE = '23505';
    END IF;

    RETURN p_post_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'forum'
      AND stage.status <> 'uploaded'
  ) THEN
    RAISE EXCEPTION 'Forum media upload is incomplete' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND (
        stage.owner_id IS DISTINCT FROM v_me
        OR stage.post_id IS DISTINCT FROM p_post_id
        OR stage.post_type IS DISTINCT FROM 'forum'
      )
  ) THEN
    RAISE EXCEPTION 'Forum media operation does not match the post'
      USING ERRCODE = '42501';
  END IF;

  SELECT profile.school_id INTO v_school_id
  FROM public.profiles profile
  WHERE profile.id = v_me;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'Profile has no school' USING ERRCODE = '23502';
  END IF;

  SELECT COUNT(*) INTO v_expected_media_count
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'forum'
    AND stage.status = 'uploaded';

  INSERT INTO public.posts (
    id, user_id, school_id, type, title, description, status,
    is_anonymous, is_private
  )
  VALUES (
    p_post_id, v_me, v_school_id, 'forum', BTRIM(p_title),
    NULLIF(BTRIM(p_description), ''), 'active', p_is_anonymous, p_is_private
  );

  INSERT INTO public.forum_posts (
    id, board_id, allow_comments
  )
  VALUES (
    p_post_id, p_board_id, p_allow_comments
  );

  INSERT INTO public.post_images (
    id, post_id, url, order_index, bucket, object_path
  )
  SELECT
    stage.id,
    p_post_id,
    stage.url,
    stage.order_index,
    stage.bucket,
    stage.object_path
  FROM public.post_media_staging stage
  WHERE stage.operation_id = p_operation_id
    AND stage.owner_id = v_me
    AND stage.post_id = p_post_id
    AND stage.post_type = 'forum'
    AND stage.status = 'uploaded'
  ORDER BY stage.order_index;

  IF (
    SELECT COUNT(*)
    FROM public.post_images image
    WHERE image.post_id = p_post_id
  ) IS DISTINCT FROM v_expected_media_count THEN
    RAISE EXCEPTION 'Forum image metadata finalization failed' USING ERRCODE = '23514';
  END IF;

  UPDATE public.post_media_staging
  SET status = 'finalized', finalized_at = NOW()
  WHERE operation_id = p_operation_id
    AND owner_id = v_me
    AND post_id = p_post_id
    AND post_type = 'forum'
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

CREATE OR REPLACE FUNCTION public.update_forum_post_with_media(
  p_post_id UUID,
  p_operation_id UUID,
  p_board_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_allow_comments BOOLEAN,
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
    RAISE EXCEPTION 'Forum post title cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.posts post
    WHERE post.id = p_post_id
      AND post.user_id = v_me
      AND post.type = 'forum'
  ) THEN
    RAISE EXCEPTION 'Forum post not found or not editable' USING ERRCODE = '42501';
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
    RAISE EXCEPTION 'Retained image does not belong to the Forum post'
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.operation_id = p_operation_id
      AND stage.owner_id = v_me
      AND stage.post_id = p_post_id
      AND stage.post_type = 'forum'
      AND stage.status NOT IN ('uploaded', 'finalized')
  ) THEN
    RAISE EXCEPTION 'Forum media upload is incomplete' USING ERRCODE = '23514';
  END IF;

  -- Preserve the existing trigger-safe update ordering.
  IF p_is_anonymous THEN
    UPDATE public.forum_posts
    SET board_id = p_board_id,
        allow_comments = p_allow_comments
    WHERE id = p_post_id;

    UPDATE public.posts
    SET title = BTRIM(p_title),
        description = NULLIF(BTRIM(p_description), ''),
        is_anonymous = TRUE,
        is_private = p_is_private
    WHERE id = p_post_id
      AND user_id = v_me
      AND type = 'forum';
  ELSE
    UPDATE public.posts
    SET title = BTRIM(p_title),
        description = NULLIF(BTRIM(p_description), ''),
        is_anonymous = FALSE,
        is_private = p_is_private
    WHERE id = p_post_id
      AND user_id = v_me
      AND type = 'forum';

    UPDATE public.forum_posts
    SET board_id = p_board_id,
        allow_comments = p_allow_comments
    WHERE id = p_post_id;
  END IF;

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
        v_image.url, 'pending', 'forum_image_removed'
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
    AND stage.post_type = 'forum'
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
    AND post_type = 'forum'
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

CREATE OR REPLACE FUNCTION public.delete_forum_post_with_media(
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
      AND post.type = 'forum'
  ) THEN
    -- Idempotent retry after database deletion may still need to drain cleanup.
    IF EXISTS (
      SELECT 1
      FROM public.post_media_cleanup_backlog cleanup
      WHERE cleanup.post_id = p_post_id
        AND cleanup.owner_id = v_me
    ) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Forum post not found or not deletable' USING ERRCODE = '42501';
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
        v_image.url, 'pending', 'forum_post_deleted'
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
    AND type = 'forum';
END;
$$;

REVOKE ALL ON FUNCTION public.prepare_post_media_operation(UUID, UUID, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_post_media_uploaded(UUID, INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.abandon_post_media_operation(UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_post_media_cleanup_attempt(UUID, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_post_media_cleanup_backlog(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_forum_publish_status(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.publish_forum_post(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_forum_post_with_media(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_forum_post_with_media(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.prepare_post_media_operation(UUID, UUID, TEXT, JSONB)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_post_media_uploaded(UUID, INTEGER)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.abandon_post_media_operation(UUID, TEXT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_post_media_cleanup_attempt(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_post_media_cleanup_backlog(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_forum_publish_status(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_forum_post(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_forum_post_with_media(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, UUID[]
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_forum_post_with_media(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
