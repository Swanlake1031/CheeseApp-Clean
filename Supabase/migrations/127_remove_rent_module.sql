-- 127_remove_rent_module.sql
--
-- DESTRUCTIVE FORWARD MIGRATION
-- Deleted data:
--   * every base post whose type is `rent` and all FK-dependent comments,
--     reactions, favorites, reports, images, mentions, and rent detail rows;
--   * rent-only staging rows, system-message payloads, and linked-card metadata;
--   * the rent table, view, indexes, triggers, RPCs, policies, and type allowance.
-- Media safety:
--   * exact bucket/object_path identities are queued for retryable deletion;
--   * URL-only legacy images are recorded as unresolved and are never parsed;
--   * cleanup obligations intentionally survive deletion of the post rows.
-- Rollback limits:
--   * the deleted product data cannot be reconstructed by a down migration;
--   * rollback requires a database backup plus a matching Storage snapshot.
-- Production order:
--   1. take and verify database + `post-images` Storage backups;
--   2. ship an app/worker version that no longer reads or writes Rent;
--   3. apply this migration once old clients are outside support;
--   4. drain exact cleanup rows and manually reconcile unresolved rows.

BEGIN;

CREATE TEMP TABLE retired_rent_post_ids (
  id UUID PRIMARY KEY,
  owner_id UUID NOT NULL
) ON COMMIT DROP;

INSERT INTO retired_rent_post_ids (id, owner_id)
SELECT post.id, post.user_id
FROM public.posts post
WHERE post.type = 'rent';

-- Preserve exact image deletion identities before post_images cascade away.
INSERT INTO public.post_media_cleanup_backlog (
  owner_id,
  post_image_id,
  post_id,
  bucket,
  object_path,
  stored_url,
  status,
  reason,
  candidate_count,
  next_attempt_at
)
SELECT
  retired.owner_id,
  image.id,
  image.post_id,
  image.bucket,
  image.object_path,
  image.url,
  CASE
    WHEN image.bucket IS NOT NULL AND image.object_path IS NOT NULL
      THEN 'pending'
    ELSE 'unresolved'
  END,
  CASE
    WHEN image.bucket IS NOT NULL AND image.object_path IS NOT NULL
      THEN 'rent_module_removed'
    ELSE 'rent_module_removed_legacy_identity_unknown'
  END,
  CASE
    WHEN image.bucket IS NULL OR image.object_path IS NULL THEN 0
    ELSE NULL
  END,
  NOW()
FROM public.post_images image
JOIN retired_rent_post_ids retired ON retired.id = image.post_id
ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
DO UPDATE SET
  status = EXCLUDED.status,
  reason = EXCLUDED.reason,
  bucket = EXCLUDED.bucket,
  object_path = EXCLUDED.object_path,
  stored_url = EXCLUDED.stored_url,
  candidate_count = EXCLUDED.candidate_count,
  next_attempt_at = EXCLUDED.next_attempt_at,
  resolved_at = NULL,
  locked_at = NULL,
  lock_token = NULL;

-- Preserve staged exact identities, including abandoned drafts that never made
-- a visible base post. Staging URLs are recorded, never parsed.
INSERT INTO public.post_media_cleanup_backlog (
  owner_id,
  post_id,
  source_staging_id,
  bucket,
  object_path,
  stored_url,
  status,
  reason,
  next_attempt_at
)
SELECT
  stage.owner_id,
  stage.post_id,
  stage.id,
  stage.bucket,
  stage.object_path,
  stage.url,
  'pending',
  'rent_module_removed_staged_asset',
  NOW()
FROM public.post_media_staging stage
WHERE stage.post_type = 'rent'
  AND stage.bucket IS NOT NULL
  AND stage.object_path IS NOT NULL
ON CONFLICT ON CONSTRAINT post_media_cleanup_source_staging_key
DO UPDATE SET
  status = 'pending',
  reason = EXCLUDED.reason,
  bucket = EXCLUDED.bucket,
  object_path = EXCLUDED.object_path,
  stored_url = EXCLUDED.stored_url,
  next_attempt_at = EXCLUDED.next_attempt_at,
  resolved_at = NULL,
  locked_at = NULL,
  lock_token = NULL;

-- Remove reusable Rent contact-card payloads without deleting the surrounding
-- user conversation or unrelated message text.
UPDATE public.messages
SET metadata = metadata - 'post_contact_card'
WHERE metadata -> 'post_contact_card' ->> 'post_kind' = 'rent';

UPDATE public.group_messages
SET metadata = metadata - 'post_contact_card'
WHERE metadata -> 'post_contact_card' ->> 'post_kind' = 'rent';

UPDATE public.conversations conversation
SET related_post_id = NULL,
    updated_at = NOW()
WHERE conversation.related_post_id IN (SELECT id FROM retired_rent_post_ids);

DELETE FROM public.system_messages message
WHERE message.content_kind = 'rent'
   OR message.post_id IN (SELECT id FROM retired_rent_post_ids);

DELETE FROM public.content_mentions mention
WHERE mention.content_kind = 'rent'
   OR mention.post_id IN (SELECT id FROM retired_rent_post_ids);

DELETE FROM public.post_media_staging stage
WHERE stage.post_type = 'rent';

-- FK cascades remove all ordinary child rows. Cleanup rows have no post FK and
-- intentionally remain observable after this deletion.
DELETE FROM public.posts post
WHERE post.id IN (SELECT id FROM retired_rent_post_ids);

-- Retire Rent-only API contracts before dropping their backing relations.
DO $drop_rent_functions$
DECLARE
  function_row RECORD;
BEGIN
  FOR function_row IN
    SELECT procedure.oid::regprocedure AS signature
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.proname IN (
        'create_rent_post',
        'delete_rent_post_with_media',
        'get_hot_rent_posts',
        'get_rent_posts_page',
        'get_rent_publish_status',
        'publish_rent_post',
        'publish_rent_post_with_mentions',
        'sync_rent_anchor_distance_only',
        'sync_rent_post_geo_mirror',
        'update_rent_post_with_media'
      )
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', function_row.signature);
  END LOOP;
END;
$drop_rent_functions$;

