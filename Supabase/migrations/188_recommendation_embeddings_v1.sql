-- Cheese Recommendation System V1: semantic embedding storage and jobs.
--
-- Additive/rollback notes:
-- - This migration does not replace the legacy feed or remove data.
-- - Dropping these new objects rolls back the schema, but generated vectors and
--   job history would be lost. Back them up before a destructive rollback.
-- - Apply before deploying the Worker that claims embedding jobs.

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.recommendation_configuration (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  algorithm_version TEXT NOT NULL DEFAULT 'cheese-rec-v1'
    CHECK (algorithm_version = 'cheese-rec-v1'),
  embedding_version TEXT NOT NULL DEFAULT 'cheese-semantic-v1'
    CHECK (embedding_version = 'cheese-semantic-v1'),
  embedding_model TEXT NOT NULL DEFAULT 'gemini-embedding-2'
    CHECK (embedding_model = 'gemini-embedding-2'),
  embedding_dimension INTEGER NOT NULL DEFAULT 768
    CHECK (embedding_dimension = 768),
  input_format_version INTEGER NOT NULL DEFAULT 1
    CHECK (input_format_version = 1),
  rollout_percentage INTEGER NOT NULL DEFAULT 0
    CHECK (rollout_percentage BETWEEN 0 AND 100),
  shadow_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  semantic_weight DOUBLE PRECISION NOT NULL DEFAULT 0.40,
  engagement_weight DOUBLE PRECISION NOT NULL DEFAULT 0.20,
  freshness_weight DOUBLE PRECISION NOT NULL DEFAULT 0.15,
  quality_weight DOUBLE PRECISION NOT NULL DEFAULT 0.10,
  author_weight DOUBLE PRECISION NOT NULL DEFAULT 0.05,
  exploration_weight DOUBLE PRECISION NOT NULL DEFAULT 0.10,
  CHECK (ABS(
    semantic_weight + engagement_weight + freshness_weight
    + quality_weight + author_weight + exploration_weight - 1.0
  ) < 0.000001),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO public.recommendation_configuration(singleton)
VALUES (TRUE)
ON CONFLICT (singleton) DO NOTHING;

ALTER TABLE public.recommendation_configuration ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.recommendation_configuration
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.recommendation_configuration TO service_role;

CREATE TABLE public.post_embeddings (
  post_id UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  embedding_version TEXT NOT NULL,
  embedding extensions.vector(768),
  model TEXT NOT NULL,
  input_format_version INTEGER NOT NULL,
  input_hash TEXT NOT NULL CHECK (input_hash ~ '^[0-9a-f]{64}$'),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'ready', 'failed')),
  generated_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  last_error TEXT,
  PRIMARY KEY (post_id, embedding_version),
  CHECK ((status = 'ready') = (embedding IS NOT NULL))
);

CREATE INDEX post_embeddings_ready_version_idx
  ON public.post_embeddings(embedding_version, post_id)
  WHERE status = 'ready';

CREATE TABLE public.post_embedding_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  input_hash TEXT NOT NULL CHECK (input_hash ~ '^[0-9a-f]{64}$'),
  embedding_version TEXT NOT NULL,
  model TEXT NOT NULL,
  input_format_version INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'ready', 'failed', 'superseded')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 12),
  next_retry_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  locked_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(post_id, input_hash, embedding_version)
);

CREATE INDEX post_embedding_jobs_work_idx
  ON public.post_embedding_jobs(status, next_retry_at, created_at, id)
  WHERE status IN ('pending', 'processing', 'failed');

ALTER TABLE public.post_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_embedding_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.post_embeddings, public.post_embedding_jobs
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.post_embeddings, public.post_embedding_jobs TO service_role;

