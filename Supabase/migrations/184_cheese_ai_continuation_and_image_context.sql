-- 184_cheese_ai_continuation_and_image_context.sql
--
-- Make the database the single authority for Cheese AI invocation type:
--   1. an explicit structured @奶酪AI mention; or
--   2. a direct reply to a completed Cheese AI output comment.
-- The Worker reads existing public.post_images separately; no image schema or
-- access policy is changed by this migration.

BEGIN;

-- Migration 183 was applied to production before its history row was recorded.
-- Refuse to extend that schema unless every object 184 depends on is present.
DO $$
BEGIN
  IF to_regclass('public.cheese_ai_interactions') IS NULL
     OR to_regprocedure(
       'public.enqueue_cheese_ai_interaction(uuid,uuid,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.claim_cheese_ai_interaction(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.check_cheese_ai_rate_limit(uuid,integer,integer,integer)'
     ) IS NULL
     OR to_regprocedure(
       'public.complete_cheese_ai_interaction(uuid,uuid,text,integer,integer,integer,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.fail_cheese_ai_interaction(uuid,text,integer)'
     ) IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM pg_catalog.pg_trigger trigger_row
       WHERE trigger_row.tgrelid = 'public.cheese_ai_interactions'::regclass
         AND trigger_row.tgname = 'trg_touch_cheese_ai_interaction_updated_at'
         AND NOT trigger_row.tgisinternal
     )
  THEN
    RAISE EXCEPTION
      'Migration 183 Cheese AI schema is incomplete; refusing migration 184'
      USING ERRCODE = '55000';
  END IF;
END;
$$;

ALTER TABLE public.cheese_ai_interactions
  ADD COLUMN trigger_kind TEXT NOT NULL DEFAULT 'mention';

ALTER TABLE public.cheese_ai_interactions
  ADD CONSTRAINT cheese_ai_interactions_trigger_kind_check
  CHECK (trigger_kind IN ('mention', 'continuation'));

CREATE INDEX cheese_ai_interactions_output_lookup_idx
  ON public.cheese_ai_interactions (output_comment_id, post_id, ai_user_id)
  WHERE status = 'completed' AND output_comment_id IS NOT NULL;

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
  v_trigger_kind TEXT;
  v_inserted BOOLEAN := FALSE;
  v_status TEXT;
  v_stored_trigger_kind TEXT;
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

  IF EXISTS (
    SELECT 1
    FROM public.content_mentions mention
    WHERE mention.content_kind = 'comment'
      AND mention.post_id = v_comment.post_id
      AND mention.comment_id = v_comment.id
      AND mention.actor_user_id = v_comment.user_id
      AND mention.mentioned_user_id = p_ai_user_id
  ) THEN
    v_trigger_kind := 'mention';
  ELSIF v_comment.parent_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.cheese_ai_interactions prior
    WHERE prior.output_comment_id = v_comment.parent_id
      AND prior.post_id = v_comment.post_id
      AND prior.ai_user_id = p_ai_user_id
      AND prior.status = 'completed'
  ) THEN
    v_trigger_kind := 'continuation';
  ELSE
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'invocation_missing');
  END IF;

  INSERT INTO public.cheese_ai_interactions (
    source_comment_id,
    post_id,
    source_author_id,
    ai_user_id,
    model,
    prompt_version,
    trigger_kind
  )
  VALUES (
    v_comment.id,
    v_comment.post_id,
    v_comment.user_id,
    p_ai_user_id,
    btrim(p_model),
    btrim(p_prompt_version),
    v_trigger_kind
  )
  ON CONFLICT (source_comment_id) DO NOTHING;

  v_inserted := FOUND;

  SELECT interaction.status, interaction.trigger_kind
  INTO v_status, v_stored_trigger_kind
  FROM public.cheese_ai_interactions interaction
  WHERE interaction.source_comment_id = p_source_comment_id;

  RETURN jsonb_build_object(
    'accepted', TRUE,
    'created', v_inserted,
    'status', v_status,
    'trigger_kind', v_stored_trigger_kind
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
    AND (
      (
        v_interaction.trigger_kind = 'mention'
        AND EXISTS (
          SELECT 1
          FROM public.content_mentions mention
          WHERE mention.content_kind = 'comment'
            AND mention.post_id = comment_row.post_id
            AND mention.comment_id = comment_row.id
            AND mention.actor_user_id = comment_row.user_id
            AND mention.mentioned_user_id = v_interaction.ai_user_id
        )
      )
      OR
      (
        v_interaction.trigger_kind = 'continuation'
        AND comment_row.parent_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM public.cheese_ai_interactions prior
          WHERE prior.output_comment_id = comment_row.parent_id
            AND prior.post_id = comment_row.post_id
            AND prior.ai_user_id = v_interaction.ai_user_id
            AND prior.status = 'completed'
        )
      )
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source comment is no longer eligible'
      USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.comments (
    id, post_id, user_id, parent_id, content, is_anonymous, is_deleted
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

CREATE OR REPLACE FUNCTION public.list_cheese_ai_candidate_comment_ids(
  p_ai_user_id UUID,
  p_since TIMESTAMPTZ,
  p_limit INTEGER DEFAULT 50
)
RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_ids UUID[];
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(array_agg(candidate.id ORDER BY candidate.created_at), ARRAY[]::UUID[])
  INTO v_ids
  FROM (
    SELECT comment_row.id, comment_row.created_at
    FROM public.comments comment_row
    JOIN public.posts post_row ON post_row.id = comment_row.post_id
    JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
    WHERE comment_row.created_at >= p_since
      AND comment_row.is_deleted = FALSE
      AND comment_row.user_id <> p_ai_user_id
      AND post_row.type = 'forum'
      AND post_row.status = 'active'
      AND post_row.is_private = FALSE
      AND COALESCE(forum_row.allow_comments, TRUE)
      AND NOT COALESCE(forum_row.is_locked, FALSE)
      AND NOT EXISTS (
        SELECT 1
        FROM public.cheese_ai_interactions existing
        WHERE existing.source_comment_id = comment_row.id
      )
      AND (
        EXISTS (
          SELECT 1
          FROM public.content_mentions mention
          WHERE mention.content_kind = 'comment'
            AND mention.post_id = comment_row.post_id
            AND mention.comment_id = comment_row.id
            AND mention.actor_user_id = comment_row.user_id
            AND mention.mentioned_user_id = p_ai_user_id
        )
        OR (
          comment_row.parent_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM public.cheese_ai_interactions prior
            WHERE prior.output_comment_id = comment_row.parent_id
              AND prior.post_id = comment_row.post_id
              AND prior.ai_user_id = p_ai_user_id
              AND prior.status = 'completed'
          )
        )
      )
    ORDER BY comment_row.created_at
    LIMIT greatest(1, least(COALESCE(p_limit, 50), 100))
  ) candidate;

  RETURN v_ids;
END;
$$;

REVOKE ALL ON FUNCTION public.list_cheese_ai_candidate_comment_ids(
  UUID, TIMESTAMPTZ, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_cheese_ai_candidate_comment_ids(
  UUID, TIMESTAMPTZ, INTEGER
) TO service_role;

COMMIT;