DROP VIEW IF EXISTS public.rent_posts_view CASCADE;
DROP TABLE IF EXISTS public.rent_posts CASCADE;

-- Rent is no longer a valid product identity anywhere in the active schema.
ALTER TABLE public.posts
  DROP CONSTRAINT IF EXISTS posts_type_allowed_check;
ALTER TABLE public.posts
  ADD CONSTRAINT posts_type_allowed_check
  CHECK (type IN ('secondhand', 'forum'));

ALTER TABLE public.post_media_staging
  DROP CONSTRAINT IF EXISTS post_media_staging_post_type_check;
ALTER TABLE public.post_media_staging
  ADD CONSTRAINT post_media_staging_post_type_check
  CHECK (post_type IN ('forum', 'secondhand'));

ALTER TABLE public.content_mentions
  DROP CONSTRAINT IF EXISTS content_mentions_content_kind_check;
ALTER TABLE public.content_mentions
  ADD CONSTRAINT content_mentions_content_kind_check
  CHECK (content_kind IN ('forum', 'secondhand', 'comment'));

ALTER TABLE public.system_messages
  DROP CONSTRAINT IF EXISTS system_messages_content_kind_check;
ALTER TABLE public.system_messages
  ADD CONSTRAINT system_messages_content_kind_check
  CHECK (
    content_kind IS NULL
    OR content_kind IN ('forum', 'secondhand', 'comment', 'profile')
  );

CREATE OR REPLACE VIEW public.geo_feed_posts_v1
WITH (security_invoker = TRUE)
AS
SELECT
  post.id AS post_id,
  post.user_id AS author_id,
  post.type AS module,
  post.school_id,
  post.geo,
  post.title,
  post.description,
  post.status,
  post.created_at,
  detail.highlight_type,
  detail.pinned_until,
  profile.full_name AS author_name,
  school.name AS school_name,
  (
    SELECT image.url
    FROM public.post_images image
    WHERE image.post_id = post.id
    ORDER BY image.order_index, image.created_at, image.id
    LIMIT 1
  ) AS image_url
FROM public.posts post
JOIN public.secondhand_posts detail ON detail.id = post.id
JOIN public.profile_public_view profile ON profile.id = post.user_id
JOIN public.schools school ON school.id = post.school_id
WHERE post.type = 'secondhand'
  AND post.status = 'active'
  AND post.is_private = FALSE;

