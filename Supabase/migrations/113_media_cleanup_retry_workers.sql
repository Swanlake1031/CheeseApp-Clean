-- Durable media cleanup for Chat plus a bounded, service-role retry contract
-- for both Chat and the existing Forum/Secondhand/Rent cleanup backlog.

BEGIN;

CREATE OR REPLACE FUNCTION public.media_cleanup_next_attempt(p_attempt_count INTEGER)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT NOW() + LEAST(
    INTERVAL '24 hours',
    POWER(2, LEAST(GREATEST(COALESCE(p_attempt_count, 0), 0), 10))
      * INTERVAL '1 minute'
  );
$$;

REVOKE ALL ON FUNCTION public.media_cleanup_next_attempt(INTEGER) FROM PUBLIC;

ALTER TABLE public.post_media_cleanup_backlog
  ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS locked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lock_token UUID;

ALTER TABLE public.post_media_cleanup_backlog
  DROP CONSTRAINT IF EXISTS post_media_cleanup_backlog_status_check;
ALTER TABLE public.post_media_cleanup_backlog
  ADD CONSTRAINT post_media_cleanup_backlog_status_check
  CHECK (status IN ('pending', 'unresolved', 'resolved', 'blocked'));

CREATE INDEX IF NOT EXISTS post_media_cleanup_retry_idx
  ON public.post_media_cleanup_backlog(status, next_attempt_at, created_at, id)
  WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.is_exact_chat_media_identity(
  p_bucket TEXT,
  p_object_path TEXT,
  p_scope TEXT,
  p_scope_id UUID,
  p_owner_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_parts TEXT[];
BEGIN
  IF p_bucket IS DISTINCT FROM 'chat-images'
     OR p_object_path IS NULL
     OR p_scope NOT IN ('direct', 'group')
     OR p_scope_id IS NULL
     OR p_owner_id IS NULL
  THEN
    RETURN FALSE;
  END IF;

  v_parts := string_to_array(p_object_path, '/');
  RETURN array_length(v_parts, 1) = 4
    AND v_parts[1] = p_scope
    AND v_parts[2] = LOWER(p_scope_id::TEXT)
    AND v_parts[3] = LOWER(p_owner_id::TEXT)
    AND v_parts[4] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$';
END;
$$;

REVOKE ALL ON FUNCTION public.is_exact_chat_media_identity(TEXT, TEXT, TEXT, UUID, UUID)
  FROM PUBLIC;

CREATE TABLE IF NOT EXISTS public.chat_media_cleanup_backlog (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  bucket TEXT NOT NULL,
  object_path TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('direct', 'group')),
  scope_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'blocked')),
  reason TEXT NOT NULL,
  resolution TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at TIMESTAMPTZ DEFAULT NOW(),
  locked_at TIMESTAMPTZ,
  lock_token UUID,
  last_error_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  UNIQUE(bucket, object_path),
  CHECK (
    public.is_exact_chat_media_identity(
      bucket, object_path, scope, scope_id, owner_id
    )
  )
);

CREATE INDEX IF NOT EXISTS chat_media_cleanup_owner_status_idx
  ON public.chat_media_cleanup_backlog(owner_id, status, created_at, id);
CREATE INDEX IF NOT EXISTS chat_media_cleanup_retry_idx
  ON public.chat_media_cleanup_backlog(status, next_attempt_at, created_at, id)
  WHERE status = 'pending';

ALTER TABLE public.chat_media_cleanup_backlog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners can read their chat media cleanup backlog"
  ON public.chat_media_cleanup_backlog;
CREATE POLICY "Owners can read their chat media cleanup backlog"
ON public.chat_media_cleanup_backlog
FOR SELECT
TO authenticated
USING (owner_id = auth.uid());

REVOKE ALL ON TABLE public.chat_media_cleanup_backlog
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.chat_media_cleanup_backlog TO authenticated;
GRANT ALL ON TABLE public.chat_media_cleanup_backlog TO service_role;

DROP TRIGGER IF EXISTS chat_media_cleanup_backlog_set_updated_at
  ON public.chat_media_cleanup_backlog;
