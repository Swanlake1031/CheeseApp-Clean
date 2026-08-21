-- Forum posts require a title and a board. Body text is optional so image-only
-- and title-only posts use the same existing publication pipeline.

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