GRANT SELECT ON public.geo_feed_posts_v1 TO authenticated, service_role;

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
    RAISE EXCEPTION 'Media operation and post IDs are required'
      USING ERRCODE = '22004';
  END IF;
  IF p_post_type NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'Unsupported post type' USING ERRCODE = '22023';
  END IF;
  IF p_media IS NULL OR jsonb_typeof(p_media) <> 'array' THEN
    RAISE EXCEPTION 'Media payload must be an array'
      USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(p_media);
  IF v_count > 6 THEN
    RAISE EXCEPTION 'At most six post images are supported'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.posts post
    WHERE post.id = p_post_id
      AND (
        post.user_id IS DISTINCT FROM v_me
        OR post.type IS DISTINCT FROM p_post_type
      )
  ) THEN
    RAISE EXCEPTION 'Post identity is already in use'
      USING ERRCODE = '23505';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_media)
      AS media(bucket TEXT, object_path TEXT, url TEXT, order_index INTEGER)
    GROUP BY media.order_index
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Media order indexes must be unique'
      USING ERRCODE = '23505';
  END IF;

  v_prefix :=
    LOWER(v_me::TEXT) || '/posts/' || LOWER(p_post_id::TEXT) || '/'
    || LOWER(p_operation_id::TEXT) || '/';

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
      owner_id,
      post_id,
      source_staging_id,
      bucket,
      object_path,
      stored_url,
      status,
      reason
    ) VALUES (
      v_me,
      p_post_id,
      v_existing.id,
      v_existing.bucket,
      v_existing.object_path,
      v_existing.url,
      'pending',
      'publish_selection_changed'
    )
    ON CONFLICT ON CONSTRAINT post_media_cleanup_source_staging_key
    DO UPDATE SET
      status = 'pending',
      reason = EXCLUDED.reason,
      resolved_at = NULL;

    UPDATE public.post_media_staging stage
    SET status = 'cleanup_pending'
    WHERE stage.id = v_existing.id;
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
       OR v_item.object_path NOT LIKE v_prefix || '%'
    THEN
      RAISE EXCEPTION
        'Post image path is outside the authenticated operation prefix'
        USING ERRCODE = '42501';
    END IF;
    IF NULLIF(BTRIM(v_item.url), '') IS NULL THEN
      RAISE EXCEPTION 'Post image URL is required' USING ERRCODE = '22023';
    END IF;
    IF v_item.order_index IS NULL
       OR v_item.order_index < 0
       OR v_item.order_index >= 6
    THEN
      RAISE EXCEPTION 'Post image order index is invalid'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.post_media_staging (
      operation_id,
      owner_id,
      post_id,
      post_type,
      bucket,
      object_path,
      url,
      order_index,
      status
    ) VALUES (
      p_operation_id,
      v_me,
      p_post_id,
      p_post_type,
      v_item.bucket,
      v_item.object_path,
      v_item.url,
      v_item.order_index,
      'planned'
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

REVOKE ALL ON FUNCTION public.prepare_post_media_operation(UUID, UUID, TEXT, JSONB)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prepare_post_media_operation(UUID, UUID, TEXT, JSONB)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.has_sent_post_linked_card(
  p_conversation_id UUID,
  p_post_kind TEXT,
  p_post_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_post_kind NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'unsupported post kind' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.conversations conversation
    WHERE conversation.id = p_conversation_id
      AND v_user_id IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.messages message
    WHERE message.conversation_id = p_conversation_id
      AND message.sender_id = v_user_id
      AND message.is_deleted = FALSE
      AND message.metadata -> 'post_contact_card' ->> 'post_kind' = p_post_kind
      AND message.metadata -> 'post_contact_card' ->> 'post_id' = p_post_id::TEXT
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.sync_content_mentions(
  p_content_kind TEXT,
  p_post_id UUID,
  p_comment_id UUID DEFAULT NULL,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_kind TEXT := LOWER(BTRIM(COALESCE(p_content_kind, '')));
  v_post public.posts%ROWTYPE;
  v_comment public.comments%ROWTYPE;
  v_is_anonymous BOOLEAN := FALSE;
  v_inserted INTEGER := 0;
  v_target UUID;
  v_actor_name TEXT;
  v_event_id TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_kind NOT IN ('forum', 'secondhand', 'comment') THEN
    RAISE EXCEPTION 'Unsupported mention content kind'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(cardinality(p_mentioned_user_ids), 0) > 10 THEN
    RAISE EXCEPTION 'At most 10 users can be mentioned'
      USING ERRCODE = '22023';
  END IF;

  SELECT post.*
  INTO v_post
  FROM public.posts post
  WHERE post.id = p_post_id
    AND post.type IN ('forum', 'secondhand')
    AND post.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mentioned content is unavailable'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_kind = 'comment' THEN
    IF p_comment_id IS NULL THEN
      RAISE EXCEPTION 'Comment ID is required' USING ERRCODE = '22023';
    END IF;

    SELECT comment.*
    INTO v_comment
    FROM public.comments comment
    WHERE comment.id = p_comment_id
      AND comment.post_id = p_post_id
      AND comment.is_deleted = FALSE;

    IF NOT FOUND OR v_comment.user_id IS DISTINCT FROM v_me THEN
      RAISE EXCEPTION 'Only the comment author can set mentions'
        USING ERRCODE = '42501';
    END IF;
    v_is_anonymous := COALESCE(v_comment.is_anonymous, FALSE);
  ELSE
    IF p_comment_id IS NOT NULL
       OR v_post.type IS DISTINCT FROM v_kind
       OR v_post.user_id IS DISTINCT FROM v_me
    THEN
      RAISE EXCEPTION 'Only the content author can set mentions'
        USING ERRCODE = '42501';
    END IF;
    v_is_anonymous := COALESCE(v_post.is_anonymous, FALSE);
  END IF;

  DELETE FROM public.content_mentions mention
  WHERE mention.content_kind = v_kind
    AND mention.post_id = p_post_id
    AND mention.comment_id IS NOT DISTINCT FROM p_comment_id
    AND mention.actor_user_id = v_me
    AND NOT (
      mention.mentioned_user_id = ANY(
        COALESCE(p_mentioned_user_ids, ARRAY[]::UUID[])
      )
    );

  IF v_post.is_private THEN
    DELETE FROM public.content_mentions mention
    WHERE mention.content_kind = v_kind
      AND mention.post_id = p_post_id
      AND mention.comment_id IS NOT DISTINCT FROM p_comment_id
      AND mention.actor_user_id = v_me;
    RETURN 0;
  END IF;

  SELECT COALESCE(NULLIF(BTRIM(profile.full_name), ''), '有人')
  INTO v_actor_name
  FROM public.profiles profile
  WHERE profile.id = v_me;

  FOR v_target IN
    SELECT DISTINCT target_id
    FROM unnest(COALESCE(p_mentioned_user_ids, ARRAY[]::UUID[])) target(target_id)
    WHERE target_id IS NOT NULL
      AND target_id <> v_me
    ORDER BY target_id
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles profile WHERE profile.id = v_target
    ) OR EXISTS (
      SELECT 1
      FROM public.user_blocks block
      WHERE (block.blocker_id = v_me AND block.blocked_id = v_target)
         OR (block.blocker_id = v_target AND block.blocked_id = v_me)
    ) THEN
      CONTINUE;
    END IF;

    INSERT INTO public.content_mentions (
      content_kind,
      post_id,
      comment_id,
      actor_user_id,
      mentioned_user_id
    ) VALUES (
      v_kind,
      p_post_id,
      p_comment_id,
      v_me,
      v_target
    )
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_inserted := v_inserted + 1;
    v_event_id := format(
      'mention:%s:%s:%s',
      v_kind,
      COALESCE(p_comment_id, p_post_id),
      v_target
    );

    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_target,
      p_event_id := v_event_id,
      p_kind := 'mention',
      p_title := '有人提到了你',
      p_body := CASE
        WHEN v_is_anonymous THEN format(
          '匿名用户在「%s」中提到了你',
          COALESCE(NULLIF(LEFT(BTRIM(v_post.title), 60), ''), '一则内容')
        )
        ELSE format(
          '%s 在「%s」中提到了你',
          COALESCE(v_actor_name, '有人'),
          COALESCE(NULLIF(LEFT(BTRIM(v_post.title), 60), ''), '一则内容')
        )
      END,
      p_actor_user_id := v_me,
      p_post_id := p_post_id,
      p_comment_id := p_comment_id,
      p_content_kind := CASE
        WHEN v_kind = 'comment' THEN 'comment'
        ELSE v_kind
      END,
      p_cta_kind := 'view_post',
      p_hide_actor := v_is_anonymous
    );
  END LOOP;

  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_content_mentions(TEXT, UUID, UUID, UUID[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_content_mentions(TEXT, UUID, UUID, UUID[])
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.sync_post_metrics(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_type TEXT;
  v_created_at TIMESTAMPTZ;
  v_view_count INTEGER;
  v_like_count INTEGER;
  v_comment_count INTEGER;
  v_save_count INTEGER;
  v_hot_score DOUBLE PRECISION;
BEGIN
  SELECT post.type, post.created_at, COALESCE(post.view_count, 0)
  INTO v_type, v_created_at, v_view_count
  FROM public.posts post
  WHERE post.id = p_post_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::INTEGER INTO v_like_count
  FROM public.likes liked
  WHERE liked.target_type = 'post' AND liked.target_id = p_post_id;

  SELECT COUNT(*)::INTEGER INTO v_comment_count
  FROM public.comments comment
  WHERE comment.post_id = p_post_id AND comment.is_deleted = FALSE;

  SELECT COUNT(*)::INTEGER INTO v_save_count
  FROM public.favorites favorite
  WHERE favorite.post_id = p_post_id;

  v_hot_score := public.calculate_hot_score(
    v_view_count,
    v_like_count,
    v_comment_count,
    v_save_count,
    v_created_at
  );

  IF v_type = 'secondhand' THEN
    UPDATE public.secondhand_posts detail
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN detail.highlight_type IN (
            'pinned'::public.post_highlight_type,
            'urgent'::public.post_highlight_type
          )
          AND detail.pinned_until IS NOT NULL
          AND detail.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE detail.highlight_type
        END
    WHERE detail.id = p_post_id;
  ELSIF v_type = 'forum' THEN
    UPDATE public.forum_posts detail
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN detail.highlight_type IN (
            'pinned'::public.post_highlight_type,
            'urgent'::public.post_highlight_type
          )
          AND detail.pinned_until IS NOT NULL
          AND detail.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE detail.highlight_type
        END
    WHERE detail.id = p_post_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_expired_highlights()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_total INTEGER := 0;
  v_affected INTEGER := 0;
BEGIN
  UPDATE public.secondhand_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN (
    'pinned'::public.post_highlight_type,
    'urgent'::public.post_highlight_type
  )
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.forum_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN (
    'pinned'::public.post_highlight_type,
    'urgent'::public.post_highlight_type
  )
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;

  RETURN v_total + v_affected;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_all_post_metrics()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  post_row RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR post_row IN
    SELECT post.id
    FROM public.posts post
    WHERE post.type IN ('secondhand', 'forum')
  LOOP
    PERFORM public.sync_post_metrics(post_row.id);
    v_count := v_count + 1;
  END LOOP;

  PERFORM public.normalize_expired_highlights();
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_post_metrics(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.normalize_expired_highlights() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_all_post_metrics() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_post_metrics(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.normalize_expired_highlights() TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_all_post_metrics() TO service_role;

CREATE OR REPLACE FUNCTION public.get_my_favorite_posts(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  post_id UUID,
  post_type TEXT,
  title TEXT,
  description TEXT,
  price NUMERIC,
  subtitle TEXT,
  cover_image TEXT,
  saved_at TIMESTAMPTZ,
  author_id UUID,
  author_name TEXT,
  author_avatar TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    post.id,
    post.type,
    post.title,
    post.description,
    market.price,
    COALESCE(market.condition, ''),
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = post.id
      ORDER BY image.order_index, image.id
      LIMIT 1
    ),
    favorite.created_at,
    post.user_id,
    COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户'),
    profile.avatar_url
  FROM public.favorites favorite
  JOIN public.posts post ON post.id = favorite.post_id
  JOIN public.profiles profile ON profile.id = post.user_id
  JOIN public.secondhand_posts market ON market.id = post.id
  WHERE auth.uid() IS NOT NULL
    AND favorite.user_id = auth.uid()
    AND post.type = 'secondhand'
    AND post.status = 'active'
    AND post.is_private = FALSE
    AND NOT public.is_user_blocked(auth.uid(), post.user_id)
  ORDER BY favorite.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 300));
$$;

REVOKE ALL ON FUNCTION public.get_my_favorite_posts(INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_favorite_posts(INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_my_profile_activity_page(
  p_activity_kind TEXT,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 30
)
RETURNS TABLE (
  activity_id UUID,
  post_id UUID,
  post_type TEXT,
  post_title TEXT,
  post_summary TEXT,
  activity_summary TEXT,
  comment_id UUID,
  activity_created_at TIMESTAMPTZ,
  price NUMERIC,
  cover_image TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_kind TEXT := lower(btrim(COALESCE(p_activity_kind, '')));
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF v_kind NOT IN ('published', 'liked', 'commented', 'favorited') THEN
    RAISE EXCEPTION 'Unsupported profile activity kind' USING ERRCODE = '22023';
  END IF;

  IF (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Both cursor fields must be supplied together'
      USING ERRCODE = '22023';
  END IF;

  IF v_kind = 'published' THEN
    RETURN QUERY
    SELECT
      post.id,
      post.id,
      post.type,
      post.title,
      COALESCE(post.description, ''),
      COALESCE(post.description, ''),
      NULL::UUID,
      post.created_at,
      market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.posts post
    LEFT JOIN public.secondhand_posts market ON market.id = post.id
    WHERE post.user_id = v_me
      AND post.type IN ('forum', 'secondhand')
      AND post.status <> 'deleted'
      AND (
        p_before_created_at IS NULL
        OR (post.created_at, post.id) < (p_before_created_at, p_before_id)
      )
    ORDER BY post.created_at DESC, post.id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'liked' THEN
    RETURN QUERY
    SELECT
      liked.target_id,
      post.id,
      post.type,
      post.title,
      COALESCE(post.description, ''),
      COALESCE(post.description, ''),
      NULL::UUID,
      liked.created_at,
      market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.likes liked
    JOIN public.posts post ON post.id = liked.target_id
    LEFT JOIN public.secondhand_posts market ON market.id = post.id
    WHERE liked.user_id = v_me
      AND liked.target_type = 'post'
      AND post.type IN ('forum', 'secondhand')
      AND public.can_view_post(post.id)
      AND (
        p_before_created_at IS NULL
        OR (liked.created_at, liked.target_id) < (p_before_created_at, p_before_id)
      )
    ORDER BY liked.created_at DESC, liked.target_id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  IF v_kind = 'commented' THEN
    RETURN QUERY
    SELECT
      comment.id,
      post.id,
      post.type,
      post.title,
      COALESCE(post.description, ''),
      comment.content,
      comment.id,
      comment.created_at,
      market.price,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = post.id
        ORDER BY image.order_index, image.id LIMIT 1
      )
    FROM public.comments comment
    JOIN public.posts post ON post.id = comment.post_id
    LEFT JOIN public.secondhand_posts market ON market.id = post.id
    WHERE comment.user_id = v_me
      AND comment.is_deleted = FALSE
      AND post.type IN ('forum', 'secondhand')
      AND public.can_view_post(post.id)
      AND (
        p_before_created_at IS NULL
        OR (comment.created_at, comment.id) < (p_before_created_at, p_before_id)
      )
    ORDER BY comment.created_at DESC, comment.id DESC
    LIMIT v_limit;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    favorite.post_id,
    post.id,
    post.type,
    post.title,
    COALESCE(post.description, ''),
    COALESCE(post.description, ''),
    NULL::UUID,
    favorite.created_at,
    market.price,
    (
      SELECT image.url FROM public.post_images image
      WHERE image.post_id = post.id
      ORDER BY image.order_index, image.id LIMIT 1
    )
  FROM public.favorites favorite
  JOIN public.posts post ON post.id = favorite.post_id
  LEFT JOIN public.secondhand_posts market ON market.id = post.id
  WHERE favorite.user_id = v_me
    AND post.type IN ('forum', 'secondhand')
    AND public.can_view_post(post.id)
    AND (
      p_before_created_at IS NULL
      OR (favorite.created_at, favorite.post_id)
        < (p_before_created_at, p_before_id)
    )
  ORDER BY favorite.created_at DESC, favorite.post_id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_profile_activity_page(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;

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
SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH input AS (
    SELECT
      LOWER(COALESCE(NULLIF(BTRIM(p_query), ''), '')) AS query_text,
      LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all')) AS category_key,
      GREATEST(1, LEAST(COALESCE(p_limit, 80), 200)) AS result_limit
  ),
  secondhand_results AS (
    SELECT
      item.id,
      'market'::TEXT AS category,
      item.title,
      ('$' || TRIM(TO_CHAR(item.price, 'FM999999990.00')) || ' - '
        || COALESCE(item.condition, ''))::TEXT AS subtitle,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = item.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      item.created_at,
      COALESCE(item.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(item.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(item.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.secondhand_posts_view item
    CROSS JOIN input
    WHERE input.category_key IN ('all', 'market')
      AND (
        input.query_text = ''
        OR (
          COALESCE(item.title, '') || ' ' || COALESCE(item.category, '') || ' '
          || COALESCE(item.condition, '')
        ) ILIKE '%' || input.query_text || '%'
      )
  ),
  forum_results AS (
    SELECT
      forum.id,
      'forum'::TEXT AS category,
      forum.title,
      COALESCE(NULLIF(forum.description, ''), forum.board_name)::TEXT AS subtitle,
      (
        SELECT image.url FROM public.post_images image
        WHERE image.post_id = forum.id
        ORDER BY image.order_index ASC NULLS LAST, image.created_at ASC
        LIMIT 1
      ) AS preview_image_url,
      forum.created_at,
      COALESCE(forum.hot_score, 0)::DOUBLE PRECISION AS hot_score,
      COALESCE(forum.highlight_type, 'normal')::TEXT AS highlight_type,
      COALESCE(forum.highlight_rank, 2)::INTEGER AS highlight_rank
    FROM public.forum_posts_view forum
    CROSS JOIN input
    WHERE input.category_key IN ('all', 'forum')
      AND (
        input.query_text = ''
        OR (
          COALESCE(forum.title, '') || ' ' || COALESCE(forum.description, '')
          || ' ' || forum.board_name
        ) ILIKE '%' || input.query_text || '%'
      )
  ),
  combined AS (
    SELECT * FROM secondhand_results
    UNION ALL
    SELECT * FROM forum_results
  )
  SELECT
    result.id,
    result.category,
    result.title,
    result.subtitle,
    result.preview_image_url,
    result.created_at,
    result.hot_score,
    result.highlight_type,
    result.highlight_rank
  FROM combined result
  CROSS JOIN input
  WHERE input.category_key IN ('all', 'market', 'forum')
  ORDER BY result.highlight_rank, result.hot_score DESC, result.created_at DESC NULLS LAST
  LIMIT (SELECT result_limit FROM input);
$$;

REVOKE ALL ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts(TEXT, TEXT, INTEGER)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.search_posts_page(
  p_query TEXT,
  p_category TEXT DEFAULT 'all',
  p_after_rank_score DOUBLE PRECISION DEFAULT NULL,
  p_after_created_at TIMESTAMPTZ DEFAULT NULL,
  p_after_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 24
)
RETURNS TABLE (
  id UUID,
  category TEXT,
  title TEXT,
  subtitle TEXT,
  preview_image_url TEXT,
  created_at TIMESTAMPTZ,
  hot_score DOUBLE PRECISION,
  rank_score DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
  v_query TEXT := LOWER(COALESCE(BTRIM(p_query), ''));
  v_category TEXT := LOWER(COALESCE(NULLIF(BTRIM(p_category), ''), 'all'));
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF v_category NOT IN ('all', 'market', 'forum') THEN
    RAISE EXCEPTION 'unsupported search category' USING ERRCODE = '22023';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 50' USING ERRCODE = '22023';
  END IF;

  IF (
    (p_after_rank_score IS NULL)::INTEGER
    + (p_after_created_at IS NULL)::INTEGER
    + (p_after_id IS NULL)::INTEGER
  ) NOT IN (0, 3) THEN
    RAISE EXCEPTION 'search cursor must be complete' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH input AS (
    SELECT
      v_query AS query_text,
      CASE WHEN v_query = '' THEN NULL ELSE plainto_tsquery('simple', v_query) END
        AS text_query
  ),
  candidates AS (
    SELECT
      post.id,
      'market'::TEXT AS category,
      post.title,
      (
        '$' || TRIM(TO_CHAR(market.price, 'FM999999990.00')) || ' - '
        || COALESCE(market.condition, '')
      )::TEXT AS subtitle,
      post.created_at,
      public.calculate_hot_score(
        market.view_count,
        market.like_count,
        market.comment_count,
        market.save_count,
        post.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN market.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN market.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        AS shared_document,
      (
        COALESCE(market.category, '') || ' '
        || COALESCE(market.condition, '') || ' '
        || COALESCE(market.pickup_location, '')
      ) AS feature_document
    FROM public.posts post
    JOIN public.secondhand_posts market ON market.id = post.id
    JOIN public.profile_public_view profile ON profile.id = post.user_id
    CROSS JOIN input
    WHERE v_category IN ('all', 'market')
      AND post.type = 'secondhand'
      AND post.status = 'active'
      AND post.is_private = FALSE
      AND (market.expires_at IS NULL OR market.expires_at > NOW())
      AND (
        input.query_text = ''
        OR to_tsvector(
          'simple', COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        ) @@ input.text_query
        OR (COALESCE(post.title, '') || ' ' || COALESCE(post.description, ''))
          ILIKE '%' || input.query_text || '%'
        OR (
          COALESCE(market.category, '') || ' '
          || COALESCE(market.condition, '') || ' '
          || COALESCE(market.pickup_location, '')
        ) ILIKE '%' || input.query_text || '%'
      )

    UNION ALL

    SELECT
      post.id,
      'forum'::TEXT AS category,
      post.title,
      COALESCE(NULLIF(post.description, ''), board.name)::TEXT AS subtitle,
      post.created_at,
      public.calculate_hot_score(
        forum.view_count,
        forum.like_count,
        forum.comment_count,
        forum.save_count,
        post.created_at
      )::DOUBLE PRECISION AS hot_score,
      CASE
        WHEN forum.highlight_type = 'pinned'::public.post_highlight_type THEN 0
        WHEN forum.highlight_type IN (
          'urgent'::public.post_highlight_type,
          'breaking'::public.post_highlight_type
        ) THEN 1
        ELSE 2
      END AS highlight_rank,
      COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        AS shared_document,
      COALESCE(board.name, '') AS feature_document
    FROM public.posts post
    JOIN public.forum_posts forum ON forum.id = post.id
    JOIN public.forum_boards board ON board.id = forum.board_id
    JOIN public.profile_public_view profile ON profile.id = post.user_id
    CROSS JOIN input
    WHERE v_category IN ('all', 'forum')
      AND post.type = 'forum'
      AND post.status = 'active'
      AND post.is_private = FALSE
      AND (
        input.query_text = ''
        OR to_tsvector(
          'simple', COALESCE(post.title, '') || ' ' || COALESCE(post.description, '')
        ) @@ input.text_query
        OR (COALESCE(post.title, '') || ' ' || COALESCE(post.description, ''))
          ILIKE '%' || input.query_text || '%'
        OR COALESCE(board.name, '') ILIKE '%' || input.query_text || '%'
      )
  ),
  ranked AS (
    SELECT
      candidate.*,
      CASE
        WHEN input.query_text = '' THEN
          ((2 - candidate.highlight_rank) * 1000000 + candidate.hot_score)
            ::DOUBLE PRECISION
        ELSE
          (
            CASE WHEN LOWER(candidate.title) = input.query_text THEN 100 ELSE 0 END
            + CASE WHEN LOWER(candidate.title) LIKE input.query_text || '%' THEN 20 ELSE 0 END
            + 10 * ts_rank_cd(
              to_tsvector('simple', candidate.shared_document), input.text_query
            )
            + 5 * GREATEST(
              similarity(LOWER(candidate.title), input.query_text),
              similarity(LOWER(candidate.shared_document), input.query_text),
              similarity(LOWER(candidate.feature_document), input.query_text)
            )
            + LEAST(candidate.hot_score, 10000) * 0.000001
          )::DOUBLE PRECISION
      END AS rank_score
    FROM candidates candidate
    CROSS JOIN input
  )
  SELECT
    ranked.id,
    ranked.category,
    ranked.title,
    ranked.subtitle,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = ranked.id
      ORDER BY image.order_index ASC NULLS LAST, image.created_at, image.id
      LIMIT 1
    ),
    ranked.created_at,
    ranked.hot_score,
    ranked.rank_score
  FROM ranked
  WHERE p_after_rank_score IS NULL
    OR ranked.rank_score < p_after_rank_score
    OR (
      ranked.rank_score = p_after_rank_score
      AND ranked.created_at < p_after_created_at
    )
    OR (
      ranked.rank_score = p_after_rank_score
      AND ranked.created_at = p_after_created_at
      AND ranked.id < p_after_id
    )
  ORDER BY ranked.rank_score DESC, ranked.created_at DESC, ranked.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_search_post_counts()
RETURNS TABLE (category TEXT, total_count BIGINT)
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT 'market'::TEXT, COUNT(*)::BIGINT
  FROM public.posts post
  JOIN public.secondhand_posts market ON market.id = post.id
  JOIN public.profile_public_view profile ON profile.id = post.user_id
  WHERE post.type = 'secondhand'
    AND post.status = 'active'
    AND post.is_private = FALSE
    AND (market.expires_at IS NULL OR market.expires_at > NOW())

  UNION ALL

  SELECT 'forum'::TEXT, COUNT(*)::BIGINT
  FROM public.posts post
  JOIN public.forum_posts forum ON forum.id = post.id
  JOIN public.profile_public_view profile ON profile.id = post.user_id
  WHERE post.type = 'forum'
    AND post.status = 'active'
    AND post.is_private = FALSE;
$$;

REVOKE ALL ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_search_post_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_posts_page(
  TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_search_post_counts()
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.c1_internal_get_geo_feed(
  p_viewer_user_id UUID,
  p_module TEXT,
  p_page_size INTEGER DEFAULT 20,
  p_cursor JSONB DEFAULT NULL,
  p_anchor_lat DOUBLE PRECISION DEFAULT NULL,
  p_anchor_lng DOUBLE PRECISION DEFAULT NULL,
  p_nearby_radius_km DOUBLE PRECISION DEFAULT NULL,
  p_pinned_local_radius_km DOUBLE PRECISION DEFAULT 25,
  p_pinned_slots INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
SET row_security = on
AS $$
DECLARE
  v_module TEXT := lower(COALESCE(p_module, ''));
  v_page_size INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 20), 50));
  v_viewer_school_id UUID;
  v_viewer_campus_id UUID;
  v_profile_geo extensions.geography;
  v_sort_anchor extensions.geography;
  v_school_anchor extensions.geography;
  v_nearby_radius_km DOUBLE PRECISION;
  v_nearby_radius_m DOUBLE PRECISION;
  v_cursor_layer INTEGER;
  v_cursor_distance_key BIGINT;
  v_cursor_created_at TIMESTAMPTZ;
  v_cursor_id UUID;
  v_pinned_local JSONB := '[]'::JSONB;
  v_pinned_more JSONB := '[]'::JSONB;
  v_organic JSONB := '[]'::JSONB;
  v_next_cursor JSONB;
BEGIN
  IF v_module <> 'secondhand' THEN
    RAISE EXCEPTION 'Unsupported module: %', p_module USING ERRCODE = '22023';
  END IF;

  SELECT profile.school_id, profile.campus_id, profile.last_known_geo
  INTO v_viewer_school_id, v_viewer_campus_id, v_profile_geo
  FROM public.profiles profile
  WHERE profile.id = p_viewer_user_id;

  IF v_viewer_school_id IS NULL THEN
    RAISE EXCEPTION 'viewer profile has no school_id' USING ERRCODE = '22023';
  END IF;

  IF p_anchor_lat IS NOT NULL AND p_anchor_lng IS NOT NULL THEN
    v_sort_anchor := extensions.ST_SetSRID(
      extensions.ST_MakePoint(p_anchor_lng, p_anchor_lat), 4326
    )::extensions.geography;
  ELSIF v_profile_geo IS NOT NULL THEN
    v_sort_anchor := v_profile_geo;
  END IF;

  IF v_viewer_campus_id IS NOT NULL THEN
    SELECT campus.geo INTO v_school_anchor
    FROM public.school_campuses campus
    WHERE campus.id = v_viewer_campus_id
    LIMIT 1;
  END IF;

  IF v_school_anchor IS NULL THEN
    SELECT campus.geo INTO v_school_anchor
    FROM public.school_campuses campus
    WHERE campus.school_id = v_viewer_school_id
      AND campus.is_default = TRUE
    LIMIT 1;
  END IF;

  SELECT COALESCE(p_nearby_radius_km, school.default_radius_km, 25)
  INTO v_nearby_radius_km
  FROM public.schools school
  WHERE school.id = v_viewer_school_id;

  v_nearby_radius_km := COALESCE(v_nearby_radius_km, 25);
  v_nearby_radius_m := v_nearby_radius_km * 1000.0;
  v_cursor_layer := (p_cursor ->> 'layer')::INTEGER;
  v_cursor_distance_key := COALESCE(
    (p_cursor ->> 'distance_sort_key')::BIGINT,
    ROUND((p_cursor ->> 'distance_sort')::DOUBLE PRECISION)::BIGINT
  );
  v_cursor_created_at := (p_cursor ->> 'created_at')::TIMESTAMPTZ;
  v_cursor_id := (p_cursor ->> 'id')::UUID;

  WITH base AS (
    SELECT
      feed.post_id,
      feed.author_id,
      feed.module,
      feed.school_id,
      feed.title,
      feed.description,
      feed.created_at,
      feed.highlight_type,
      feed.pinned_until,
      feed.author_name,
      feed.school_name,
      feed.image_url,
      COALESCE(feed.geo, campus.geo) AS effective_geo,
      campus.geo AS school_geo,
      COALESCE(market.view_count, 0)::DOUBLE PRECISION AS view_count
    FROM public.geo_feed_posts_v1 feed
    JOIN public.secondhand_posts market ON market.id = feed.post_id
    LEFT JOIN public.school_campuses campus
      ON campus.school_id = feed.school_id AND campus.is_default = TRUE
    WHERE feed.module = 'secondhand'
      AND feed.status = 'active'
      AND (market.expires_at IS NULL OR market.expires_at > NOW())
  ),
  scored AS (
    SELECT
      base.*,
      CASE
        WHEN base.school_id = v_viewer_school_id THEN 1
        WHEN base.school_geo IS NOT NULL
          AND v_school_anchor IS NOT NULL
          AND extensions.ST_DWithin(base.school_geo, v_school_anchor, v_nearby_radius_m)
          THEN 2
        ELSE 3
      END AS layer,
      CASE
        WHEN base.effective_geo IS NOT NULL AND v_sort_anchor IS NOT NULL
          THEN extensions.ST_Distance(base.effective_geo, v_sort_anchor)
        WHEN base.effective_geo IS NOT NULL AND v_school_anchor IS NOT NULL
          THEN extensions.ST_Distance(base.effective_geo, v_school_anchor)
        WHEN base.school_geo IS NOT NULL AND v_school_anchor IS NOT NULL
          THEN extensions.ST_Distance(base.school_geo, v_school_anchor)
        ELSE 999999999.0
      END AS distance_sort_m,
      CASE
        WHEN base.effective_geo IS NOT NULL AND base.school_geo IS NOT NULL
          THEN extensions.ST_Distance(base.effective_geo, base.school_geo)
        ELSE 999999999.0
      END AS distance_to_school_m
    FROM base
  ),
  pinned_candidates AS (
    SELECT scored.*
    FROM scored
    WHERE scored.highlight_type = 'pinned'::public.post_highlight_type
      AND scored.pinned_until IS NOT NULL
      AND scored.pinned_until > NOW()
  ),
  pinned_local_rows AS (
    SELECT candidate.*
    FROM pinned_candidates candidate
    WHERE candidate.distance_sort_m
      <= COALESCE(p_pinned_local_radius_km, 25) * 1000.0
    ORDER BY candidate.distance_sort_m, candidate.view_count DESC,
      candidate.pinned_until DESC, candidate.created_at DESC, candidate.post_id DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_pinned_slots, 3), 10))
  ),
  pinned_more_rows AS (
    SELECT candidate.*
    FROM pinned_candidates candidate
    WHERE NOT EXISTS (
      SELECT 1 FROM pinned_local_rows local
      WHERE local.post_id = candidate.post_id
    )
    ORDER BY candidate.view_count DESC, candidate.created_at DESC, candidate.post_id DESC
    LIMIT 50
  ),
  organic_pool AS (
    SELECT
      scored.*,
      ROUND(
        CASE
          WHEN scored.layer IN (1, 2)
            AND scored.distance_sort_m <= v_nearby_radius_m
            THEN (
              (1000000000.0 - LEAST(scored.view_count, 999999999.0)) * 1000000.0
            ) + LEAST(scored.distance_sort_m, 999999.0)
          ELSE scored.distance_sort_m
        END
      )::BIGINT AS distance_sort_key
    FROM scored
    WHERE NOT (
      scored.highlight_type = 'pinned'::public.post_highlight_type
      AND scored.pinned_until IS NOT NULL
      AND scored.pinned_until > NOW()
    )
  ),
  organic_ranked AS (
    SELECT organic.*
    FROM organic_pool organic
    WHERE v_cursor_layer IS NULL
      OR organic.layer > v_cursor_layer
      OR (
        organic.layer = v_cursor_layer
        AND organic.distance_sort_key > v_cursor_distance_key
      )
      OR (
        organic.layer = v_cursor_layer
        AND organic.distance_sort_key = v_cursor_distance_key
        AND organic.created_at < v_cursor_created_at
      )
      OR (
        organic.layer = v_cursor_layer
        AND organic.distance_sort_key = v_cursor_distance_key
        AND organic.created_at = v_cursor_created_at
        AND organic.post_id < v_cursor_id
      )
    ORDER BY organic.layer, organic.distance_sort_key,
      organic.created_at DESC, organic.post_id DESC
    LIMIT v_page_size
  ),
  organic_last AS (
    SELECT ranked.*
    FROM organic_ranked ranked
    ORDER BY ranked.layer DESC, ranked.distance_sort_key DESC,
      ranked.created_at ASC, ranked.post_id ASC
    LIMIT 1
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', pinned.post_id,
          'author_id', pinned.author_id,
          'module', pinned.module,
          'school_id', pinned.school_id,
          'school_name', pinned.school_name,
          'title', pinned.title,
          'description', pinned.description,
          'author_name', pinned.author_name,
          'created_at', pinned.created_at,
          'image_url', pinned.image_url,
          'distance_km', ROUND((pinned.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'distance_to_school_km',
            ROUND((pinned.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'lat', CASE WHEN pinned.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_Y(pinned.effective_geo::extensions.geometry) END,
          'lng', CASE WHEN pinned.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_X(pinned.effective_geo::extensions.geometry) END,
          'highlight_type', pinned.highlight_type,
          'pinned_until', pinned.pinned_until,
          'is_paid', TRUE,
          'view_count', pinned.view_count
        )
        ORDER BY pinned.distance_sort_m, pinned.view_count DESC,
          pinned.created_at DESC, pinned.post_id DESC
      )
      FROM pinned_local_rows pinned
    ), '[]'::JSONB),
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', pinned.post_id,
          'author_id', pinned.author_id,
          'module', pinned.module,
          'school_id', pinned.school_id,
          'school_name', pinned.school_name,
          'title', pinned.title,
          'description', pinned.description,
          'author_name', pinned.author_name,
          'created_at', pinned.created_at,
          'image_url', pinned.image_url,
          'distance_km', ROUND((pinned.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'distance_to_school_km',
            ROUND((pinned.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'lat', CASE WHEN pinned.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_Y(pinned.effective_geo::extensions.geometry) END,
          'lng', CASE WHEN pinned.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_X(pinned.effective_geo::extensions.geometry) END,
          'highlight_type', pinned.highlight_type,
          'pinned_until', pinned.pinned_until,
          'is_paid', TRUE,
          'view_count', pinned.view_count
        )
        ORDER BY pinned.view_count DESC, pinned.created_at DESC, pinned.post_id DESC
      )
      FROM pinned_more_rows pinned
    ), '[]'::JSONB),
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', organic.post_id,
          'author_id', organic.author_id,
          'module', organic.module,
          'school_id', organic.school_id,
          'school_name', organic.school_name,
          'title', organic.title,
          'description', organic.description,
          'author_name', organic.author_name,
          'created_at', organic.created_at,
          'image_url', organic.image_url,
          'distance_km', ROUND((organic.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'distance_to_school_km',
            ROUND((organic.distance_to_school_m / 1000.0)::NUMERIC, 2),
          'layer', organic.layer,
          'distance_sort', organic.distance_sort_key,
          'distance_sort_key', organic.distance_sort_key,
          'lat', CASE WHEN organic.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_Y(organic.effective_geo::extensions.geometry) END,
          'lng', CASE WHEN organic.effective_geo IS NULL THEN NULL
            ELSE extensions.ST_X(organic.effective_geo::extensions.geometry) END,
          'highlight_type', organic.highlight_type,
          'pinned_until', organic.pinned_until,
          'is_paid', FALSE,
          'view_count', organic.view_count
        )
        ORDER BY organic.layer, organic.distance_sort_key,
          organic.created_at DESC, organic.post_id DESC
      )
      FROM organic_ranked organic
    ), '[]'::JSONB),
    (
      SELECT jsonb_build_object(
        'layer', last_row.layer,
        'distance_sort', last_row.distance_sort_key,
        'distance_sort_key', last_row.distance_sort_key,
        'created_at', last_row.created_at,
        'id', last_row.post_id
      )
      FROM organic_last last_row
    )
  INTO v_pinned_local, v_pinned_more, v_organic, v_next_cursor;

  RETURN jsonb_build_object(
    'module', v_module,
    'viewer_school_id', v_viewer_school_id,
    'nearby_radius_km', v_nearby_radius_km,
    'pinned_local', v_pinned_local,
    'pinned_more', v_pinned_more,
    'organic', v_organic,
    'next_cursor', v_next_cursor
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_geo_feed(
  p_viewer_user_id UUID,
  p_module TEXT,
  p_page_size INTEGER DEFAULT 20,
  p_cursor JSONB DEFAULT NULL,
  p_anchor_lat DOUBLE PRECISION DEFAULT NULL,
  p_anchor_lng DOUBLE PRECISION DEFAULT NULL,
  p_nearby_radius_km DOUBLE PRECISION DEFAULT NULL,
  p_pinned_local_radius_km DOUBLE PRECISION DEFAULT 25,
  p_pinned_slots INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR p_viewer_user_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Authentication identity mismatch' USING ERRCODE = '42501';
  END IF;

  RETURN public.c1_internal_get_geo_feed(
    v_me,
    p_module,
    p_page_size,
    p_cursor,
    p_anchor_lat,
    p_anchor_lng,
    p_nearby_radius_km,
    p_pinned_local_radius_km,
    p_pinned_slots
  );
END;
$$;

REVOKE ALL ON FUNCTION public.c1_internal_get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.c1_internal_get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) TO service_role;
REVOKE ALL ON FUNCTION public.get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_geo_feed(
  UUID, TEXT, INTEGER, JSONB, DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, INTEGER
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