CREATE OR REPLACE FUNCTION public.recommendation_embedding_input(
  p_post_id UUID
)
RETURNS TABLE (
  embedding_input TEXT,
  input_hash TEXT,
  embedding_version TEXT,
  model TEXT,
  input_format_version INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
  SELECT
    'task: sentence similarity | query: '
      || 'Title: ' || COALESCE(NULLIF(BTRIM(post_row.title), ''), '')
      || E'\nBody: ' || COALESCE(NULLIF(BTRIM(post_row.description), ''), '')
      || E'\nHashtags: ' || COALESCE('#' || board.name, ''),
    encode(
      extensions.digest(
        convert_to(
          'task: sentence similarity | query: '
            || 'Title: ' || COALESCE(NULLIF(BTRIM(post_row.title), ''), '')
            || E'\nBody: ' || COALESCE(NULLIF(BTRIM(post_row.description), ''), '')
            || E'\nHashtags: ' || COALESCE('#' || board.name, ''),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    ),
    config.embedding_version,
    config.embedding_model,
    config.input_format_version
  FROM public.posts post_row
  JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
  JOIN public.forum_boards board ON board.id = forum_row.board_id
  CROSS JOIN public.recommendation_configuration config
  WHERE config.singleton
    AND post_row.id = p_post_id
    AND post_row.type = 'forum'
    AND post_row.status = 'active'
    AND board.status <> 'archived'
    AND (
      NULLIF(BTRIM(post_row.title), '') IS NOT NULL
      OR NULLIF(BTRIM(post_row.description), '') IS NOT NULL
    );
$$;

REVOKE ALL ON FUNCTION public.recommendation_embedding_input(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recommendation_embedding_input(UUID)
  TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_forum_post_embedding(
  p_post_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_input RECORD;
  v_job_id UUID;
BEGIN
  SELECT * INTO v_input
  FROM public.recommendation_embedding_input(p_post_id);

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.post_embeddings (
    post_id, embedding_version, model, input_format_version, input_hash,
    status, embedding, generated_at, updated_at, last_error
  )
  VALUES (
    p_post_id, v_input.embedding_version, v_input.model,
    v_input.input_format_version, v_input.input_hash,
    'pending', NULL, NULL, clock_timestamp(), NULL
  )
  ON CONFLICT (post_id, embedding_version) DO UPDATE
  SET
    model = EXCLUDED.model,
    input_format_version = EXCLUDED.input_format_version,
    input_hash = EXCLUDED.input_hash,
    status = CASE
      WHEN public.post_embeddings.input_hash = EXCLUDED.input_hash
           AND public.post_embeddings.status = 'ready'
        THEN 'ready'
      ELSE 'pending'
    END,
    embedding = CASE
      WHEN public.post_embeddings.input_hash = EXCLUDED.input_hash
           AND public.post_embeddings.status = 'ready'
        THEN public.post_embeddings.embedding
      ELSE NULL
    END,
    generated_at = CASE
      WHEN public.post_embeddings.input_hash = EXCLUDED.input_hash
           AND public.post_embeddings.status = 'ready'
        THEN public.post_embeddings.generated_at
      ELSE NULL
    END,
    updated_at = clock_timestamp(),
    last_error = NULL;

  IF EXISTS (
    SELECT 1 FROM public.post_embeddings current_embedding
    WHERE current_embedding.post_id = p_post_id
      AND current_embedding.embedding_version = v_input.embedding_version
      AND current_embedding.input_hash = v_input.input_hash
      AND current_embedding.status = 'ready'
  ) THEN
    RETURN NULL;
  END IF;

  UPDATE public.post_embedding_jobs old_job
  SET status = 'superseded', updated_at = clock_timestamp()
  WHERE old_job.post_id = p_post_id
    AND old_job.embedding_version = v_input.embedding_version
    AND old_job.input_hash <> v_input.input_hash
    AND old_job.status IN ('pending', 'processing', 'ready', 'failed');

  INSERT INTO public.post_embedding_jobs (
    post_id, input_hash, embedding_version, model, input_format_version
  )
  VALUES (
    p_post_id, v_input.input_hash, v_input.embedding_version,
    v_input.model, v_input.input_format_version
  )
  ON CONFLICT (post_id, input_hash, embedding_version) DO UPDATE
  SET
    status = CASE
      WHEN public.post_embedding_jobs.status = 'ready' THEN 'ready'
      WHEN public.post_embedding_jobs.status = 'processing' THEN 'processing'
      ELSE 'pending'
    END,
    next_retry_at = CASE
      WHEN public.post_embedding_jobs.status IN ('ready', 'processing')
        THEN public.post_embedding_jobs.next_retry_at
      ELSE clock_timestamp()
    END,
    locked_at = CASE
      WHEN public.post_embedding_jobs.status = 'processing'
        THEN public.post_embedding_jobs.locked_at
      ELSE NULL
    END,
    last_error = NULL,
    updated_at = clock_timestamp()
  RETURNING id INTO v_job_id;

  RETURN v_job_id;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_forum_post_embedding(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_forum_post_embedding(UUID)
  TO service_role;

CREATE OR REPLACE FUNCTION public.trg_enqueue_forum_post_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
BEGIN
  PERFORM public.enqueue_forum_post_embedding(COALESCE(NEW.id, OLD.id));
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_posts_enqueue_forum_embedding
AFTER INSERT OR UPDATE OF title, description, status ON public.posts
FOR EACH ROW
WHEN (NEW.type = 'forum')
EXECUTE FUNCTION public.trg_enqueue_forum_post_embedding();

CREATE TRIGGER trg_forum_posts_enqueue_embedding
AFTER INSERT OR UPDATE OF board_id ON public.forum_posts
FOR EACH ROW
EXECUTE FUNCTION public.trg_enqueue_forum_post_embedding();

CREATE OR REPLACE FUNCTION public.trg_enqueue_forum_board_embeddings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE v_post_id UUID;
BEGIN
  FOR v_post_id IN
    SELECT forum.id FROM public.forum_posts forum WHERE forum.board_id = NEW.id
  LOOP
    PERFORM public.enqueue_forum_post_embedding(v_post_id);
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_boards_enqueue_embeddings
AFTER UPDATE OF name ON public.forum_boards
FOR EACH ROW
WHEN (OLD.name IS DISTINCT FROM NEW.name)
EXECUTE FUNCTION public.trg_enqueue_forum_board_embeddings();

REVOKE ALL ON FUNCTION public.trg_enqueue_forum_post_embedding(),
  public.trg_enqueue_forum_board_embeddings()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.claim_post_embedding_jobs(
  p_limit INTEGER DEFAULT 8
)
RETURNS TABLE (
  job_id UUID,
  post_id UUID,
  input_hash TEXT,
  embedding_version TEXT,
  model TEXT,
  input_format_version INTEGER,
  embedding_input TEXT,
  attempt INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH claimable AS (
    SELECT job.id
    FROM public.post_embedding_jobs job
    WHERE job.attempts < 12
      AND (
        (job.status IN ('pending', 'failed') AND job.next_retry_at <= clock_timestamp())
        OR (job.status = 'processing' AND job.locked_at < clock_timestamp() - INTERVAL '5 minutes')
      )
    ORDER BY job.next_retry_at, job.created_at, job.id
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 8), 32))
  ), claimed AS (
    UPDATE public.post_embedding_jobs job
    SET
      status = 'processing',
      attempts = job.attempts + 1,
      locked_at = clock_timestamp(),
      updated_at = clock_timestamp(),
      last_error = NULL
    FROM claimable
    WHERE job.id = claimable.id
    RETURNING job.*
  )
  SELECT
    claimed.id,
    claimed.post_id,
    claimed.input_hash,
    claimed.embedding_version,
    claimed.model,
    claimed.input_format_version,
    current_input.embedding_input,
    claimed.attempts
  FROM claimed
  JOIN LATERAL public.recommendation_embedding_input(claimed.post_id)
    current_input ON current_input.input_hash = claimed.input_hash
      AND current_input.embedding_version = claimed.embedding_version;

  UPDATE public.post_embedding_jobs job
  SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
  WHERE job.status = 'processing'
    AND job.locked_at >= clock_timestamp() - INTERVAL '1 minute'
    AND NOT EXISTS (
      SELECT 1
      FROM public.recommendation_embedding_input(job.post_id) current_input
      WHERE current_input.input_hash = job.input_hash
        AND current_input.embedding_version = job.embedding_version
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_post_embedding_job(
  p_job_id UUID,
  p_input_hash TEXT,
  p_embedding REAL[],
  p_norm DOUBLE PRECISION
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_job public.post_embedding_jobs%ROWTYPE;
  v_actual_norm DOUBLE PRECISION;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  SELECT SQRT(SUM(value::DOUBLE PRECISION * value::DOUBLE PRECISION))
  INTO v_actual_norm
  FROM unnest(p_embedding) AS item(value);

  IF COALESCE(array_length(p_embedding, 1), 0) <> 768
     OR p_norm IS NULL
     OR ABS(p_norm - 1.0) > 0.01
     OR v_actual_norm IS NULL
     OR ABS(v_actual_norm - 1.0) > 0.01
     OR v_actual_norm >= 'Infinity'::DOUBLE PRECISION
     OR v_actual_norm = 'NaN'::DOUBLE PRECISION
  THEN
    RAISE EXCEPTION 'Embedding norm or dimension invalid' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_job
  FROM public.post_embedding_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND OR v_job.status <> 'processing'
     OR v_job.input_hash IS DISTINCT FROM p_input_hash
  THEN
    RETURN FALSE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.recommendation_embedding_input(v_job.post_id) current_input
    WHERE current_input.input_hash = v_job.input_hash
      AND current_input.embedding_version = v_job.embedding_version
      AND current_input.model = v_job.model
      AND current_input.input_format_version = v_job.input_format_version
  ) THEN
    UPDATE public.post_embedding_jobs
    SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
    WHERE id = p_job_id;
    RETURN FALSE;
  END IF;

  INSERT INTO public.post_embeddings (
    post_id, embedding_version, embedding, model, input_format_version,
    input_hash, status, generated_at, updated_at, last_error
  )
  VALUES (
    v_job.post_id, v_job.embedding_version, p_embedding::extensions.vector(768),
    v_job.model, v_job.input_format_version, v_job.input_hash, 'ready',
    clock_timestamp(), clock_timestamp(), NULL
  )
  ON CONFLICT (post_id, embedding_version) DO UPDATE
  SET
    embedding = EXCLUDED.embedding,
    model = EXCLUDED.model,
    input_format_version = EXCLUDED.input_format_version,
    input_hash = EXCLUDED.input_hash,
    status = 'ready',
    generated_at = EXCLUDED.generated_at,
    updated_at = EXCLUDED.updated_at,
    last_error = NULL
  WHERE public.post_embeddings.input_hash = EXCLUDED.input_hash;

  IF NOT FOUND THEN
    UPDATE public.post_embedding_jobs
    SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
    WHERE id = p_job_id;
    RETURN FALSE;
  END IF;

  UPDATE public.post_embedding_jobs
  SET status = 'ready', locked_at = NULL, updated_at = clock_timestamp()
  WHERE id = p_job_id;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_post_embedding_job(
  p_job_id UUID,
  p_error TEXT,
  p_retryable BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_attempts INTEGER;
  v_post_id UUID;
  v_version TEXT;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.post_embedding_jobs job
  SET
    status = 'failed',
    next_retry_at = CASE
      WHEN p_retryable AND job.attempts < 12 THEN
        clock_timestamp() + LEAST(
          INTERVAL '24 hours',
          POWER(2, LEAST(job.attempts, 10)) * INTERVAL '1 minute'
        )
      ELSE 'infinity'::TIMESTAMPTZ
    END,
    locked_at = NULL,
    last_error = LEFT(COALESCE(NULLIF(BTRIM(p_error), ''), 'unknown'), 240),
    updated_at = clock_timestamp()
  WHERE job.id = p_job_id
    AND job.status = 'processing'
  RETURNING job.attempts, job.post_id, job.embedding_version
    INTO v_attempts, v_post_id, v_version;

  IF FOUND AND (NOT p_retryable OR v_attempts >= 12) THEN
    UPDATE public.post_embeddings
    SET
      status = 'failed',
      embedding = NULL,
      last_error = LEFT(COALESCE(NULLIF(BTRIM(p_error), ''), 'unknown'), 240),
      updated_at = clock_timestamp()
    WHERE post_id = v_post_id AND embedding_version = v_version;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.backfill_forum_embedding_jobs(
  p_limit INTEGER DEFAULT 100
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_post RECORD;
  v_count INTEGER := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  FOR v_post IN
    SELECT post_row.id
    FROM public.posts post_row
    JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
    JOIN public.forum_boards board ON board.id = forum_row.board_id
    CROSS JOIN public.recommendation_configuration config
    LEFT JOIN public.post_embeddings embedding
      ON embedding.post_id = post_row.id
      AND embedding.embedding_version = config.embedding_version
    WHERE post_row.type = 'forum'
      AND post_row.status = 'active'
      AND board.status <> 'archived'
      AND (
        embedding.post_id IS NULL
        OR embedding.status <> 'ready'
        OR embedding.input_hash IS DISTINCT FROM (
          SELECT input_hash
          FROM public.recommendation_embedding_input(post_row.id)
        )
      )
    ORDER BY post_row.created_at, post_row.id
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 500))
  LOOP
    PERFORM public.enqueue_forum_post_embedding(v_post.id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_post_embedding_jobs(INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_post_embedding_job(UUID, TEXT, REAL[], DOUBLE PRECISION)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_post_embedding_job(UUID, TEXT, BOOLEAN)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.backfill_forum_embedding_jobs(INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_post_embedding_jobs(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_post_embedding_job(UUID, TEXT, REAL[], DOUBLE PRECISION)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_post_embedding_job(UUID, TEXT, BOOLEAN)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.backfill_forum_embedding_jobs(INTEGER)
  TO service_role;

COMMIT;
