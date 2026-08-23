-- 183_cheese_ai_comment_interactions.sql
-- Durable, service-only idempotency for explicit @奶酪AI forum comment mentions.
--
-- This migration does not create a second comment system. The generated reply
-- is inserted into public.comments so the existing reply notification,
-- moderation, deletion and thread-positioning behavior remains authoritative.

BEGIN;

CREATE TABLE public.cheese_ai_interactions (
  source_comment_id UUID PRIMARY KEY
    REFERENCES public.comments(id) ON DELETE CASCADE,
  post_id UUID NOT NULL
    REFERENCES public.posts(id) ON DELETE CASCADE,
  source_author_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  ai_user_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  model TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  output_comment_id UUID UNIQUE
    REFERENCES public.comments(id) ON DELETE SET NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0
    CHECK (attempt_count >= 0 AND attempt_count <= 2),
  next_attempt_at TIMESTAMPTZ,
  latency_ms INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
  input_token_count INTEGER CHECK (
    input_token_count IS NULL OR input_token_count >= 0
  ),
  output_token_count INTEGER CHECK (
    output_token_count IS NULL OR output_token_count >= 0
  ),
  finish_reason TEXT,
  error_category TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX cheese_ai_interactions_work_idx
  ON public.cheese_ai_interactions (status, next_attempt_at, created_at);

CREATE INDEX cheese_ai_interactions_author_created_idx
  ON public.cheese_ai_interactions (source_author_id, created_at DESC);

ALTER TABLE public.cheese_ai_interactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.cheese_ai_interactions
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cheese_ai_interactions
  TO service_role;

CREATE OR REPLACE FUNCTION public.touch_cheese_ai_interaction_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_touch_cheese_ai_interaction_updated_at
BEFORE UPDATE ON public.cheese_ai_interactions
FOR EACH ROW
EXECUTE FUNCTION public.touch_cheese_ai_interaction_updated_at();

CREATE OR REPLACE FUNCTION public.enqueue_cheese_ai_interaction(
  p_source_comment_id UUID,
  p_ai_user_id UUID,
  p_model TEXT,
  p_prompt_version TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_comment public.comments%ROWTYPE;
  v_post public.posts%ROWTYPE;
  v_inserted BOOLEAN := FALSE;
  v_status TEXT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  IF p_source_comment_id IS NULL
     OR p_ai_user_id IS NULL
     OR NULLIF(btrim(p_model), '') IS NULL
     OR NULLIF(btrim(p_prompt_version), '') IS NULL
  THEN
    RAISE EXCEPTION 'Invalid Cheese AI interaction parameters'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles profile WHERE profile.id = p_ai_user_id
  ) THEN
    RAISE EXCEPTION 'Configured Cheese AI profile does not exist'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT comment_row.*
  INTO v_comment
  FROM public.comments comment_row
  WHERE comment_row.id = p_source_comment_id
    AND comment_row.is_deleted = FALSE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'comment_unavailable');
  END IF;

  IF v_comment.user_id = p_ai_user_id THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'ai_self_loop');
  END IF;

  SELECT post_row.*
  INTO v_post
  FROM public.posts post_row
  JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
  WHERE post_row.id = v_comment.post_id
    AND post_row.type = 'forum'
    AND post_row.status = 'active'
    AND post_row.is_private = FALSE
    AND COALESCE(forum_row.allow_comments, TRUE)
    AND NOT COALESCE(forum_row.is_locked, FALSE);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'unsupported_or_private');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.content_mentions mention
    WHERE mention.content_kind = 'comment'
      AND mention.post_id = v_comment.post_id
      AND mention.comment_id = v_comment.id
      AND mention.actor_user_id = v_comment.user_id
      AND mention.mentioned_user_id = p_ai_user_id
  ) THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'structured_mention_missing');
  END IF;

  INSERT INTO public.cheese_ai_interactions (
    source_comment_id,
    post_id,
    source_author_id,
    ai_user_id,
    model,
    prompt_version
  )
  VALUES (
    v_comment.id,
    v_comment.post_id,
    v_comment.user_id,
    p_ai_user_id,
    btrim(p_model),
    btrim(p_prompt_version)
  )
  ON CONFLICT (source_comment_id) DO NOTHING;

  v_inserted := FOUND;

  SELECT interaction.status
  INTO v_status
  FROM public.cheese_ai_interactions interaction
  WHERE interaction.source_comment_id = p_source_comment_id;

  RETURN jsonb_build_object(
    'accepted', TRUE,
    'created', v_inserted,
    'status', v_status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_cheese_ai_interaction(
  p_source_comment_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_claimed BOOLEAN := FALSE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.cheese_ai_interactions interaction
  SET
    status = 'processing',
    attempt_count = interaction.attempt_count + 1,
    next_attempt_at = NULL,
    error_category = NULL
  WHERE interaction.source_comment_id = p_source_comment_id
    AND interaction.output_comment_id IS NULL
    AND interaction.attempt_count < 2
    AND (
      interaction.status = 'pending'
      OR (
        interaction.status = 'failed'
        AND interaction.next_attempt_at IS NOT NULL
        AND interaction.next_attempt_at <= clock_timestamp()
      )
      OR (
        interaction.status = 'processing'
        AND interaction.updated_at < clock_timestamp() - INTERVAL '5 minutes'
      )
    );

  v_claimed := FOUND;
  RETURN v_claimed;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_cheese_ai_rate_limit(
  p_source_author_id UUID,
  p_window_minutes INTEGER,
  p_window_limit INTEGER,
  p_daily_limit INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_window_count INTEGER;
  v_daily_count INTEGER;
  v_window_minutes INTEGER := greatest(1, least(p_window_minutes, 1440));
  v_window_limit INTEGER := greatest(1, p_window_limit);
  v_daily_limit INTEGER := greatest(1, p_daily_limit);
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  SELECT count(*)::INTEGER
  INTO v_window_count
  FROM public.cheese_ai_interactions interaction
  WHERE interaction.source_author_id = p_source_author_id
    AND interaction.created_at >= clock_timestamp()
      - make_interval(mins => v_window_minutes);

  SELECT count(*)::INTEGER
  INTO v_daily_count
  FROM public.cheese_ai_interactions interaction
  WHERE interaction.source_author_id = p_source_author_id
    AND interaction.created_at >= date_trunc('day', clock_timestamp());

  RETURN jsonb_build_object(
    'allowed', v_window_count <= v_window_limit AND v_daily_count <= v_daily_limit,
    'window_count', v_window_count,
    'daily_count', v_daily_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_cheese_ai_interaction(
  p_source_comment_id UUID,
  p_output_comment_id UUID,
  p_content TEXT,
  p_latency_ms INTEGER,
  p_input_token_count INTEGER,
  p_output_token_count INTEGER,
  p_finish_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_interaction public.cheese_ai_interactions%ROWTYPE;
  v_source public.comments%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  IF p_output_comment_id IS NULL OR NULLIF(btrim(p_content), '') IS NULL THEN
    RAISE EXCEPTION 'AI reply content is required' USING ERRCODE = '22023';
  END IF;

  SELECT interaction.*
  INTO v_interaction
  FROM public.cheese_ai_interactions interaction
  WHERE interaction.source_comment_id = p_source_comment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheese AI interaction not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_interaction.status = 'completed'
     AND v_interaction.output_comment_id IS NOT NULL
  THEN
    RETURN v_interaction.output_comment_id;
  END IF;

  IF v_interaction.status <> 'processing' THEN
    RAISE EXCEPTION 'Cheese AI interaction is not processing'
      USING ERRCODE = '55000';
  END IF;

  SELECT comment_row.*
  INTO v_source
  FROM public.comments comment_row
  JOIN public.posts post_row ON post_row.id = comment_row.post_id
  JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
  WHERE comment_row.id = p_source_comment_id
    AND comment_row.is_deleted = FALSE
    AND comment_row.user_id <> v_interaction.ai_user_id
    AND post_row.type = 'forum'
    AND post_row.status = 'active'
    AND post_row.is_private = FALSE
    AND COALESCE(forum_row.allow_comments, TRUE)
    AND NOT COALESCE(forum_row.is_locked, FALSE)
    AND EXISTS (
      SELECT 1
      FROM public.content_mentions mention
      WHERE mention.content_kind = 'comment'
        AND mention.post_id = comment_row.post_id
        AND mention.comment_id = comment_row.id
        AND mention.actor_user_id = comment_row.user_id
        AND mention.mentioned_user_id = v_interaction.ai_user_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source comment is no longer eligible'
      USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.comments (
    id,
    post_id,
    user_id,
    parent_id,
    content,
    is_anonymous,
    is_deleted
  )
  VALUES (
    p_output_comment_id,
    v_source.post_id,
    v_interaction.ai_user_id,
    v_source.id,
    btrim(p_content),
    FALSE,
    FALSE
  );

  UPDATE public.cheese_ai_interactions interaction
  SET
    status = 'completed',
    output_comment_id = p_output_comment_id,
    latency_ms = greatest(0, p_latency_ms),
    input_token_count = greatest(0, p_input_token_count),
    output_token_count = greatest(0, p_output_token_count),
    finish_reason = NULLIF(left(p_finish_reason, 120), ''),
    error_category = NULL,
    next_attempt_at = NULL
  WHERE interaction.source_comment_id = p_source_comment_id;

  RETURN p_output_comment_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_cheese_ai_interaction(
  p_source_comment_id UUID,
  p_error_category TEXT,
  p_retry_after_seconds INTEGER DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.cheese_ai_interactions interaction
  SET
    status = 'failed',
    error_category = COALESCE(
      NULLIF(left(btrim(p_error_category), 120), ''),
      'unknown'
    ),
    next_attempt_at = CASE
      WHEN p_retry_after_seconds IS NULL OR interaction.attempt_count >= 2
        THEN NULL
      ELSE clock_timestamp()
        + make_interval(secs => greatest(1, least(p_retry_after_seconds, 3600)))
    END
  WHERE interaction.source_comment_id = p_source_comment_id
    AND interaction.status <> 'completed';
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_cheese_ai_interaction(
  UUID, UUID, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_cheese_ai_interaction(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.check_cheese_ai_rate_limit(
  UUID, INTEGER, INTEGER, INTEGER
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_cheese_ai_interaction(
  UUID, UUID, TEXT, INTEGER, INTEGER, INTEGER, TEXT
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_cheese_ai_interaction(
  UUID, TEXT, INTEGER
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.enqueue_cheese_ai_interaction(
  UUID, UUID, TEXT, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_cheese_ai_interaction(UUID)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.check_cheese_ai_rate_limit(
  UUID, INTEGER, INTEGER, INTEGER
) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_cheese_ai_interaction(
  UUID, UUID, TEXT, INTEGER, INTEGER, INTEGER, TEXT
) TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_cheese_ai_interaction(
  UUID, TEXT, INTEGER
) TO service_role;

COMMIT;