CREATE TRIGGER chat_media_cleanup_backlog_set_updated_at
BEFORE UPDATE ON public.chat_media_cleanup_backlog
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE OR REPLACE FUNCTION public.prepare_chat_media_cleanup(
  p_scope TEXT,
  p_scope_id UUID,
  p_object_path TEXT,
  p_reason TEXT DEFAULT 'upload_reserved'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_cleanup_id UUID;
  v_reason TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_exact_chat_media_identity(
    'chat-images', p_object_path, p_scope, p_scope_id, v_me
  ) OR NOT public.can_access_chat_media_object(p_object_path) THEN
    RAISE EXCEPTION 'Chat media identity is outside the active conversation scope'
      USING ERRCODE = '42501';
  END IF;

  v_reason := CASE
    WHEN p_reason IN ('upload_reserved', 'upload_failed', 'send_failed', 'cancelled')
      THEN p_reason
    ELSE 'upload_reserved'
  END;

  INSERT INTO public.chat_media_cleanup_backlog (
    owner_id, bucket, object_path, scope, scope_id, status, reason,
    resolution, next_attempt_at, locked_at, lock_token, last_error_code,
    resolved_at
  )
  VALUES (
    v_me, 'chat-images', p_object_path, p_scope, p_scope_id, 'pending',
    v_reason, NULL, NOW() + INTERVAL '5 minutes', NULL, NULL, NULL, NULL
  )
  ON CONFLICT (bucket, object_path) DO UPDATE
  SET
    status = 'pending',
    reason = EXCLUDED.reason,
    resolution = NULL,
    next_attempt_at = NOW() + INTERVAL '5 minutes',
    locked_at = NULL,
    lock_token = NULL,
    last_error_code = NULL,
    resolved_at = NULL
  WHERE public.chat_media_cleanup_backlog.owner_id = v_me
  RETURNING id INTO v_cleanup_id;

  IF v_cleanup_id IS NULL THEN
    RAISE EXCEPTION 'Chat media identity belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_cleanup_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_chat_media_cleanup(
  p_cleanup_id UUID,
  p_resolution TEXT DEFAULT 'retained_by_message'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  UPDATE public.chat_media_cleanup_backlog
  SET
    status = 'resolved',
    resolution = CASE
      WHEN p_resolution IN ('retained_by_message', 'deleted', 'not_found')
        THEN p_resolution
      ELSE 'retained_by_message'
    END,
    next_attempt_at = NULL,
    locked_at = NULL,
    lock_token = NULL,
    last_error_code = NULL,
    resolved_at = NOW()
  WHERE id = p_cleanup_id
    AND owner_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chat cleanup obligation not found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_chat_media_cleanup_attempt(
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
  v_next_attempt_count INTEGER;
  v_error_code TEXT;
BEGIN
  SELECT attempt_count + 1
  INTO v_next_attempt_count
  FROM public.chat_media_cleanup_backlog
  WHERE id = p_cleanup_id
    AND owner_id = auth.uid();

  IF v_next_attempt_count IS NULL THEN
    RAISE EXCEPTION 'Chat cleanup obligation not found' USING ERRCODE = 'P0002';
  END IF;

  v_error_code := CASE
    WHEN p_succeeded THEN NULL
    WHEN COALESCE(p_error_code, '') ~ '^[A-Za-z0-9_.:-]{1,120}$'
      THEN p_error_code
    ELSE 'storage_delete_failed'
  END;

  UPDATE public.chat_media_cleanup_backlog
  SET
    status = CASE
      WHEN p_succeeded THEN 'resolved'
      WHEN v_next_attempt_count >= 8 THEN 'blocked'
      ELSE 'pending'
    END,
    resolution = CASE WHEN p_succeeded THEN 'deleted' ELSE NULL END,
    attempt_count = v_next_attempt_count,
    next_attempt_at = CASE
      WHEN p_succeeded OR v_next_attempt_count >= 8 THEN NULL
      ELSE public.media_cleanup_next_attempt(v_next_attempt_count)
    END,
    locked_at = NULL,
    lock_token = NULL,
    last_error_code = v_error_code,
    resolved_at = CASE WHEN p_succeeded THEN NOW() ELSE NULL END
  WHERE id = p_cleanup_id
    AND owner_id = auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_chat_media_cleanup_backlog()
RETURNS TABLE (
  cleanup_id UUID,
  bucket TEXT,
  object_path TEXT,
  scope TEXT,
  scope_id UUID,
  status TEXT,
  reason TEXT,
  attempt_count INTEGER,
  next_attempt_at TIMESTAMPTZ,
  last_error_code TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    cleanup.id, cleanup.bucket, cleanup.object_path, cleanup.scope,
    cleanup.scope_id, cleanup.status, cleanup.reason,
    cleanup.attempt_count, cleanup.next_attempt_at,
    cleanup.last_error_code, cleanup.created_at
  FROM public.chat_media_cleanup_backlog cleanup
  WHERE cleanup.owner_id = auth.uid()
    AND cleanup.status <> 'resolved'
  ORDER BY cleanup.created_at, cleanup.id;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_direct_message_media_cleanup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
BEGIN
  IF OLD.message_type <> 'image'
     OR NOT public.is_exact_chat_media_identity(
       OLD.metadata->>'image_bucket',
       OLD.metadata->>'image_object_path',
       'direct',
       OLD.conversation_id,
       OLD.sender_id
     )
  THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND COALESCE(NEW.is_deleted, FALSE) = FALSE
     AND NEW.message_type = 'image'
     AND NEW.metadata->>'image_object_path' IS NOT DISTINCT FROM
       OLD.metadata->>'image_object_path'
  THEN
    RETURN NEW;
  END IF;

  v_reason := CASE WHEN TG_OP = 'DELETE'
    THEN 'message_hard_deleted' ELSE 'message_deleted' END;

  INSERT INTO public.chat_media_cleanup_backlog (
    owner_id, bucket, object_path, scope, scope_id, status, reason,
    next_attempt_at
  ) VALUES (
    OLD.sender_id, OLD.metadata->>'image_bucket',
    OLD.metadata->>'image_object_path', 'direct', OLD.conversation_id,
    'pending', v_reason, NOW()
  )
  ON CONFLICT (bucket, object_path) DO UPDATE
  SET status = 'pending', reason = EXCLUDED.reason, resolution = NULL,
      next_attempt_at = NOW(), locked_at = NULL, lock_token = NULL,
      last_error_code = NULL, resolved_at = NULL;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_group_message_media_cleanup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
BEGIN
  IF OLD.message_type <> 'image'
     OR NOT public.is_exact_chat_media_identity(
       OLD.metadata->>'image_bucket',
       OLD.metadata->>'image_object_path',
       'group',
       OLD.group_id,
       OLD.sender_id
     )
  THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND COALESCE(NEW.is_deleted, FALSE) = FALSE
     AND NEW.message_type = 'image'
     AND NEW.metadata->>'image_object_path' IS NOT DISTINCT FROM
       OLD.metadata->>'image_object_path'
  THEN
    RETURN NEW;
  END IF;

  v_reason := CASE WHEN TG_OP = 'DELETE'
    THEN 'group_message_hard_deleted' ELSE 'group_message_deleted' END;

  INSERT INTO public.chat_media_cleanup_backlog (
    owner_id, bucket, object_path, scope, scope_id, status, reason,
    next_attempt_at
  ) VALUES (
    OLD.sender_id, OLD.metadata->>'image_bucket',
    OLD.metadata->>'image_object_path', 'group', OLD.group_id,
    'pending', v_reason, NOW()
  )
  ON CONFLICT (bucket, object_path) DO UPDATE
  SET status = 'pending', reason = EXCLUDED.reason, resolution = NULL,
      next_attempt_at = NOW(), locked_at = NULL, lock_token = NULL,
      last_error_code = NULL, resolved_at = NULL;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS messages_enqueue_media_cleanup_update ON public.messages;
CREATE TRIGGER messages_enqueue_media_cleanup_update
AFTER UPDATE OF metadata, message_type, is_deleted ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.enqueue_direct_message_media_cleanup();

DROP TRIGGER IF EXISTS messages_enqueue_media_cleanup_delete ON public.messages;
CREATE TRIGGER messages_enqueue_media_cleanup_delete
AFTER DELETE ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.enqueue_direct_message_media_cleanup();

DROP TRIGGER IF EXISTS group_messages_enqueue_media_cleanup_update
  ON public.group_messages;
CREATE TRIGGER group_messages_enqueue_media_cleanup_update
AFTER UPDATE OF metadata, message_type, is_deleted ON public.group_messages
FOR EACH ROW EXECUTE FUNCTION public.enqueue_group_message_media_cleanup();

DROP TRIGGER IF EXISTS group_messages_enqueue_media_cleanup_delete
  ON public.group_messages;
CREATE TRIGGER group_messages_enqueue_media_cleanup_delete
AFTER DELETE ON public.group_messages
FOR EACH ROW EXECUTE FUNCTION public.enqueue_group_message_media_cleanup();

-- Resolve stale upload reservations that are now referenced by an active
-- message before the worker can lease them for deletion.
CREATE OR REPLACE FUNCTION public.resolve_referenced_chat_media_cleanup()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  WITH resolved AS (
    UPDATE public.chat_media_cleanup_backlog cleanup
    SET status = 'resolved', resolution = 'retained_by_message',
        next_attempt_at = NULL, locked_at = NULL, lock_token = NULL,
        last_error_code = NULL, resolved_at = NOW()
    WHERE cleanup.status = 'pending'
      AND (
        EXISTS (
          SELECT 1 FROM public.messages message
          WHERE message.message_type = 'image'
            AND COALESCE(message.is_deleted, FALSE) = FALSE
            AND message.metadata->>'image_bucket' = cleanup.bucket
            AND message.metadata->>'image_object_path' = cleanup.object_path
        )
        OR EXISTS (
          SELECT 1 FROM public.group_messages message
          WHERE message.message_type = 'image'
            AND COALESCE(message.is_deleted, FALSE) = FALSE
            AND message.metadata->>'image_bucket' = cleanup.bucket
            AND message.metadata->>'image_object_path' = cleanup.object_path
        )
      )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_count FROM resolved;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_post_media_cleanup_batch(
  p_limit INTEGER,
  p_lock_token UUID
)
RETURNS TABLE (cleanup_id UUID, bucket TEXT, object_path TEXT, attempt_count INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  IF p_lock_token IS NULL THEN
    RAISE EXCEPTION 'Lock token is required' USING ERRCODE = '22004';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT cleanup.id
    FROM public.post_media_cleanup_backlog cleanup
    WHERE cleanup.status = 'pending'
      AND COALESCE(cleanup.next_attempt_at, cleanup.created_at) <= NOW()
      AND (cleanup.locked_at IS NULL OR cleanup.locked_at < NOW() - INTERVAL '5 minutes')
    ORDER BY COALESCE(cleanup.next_attempt_at, cleanup.created_at), cleanup.id
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.post_media_cleanup_backlog cleanup
  SET locked_at = NOW(), lock_token = p_lock_token
  FROM candidates
  WHERE cleanup.id = candidates.id
  RETURNING cleanup.id, cleanup.bucket, cleanup.object_path, cleanup.attempt_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_chat_media_cleanup_batch(
  p_limit INTEGER,
  p_lock_token UUID
)
RETURNS TABLE (cleanup_id UUID, bucket TEXT, object_path TEXT, attempt_count INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  IF p_lock_token IS NULL THEN
    RAISE EXCEPTION 'Lock token is required' USING ERRCODE = '22004';
  END IF;

  PERFORM public.resolve_referenced_chat_media_cleanup();

  RETURN QUERY
  WITH candidates AS (
    SELECT cleanup.id
    FROM public.chat_media_cleanup_backlog cleanup
    WHERE cleanup.status = 'pending'
      AND COALESCE(cleanup.next_attempt_at, cleanup.created_at) <= NOW()
      AND (cleanup.locked_at IS NULL OR cleanup.locked_at < NOW() - INTERVAL '5 minutes')
    ORDER BY COALESCE(cleanup.next_attempt_at, cleanup.created_at), cleanup.id
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.chat_media_cleanup_backlog cleanup
  SET locked_at = NOW(), lock_token = p_lock_token
  FROM candidates
  WHERE cleanup.id = candidates.id
  RETURNING cleanup.id, cleanup.bucket, cleanup.object_path, cleanup.attempt_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_post_media_cleanup_job(
  p_cleanup_id UUID,
  p_lock_token UUID,
  p_succeeded BOOLEAN,
  p_error_code TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_stage_id UUID;
  v_attempt_count INTEGER;
  v_error_code TEXT;
BEGIN
  SELECT cleanup.source_staging_id, cleanup.attempt_count + 1
  INTO v_stage_id, v_attempt_count
  FROM public.post_media_cleanup_backlog cleanup
  WHERE cleanup.id = p_cleanup_id
    AND cleanup.lock_token = p_lock_token
    AND cleanup.status = 'pending';

  IF v_attempt_count IS NULL THEN
    RAISE EXCEPTION 'Post cleanup lease not found' USING ERRCODE = 'P0002';
  END IF;

  v_error_code := CASE
    WHEN p_succeeded THEN NULL
    WHEN COALESCE(p_error_code, '') ~ '^[A-Za-z0-9_.:-]{1,120}$'
      THEN p_error_code ELSE 'storage_delete_failed' END;

  UPDATE public.post_media_cleanup_backlog
  SET status = CASE WHEN p_succeeded THEN 'resolved'
                    WHEN v_attempt_count >= 8 THEN 'blocked'
                    ELSE 'pending' END,
      attempt_count = v_attempt_count,
      next_attempt_at = CASE WHEN p_succeeded OR v_attempt_count >= 8 THEN NULL
        ELSE public.media_cleanup_next_attempt(v_attempt_count) END,
      locked_at = NULL, lock_token = NULL, last_error_code = v_error_code,
      resolved_at = CASE WHEN p_succeeded THEN NOW() ELSE NULL END
  WHERE id = p_cleanup_id AND lock_token = p_lock_token;

  IF p_succeeded AND v_stage_id IS NOT NULL THEN
    UPDATE public.post_media_staging
    SET status = 'cleaned'
    WHERE id = v_stage_id AND status <> 'finalized';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_chat_media_cleanup_job(
  p_cleanup_id UUID,
  p_lock_token UUID,
  p_succeeded BOOLEAN,
  p_error_code TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_attempt_count INTEGER;
  v_error_code TEXT;
BEGIN
  SELECT cleanup.attempt_count + 1 INTO v_attempt_count
  FROM public.chat_media_cleanup_backlog cleanup
  WHERE cleanup.id = p_cleanup_id
    AND cleanup.lock_token = p_lock_token
    AND cleanup.status = 'pending';

  IF v_attempt_count IS NULL THEN
    RAISE EXCEPTION 'Chat cleanup lease not found' USING ERRCODE = 'P0002';
  END IF;

  v_error_code := CASE
    WHEN p_succeeded THEN NULL
    WHEN COALESCE(p_error_code, '') ~ '^[A-Za-z0-9_.:-]{1,120}$'
      THEN p_error_code ELSE 'storage_delete_failed' END;

  UPDATE public.chat_media_cleanup_backlog
  SET status = CASE WHEN p_succeeded THEN 'resolved'
                    WHEN v_attempt_count >= 8 THEN 'blocked'
                    ELSE 'pending' END,
      resolution = CASE WHEN p_succeeded THEN 'deleted' ELSE NULL END,
      attempt_count = v_attempt_count,
      next_attempt_at = CASE WHEN p_succeeded OR v_attempt_count >= 8 THEN NULL
        ELSE public.media_cleanup_next_attempt(v_attempt_count) END,
      locked_at = NULL, lock_token = NULL, last_error_code = v_error_code,
      resolved_at = CASE WHEN p_succeeded THEN NOW() ELSE NULL END
  WHERE id = p_cleanup_id AND lock_token = p_lock_token;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_media_cleanup_backlog_metrics()
RETURNS TABLE (
  post_pending BIGINT,
  post_blocked BIGINT,
  post_unresolved BIGINT,
  chat_pending BIGINT,
  chat_blocked BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT
    COUNT(*) FILTER (WHERE post.status = 'pending'),
    COUNT(*) FILTER (WHERE post.status = 'blocked'),
    COUNT(*) FILTER (WHERE post.status = 'unresolved'),
    (SELECT COUNT(*) FROM public.chat_media_cleanup_backlog chat
      WHERE chat.status = 'pending'),
    (SELECT COUNT(*) FROM public.chat_media_cleanup_backlog chat
      WHERE chat.status = 'blocked')
  FROM public.post_media_cleanup_backlog post;
$$;

-- Keep app-triggered post cleanup compatible while adding bounded backoff.
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
  v_attempt_count INTEGER;
  v_error_code TEXT;
BEGIN
  SELECT cleanup.source_staging_id, cleanup.attempt_count + 1
  INTO v_stage_id, v_attempt_count
  FROM public.post_media_cleanup_backlog cleanup
  WHERE cleanup.id = p_cleanup_id
    AND cleanup.owner_id = v_me
    AND cleanup.status <> 'unresolved';

  IF v_attempt_count IS NULL THEN
    RAISE EXCEPTION 'Cleanup obligation not found' USING ERRCODE = 'P0002';
  END IF;

  v_error_code := CASE
    WHEN p_succeeded THEN NULL
    WHEN COALESCE(p_error_code, '') ~ '^[A-Za-z0-9_.:-]{1,120}$'
      THEN p_error_code ELSE 'storage_delete_failed' END;

  UPDATE public.post_media_cleanup_backlog
  SET status = CASE WHEN p_succeeded THEN 'resolved'
                    WHEN v_attempt_count >= 8 THEN 'blocked'
                    ELSE 'pending' END,
      attempt_count = v_attempt_count,
      next_attempt_at = CASE WHEN p_succeeded OR v_attempt_count >= 8 THEN NULL
        ELSE public.media_cleanup_next_attempt(v_attempt_count) END,
      locked_at = NULL, lock_token = NULL, last_error_code = v_error_code,
      resolved_at = CASE WHEN p_succeeded THEN NOW() ELSE NULL END
  WHERE id = p_cleanup_id AND owner_id = v_me;

  IF p_succeeded AND v_stage_id IS NOT NULL THEN
    UPDATE public.post_media_staging
    SET status = 'cleaned'
    WHERE id = v_stage_id AND owner_id = v_me AND status <> 'finalized';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.prepare_chat_media_cleanup(TEXT, UUID, TEXT, TEXT)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_chat_media_cleanup(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_chat_media_cleanup_attempt(UUID, BOOLEAN, TEXT)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_chat_media_cleanup_backlog() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_post_media_cleanup_batch(INTEGER, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_chat_media_cleanup_batch(INTEGER, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_post_media_cleanup_job(UUID, UUID, BOOLEAN, TEXT)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_chat_media_cleanup_job(UUID, UUID, BOOLEAN, TEXT)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_media_cleanup_backlog_metrics() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_referenced_chat_media_cleanup() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.prepare_chat_media_cleanup(TEXT, UUID, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_chat_media_cleanup(UUID, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_chat_media_cleanup_attempt(UUID, BOOLEAN, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_chat_media_cleanup_backlog()
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.claim_post_media_cleanup_batch(INTEGER, UUID),
  public.claim_chat_media_cleanup_batch(INTEGER, UUID),
  public.complete_post_media_cleanup_job(UUID, UUID, BOOLEAN, TEXT),
  public.complete_chat_media_cleanup_job(UUID, UUID, BOOLEAN, TEXT),
  public.get_media_cleanup_backlog_metrics(),
  public.resolve_referenced_chat_media_cleanup()
TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
