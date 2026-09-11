-- Recommendation V2: additive classifier/eligibility metadata; all switches OFF.
-- No posts, embeddings, signals, weights or historical migrations are removed.
-- Order: apply schema -> register reviewed artifact -> backfill scores -> shadow
-- validation -> supported-client controlled rollout, only after real-data approval.
-- Rollback: set gate_enabled=false (no redeploy). Filtered sessions cannot be reused.
-- Keep metadata during rollback. Dropping it would lose scores/audit history;
-- export those tables and preserve immutable origin IDs before any destructive undo.
BEGIN;

CREATE SCHEMA recommendation_private;
REVOKE ALL ON SCHEMA recommendation_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA recommendation_private TO service_role;

CREATE FUNCTION recommendation_private.valid_model(a JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp AS $$
DECLARE v JSONB; n DOUBLE PRECISION;
BEGIN
  IF jsonb_typeof(a) IS DISTINCT FROM 'object'
     OR a->'schema_version' IS DISTINCT FROM '1'::JSONB
     OR a->>'model_name' IS DISTINCT FROM 'cross-school-logistic'
     OR a->>'embedding_model' IS DISTINCT FROM 'gemini-embedding-2'
     OR a->>'embedding_version' IS DISTINCT FROM 'cheese-semantic-v1'
     OR a->'dimension' IS DISTINCT FROM '768'::JSONB
     OR a->'input_format_version' IS DISTINCT FROM '1'::JSONB
     OR COALESCE(a->>'version', '') !~ '^v1(-[a-z0-9]+)*$'
     OR jsonb_typeof(a->'weights') IS DISTINCT FROM 'array'
     OR jsonb_typeof(a->'bias') IS DISTINCT FROM 'number'
     OR jsonb_typeof(a->'threshold') IS DISTINCT FROM 'number'
     OR jsonb_typeof(a->'metrics') IS DISTINCT FROM 'object'
     OR COALESCE(a->>'dataset_version', '') = ''
     OR COALESCE(a->>'threshold_version', '') = ''
     OR COALESCE(a->>'trained_at', '') !~ '(Z|[+-][0-9]{2}:[0-9]{2})$'
  THEN RETURN FALSE; END IF;
  IF jsonb_array_length(a->'weights') <> 768 THEN RETURN FALSE; END IF;
  PERFORM (a->>'trained_at')::TIMESTAMPTZ;
  FOR v IN SELECT value FROM jsonb_array_elements(a->'weights')
           UNION ALL SELECT a->'bias'
  LOOP
    IF jsonb_typeof(v) IS DISTINCT FROM 'number' THEN RETURN FALSE; END IF;
    n := v::TEXT::DOUBLE PRECISION;
    IF NOT (n > '-Infinity'::DOUBLE PRECISION AND n < 'Infinity'::DOUBLE PRECISION)
    THEN RETURN FALSE; END IF;
  END LOOP;
  n := (a->>'threshold')::DOUBLE PRECISION;
  RETURN n BETWEEN 0 AND 1;
EXCEPTION WHEN OTHERS THEN RETURN FALSE;
END;
$$;

CREATE FUNCTION recommendation_private.sigmoid(z DOUBLE PRECISION)
RETURNS DOUBLE PRECISION LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF z IS NULL OR NOT (z > '-Infinity'::DOUBLE PRECISION AND z < 'Infinity'::DOUBLE PRECISION)
  THEN RETURN NULL; END IF;
  -- PostgreSQL exp can raise underflow; these limits are at double saturation.
  IF z > 700 THEN RETURN 1; ELSIF z < -700 THEN RETURN 0; END IF;
  IF z >= 0 THEN RETURN 1 / (1 + exp(-z)); END IF;
  RETURN exp(z) / (1 + exp(z));
END;
$$;

CREATE FUNCTION recommendation_private.predict(a JSONB, x extensions.vector)
RETURNS DOUBLE PRECISION LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, public, extensions, pg_temp AS $$
DECLARE values_array REAL[]; weights DOUBLE PRECISION[]; z DOUBLE PRECISION; norm DOUBLE PRECISION := 0; i INTEGER;
BEGIN
  IF NOT recommendation_private.valid_model(a) OR x IS NULL OR extensions.vector_dims(x) <> 768
  THEN RETURN NULL; END IF;
  values_array := x::REAL[];
  SELECT array_agg(value::TEXT::DOUBLE PRECISION ORDER BY ordinal)
    INTO weights FROM jsonb_array_elements(a->'weights') WITH ORDINALITY t(value, ordinal);
  z := (a->>'bias')::DOUBLE PRECISION;
  FOR i IN 1..768 LOOP
    norm := norm + values_array[i]::DOUBLE PRECISION * values_array[i]::DOUBLE PRECISION;
    z := z + weights[i] * values_array[i]::DOUBLE PRECISION;
  END LOOP;
  IF abs(sqrt(norm) - 1) > 0.0001 THEN RETURN NULL; END IF;
  RETURN recommendation_private.sigmoid(z);
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$;

CREATE TABLE public.cross_school_models (
  version TEXT PRIMARY KEY,
  artifact JSONB NOT NULL CHECK (recommendation_private.valid_model(artifact)),
  approved_for_filtering BOOLEAN NOT NULL DEFAULT FALSE,
  registered_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK (version = artifact->>'version')
);
CREATE TABLE public.cross_school_configuration (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  model_version TEXT REFERENCES public.cross_school_models(version),
  scoring_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  shadow_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  gate_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  rollout_percentage INTEGER NOT NULL DEFAULT 0 CHECK (rollout_percentage BETWEEN 0 AND 100),
  shadow_sample_percentage INTEGER NOT NULL DEFAULT 5 CHECK (shadow_sample_percentage BETWEEN 0 AND 100),
  threshold DOUBLE PRECISION NOT NULL DEFAULT 0.55 CHECK (threshold BETWEEN 0 AND 1),
  threshold_version TEXT NOT NULL DEFAULT 'unconfigured' CHECK (length(threshold_version) BETWEEN 1 AND 160),
  revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0)
);
INSERT INTO public.cross_school_configuration(singleton) VALUES (TRUE);

ALTER TABLE public.forum_posts ADD COLUMN origin_school_id UUID REFERENCES public.schools(id);
UPDATE public.forum_posts f SET origin_school_id = p.school_id FROM public.posts p WHERE p.id = f.id;
-- Existing deferred publication checks must finish before further forum DDL.
SET CONSTRAINTS ALL IMMEDIATE;
CREATE INDEX forum_posts_origin_school_idx ON public.forum_posts(origin_school_id);
ALTER TABLE public.post_embeddings ADD COLUMN cross_school_revision BIGINT NOT NULL DEFAULT 0;
CREATE FUNCTION recommendation_private.embedding_revision()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = pg_catalog, public, extensions, pg_temp AS $$
BEGIN
  NEW.cross_school_revision := OLD.cross_school_revision;
  IF (NEW.embedding, NEW.status, NEW.input_hash, NEW.model, NEW.embedding_version, NEW.input_format_version)
      IS DISTINCT FROM
     (OLD.embedding, OLD.status, OLD.input_hash, OLD.model, OLD.embedding_version, OLD.input_format_version) THEN
    NEW.cross_school_revision := OLD.cross_school_revision + 1;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_embedding_revision BEFORE UPDATE ON public.post_embeddings
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.embedding_revision();
CREATE FUNCTION recommendation_private.freeze_origin()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT p.school_id INTO NEW.origin_school_id FROM public.posts p WHERE p.id = NEW.id;
  ELSIF NEW.origin_school_id IS DISTINCT FROM OLD.origin_school_id THEN
    RAISE EXCEPTION 'Forum origin school is immutable' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_freeze_origin BEFORE INSERT OR UPDATE OF origin_school_id
  ON public.forum_posts FOR EACH ROW EXECUTE FUNCTION recommendation_private.freeze_origin();

CREATE TABLE public.cross_school_scores (
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  model_version TEXT NOT NULL REFERENCES public.cross_school_models(version),
  embedding_version TEXT NOT NULL,
  embedding_revision BIGINT NOT NULL,
  input_hash TEXT NOT NULL CHECK (input_hash ~ '^[0-9a-f]{64}$'),
  probability DOUBLE PRECISION CHECK (probability BETWEEN 0 AND 1),
  failure_reason TEXT CHECK (failure_reason IN ('invalid_embedding', 'scoring_error')),
  scored_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (post_id, model_version),
  CHECK ((probability IS NULL) = (failure_reason IS NOT NULL))
);
CREATE INDEX cross_school_scores_model_idx ON public.cross_school_scores(model_version, post_id);

CREATE FUNCTION recommendation_private.guard_configuration()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF (NEW.scoring_enabled OR NEW.shadow_enabled OR NEW.gate_enabled) AND NEW.model_version IS NULL THEN
    RAISE EXCEPTION 'An explicit compatible model is required';
  END IF;
  IF NEW.gate_enabled AND (NOT NEW.scoring_enabled OR NEW.threshold_version = 'unconfigured'
      OR NOT EXISTS (SELECT 1 FROM public.cross_school_models m
          WHERE m.version = NEW.model_version AND m.approved_for_filtering)) THEN
    RAISE EXCEPTION 'Filtering requires explicit model approval, scoring and versioned threshold';
  END IF;
  NEW.revision := OLD.revision + 1;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_configuration_revision BEFORE UPDATE ON public.cross_school_configuration
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.guard_configuration();
CREATE FUNCTION recommendation_private.immutable_model()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.version IS DISTINCT FROM OLD.version OR NEW.artifact IS DISTINCT FROM OLD.artifact THEN
    RAISE EXCEPTION 'Model artifact/version is immutable; register a new version';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_model_immutable BEFORE UPDATE ON public.cross_school_models
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.immutable_model();

CREATE FUNCTION recommendation_private.score_post(p_post_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp AS $$
DECLARE c public.cross_school_configuration%ROWTYPE; e public.post_embeddings%ROWTYPE;
  a JSONB; q DOUBLE PRECISION;
BEGIN
  SELECT * INTO c FROM public.cross_school_configuration WHERE singleton;
  IF NOT c.scoring_enabled OR c.model_version IS NULL THEN RETURN FALSE; END IF;
  SELECT artifact INTO a FROM public.cross_school_models WHERE version = c.model_version;
  SELECT * INTO e FROM public.post_embeddings WHERE post_id = p_post_id
    AND embedding_version = 'cheese-semantic-v1' AND model = 'gemini-embedding-2'
    AND input_format_version = 1 AND status = 'ready';
  IF e.post_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.forum_posts WHERE id = p_post_id) THEN RETURN FALSE; END IF;
  IF EXISTS (SELECT 1 FROM public.cross_school_scores s WHERE s.post_id = p_post_id
    AND s.model_version = c.model_version AND s.embedding_version = e.embedding_version
    AND s.embedding_revision = e.cross_school_revision
    AND s.input_hash = e.input_hash) THEN RETURN FALSE; END IF;
  q := recommendation_private.predict(a, e.embedding);
  INSERT INTO public.cross_school_scores(post_id, model_version, embedding_version, embedding_revision, input_hash, probability, failure_reason)
  VALUES (p_post_id, c.model_version, e.embedding_version, e.cross_school_revision, e.input_hash, q,
          CASE WHEN q IS NULL THEN 'invalid_embedding' END)
  ON CONFLICT (post_id, model_version) DO UPDATE SET embedding_version = EXCLUDED.embedding_version,
    embedding_revision = EXCLUDED.embedding_revision,
    input_hash = EXCLUDED.input_hash, probability = EXCLUDED.probability,
    failure_reason = EXCLUDED.failure_reason, scored_at = clock_timestamp();
  RETURN q IS NOT NULL;
END;
$$;
CREATE FUNCTION recommendation_private.score_embedding_trigger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  BEGIN
    PERFORM recommendation_private.score_post(NEW.post_id);
  EXCEPTION WHEN OTHERS THEN
    -- Never roll back a successful V1 embedding because a new classifier failed.
    -- Gate joins exact input hash, so a stale/absent cache fails closed.
    RAISE LOG 'cross_school_scoring_failure';
  END;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_score_embedding AFTER INSERT OR UPDATE ON public.post_embeddings
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.score_embedding_trigger();

CREATE FUNCTION public.backfill_cross_school_scores(p_limit INTEGER DEFAULT 100)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE r RECORD; n INTEGER := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501'; END IF;
  FOR r IN SELECT e.post_id FROM public.post_embeddings e
    JOIN public.forum_posts f ON f.id = e.post_id
    CROSS JOIN public.cross_school_configuration c
    WHERE c.singleton AND c.scoring_enabled AND e.status = 'ready'
      AND e.embedding_version = 'cheese-semantic-v1' AND e.model = 'gemini-embedding-2' AND e.input_format_version = 1
      AND NOT EXISTS (SELECT 1 FROM public.cross_school_scores s WHERE s.post_id = e.post_id
        AND s.model_version = c.model_version AND s.input_hash = e.input_hash
        AND s.embedding_version = e.embedding_version
        AND s.embedding_revision = e.cross_school_revision)
    ORDER BY e.post_id LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 500))
  LOOP
    BEGIN
      IF recommendation_private.score_post(r.post_id) THEN n := n + 1; END IF;
    EXCEPTION WHEN OTHERS THEN RAISE LOG 'cross_school_backfill_failure';
    END;
  END LOOP;
  RETURN n;
END;
$$;

CREATE FUNCTION recommendation_private.gate_active(p_user_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT COALESCE((SELECT c.gate_enabled
    AND (auth.role() = 'service_role' OR
      COALESCE(NULLIF(current_setting('request.headers', TRUE), ''), '{}')::JSONB
        ->>'x-cheese-recommendation-contract' = '2')
    AND MOD(hashtextextended(p_user_id::TEXT, 20260909) & 9223372036854775807, 100) < c.rollout_percentage
    AND MOD(hashtextextended(p_user_id::TEXT, 20260830) & 9223372036854775807, 100) < v.rollout_percentage
    FROM public.cross_school_configuration c CROSS JOIN public.recommendation_configuration v
    WHERE c.singleton AND v.singleton), FALSE);
$$;

CREATE FUNCTION recommendation_private.decision(p_post_id UUID, p_user_id UUID)
RETURNS TABLE(origin_school_id UUID, viewer_school_id UUID, probability DOUBLE PRECISION, would_allow BOOLEAN, reason TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
  WITH data AS (
    SELECT f.origin_school_id AS origin_id, u.school_id AS viewer_id, c.threshold,
      CASE WHEN e.status = 'ready' AND e.model = 'gemini-embedding-2' AND e.input_format_version = 1
        AND s.input_hash = e.input_hash AND s.embedding_version = e.embedding_version
        AND s.embedding_revision = e.cross_school_revision
        AND s.failure_reason IS NULL THEN s.probability END AS q
    FROM public.cross_school_configuration c
    LEFT JOIN public.forum_posts f ON f.id = p_post_id
    LEFT JOIN public.profiles u ON u.id = p_user_id
    LEFT JOIN public.post_embeddings e ON e.post_id = f.id AND e.embedding_version = 'cheese-semantic-v1'
    LEFT JOIN public.cross_school_scores s ON s.post_id = f.id AND s.model_version = c.model_version
    WHERE c.singleton
  ) SELECT origin_id, viewer_id, q,
    CASE WHEN origin_id IS NOT NULL AND origin_id = viewer_id THEN TRUE
      WHEN origin_id IS NULL OR viewer_id IS NULL THEN FALSE
      ELSE COALESCE(q >= threshold AND q BETWEEN 0 AND 1, FALSE) END,
    CASE WHEN origin_id IS NOT NULL AND origin_id = viewer_id THEN 'same_school'
      WHEN origin_id IS NULL OR viewer_id IS NULL THEN 'missing_school'
      WHEN q IS NULL THEN 'missing_or_stale_score'
      WHEN q >= threshold THEN 'cross_allowed' ELSE 'cross_below_threshold' END
  FROM data;
$$;
CREATE FUNCTION recommendation_private.allowed(p_post_id UUID, p_user_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE d RECORD;
BEGIN
  IF NOT recommendation_private.gate_active(p_user_id) THEN RETURN TRUE; END IF;
  SELECT * INTO d FROM recommendation_private.decision(p_post_id, p_user_id);
  IF d.reason = 'same_school' THEN RETURN TRUE; END IF;
  RETURN COALESCE(d.would_allow AND EXISTS (
    SELECT 1 FROM public.cross_school_models m JOIN public.cross_school_configuration c ON c.model_version = m.version
    WHERE c.singleton AND m.approved_for_filtering), FALSE);
END;
$$;

ALTER TABLE public.cross_school_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cross_school_configuration ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cross_school_scores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cross_school_models, public.cross_school_configuration, public.cross_school_scores FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.cross_school_models TO service_role;
GRANT SELECT, UPDATE ON public.cross_school_configuration TO service_role;
GRANT SELECT ON public.cross_school_scores TO service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA recommendation_private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA recommendation_private TO service_role;
REVOKE ALL ON FUNCTION public.backfill_cross_school_scores(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.backfill_cross_school_scores(INTEGER) TO service_role;

ALTER TABLE public.feed_sessions
  ADD COLUMN cross_school_revision BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN cross_school_viewer_school_id UUID REFERENCES public.schools(id);
CREATE FUNCTION recommendation_private.stamp_session()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  SELECT school_id INTO NEW.cross_school_viewer_school_id FROM public.profiles WHERE id = NEW.user_id;
  IF recommendation_private.gate_active(NEW.user_id) THEN
    SELECT revision INTO NEW.cross_school_revision FROM public.cross_school_configuration WHERE singleton;
  ELSE NEW.cross_school_revision := 0;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_stamp_session BEFORE INSERT ON public.feed_sessions
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.stamp_session();

CREATE FUNCTION recommendation_private.session_valid(p_session_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE s public.feed_sessions%ROWTYPE; revision_now BIGINT; school_now UUID;
BEGIN
  SELECT * INTO s FROM public.feed_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  IF NOT recommendation_private.gate_active(s.user_id) THEN RETURN s.cross_school_revision = 0; END IF;
  SELECT revision INTO revision_now FROM public.cross_school_configuration WHERE singleton;
  SELECT school_id INTO school_now FROM public.profiles WHERE id = s.user_id;
  RETURN s.cross_school_revision = revision_now
    AND s.cross_school_viewer_school_id IS NOT DISTINCT FROM school_now
    AND NOT EXISTS (SELECT 1 FROM public.feed_session_items i WHERE i.session_id = s.id
      AND NOT recommendation_private.allowed(i.post_id, s.user_id));
END;
$$;

CREATE TABLE public.cross_school_shadow_decisions (
  session_id UUID NOT NULL REFERENCES public.feed_sessions(id) ON DELETE CASCADE,
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  origin_school_id UUID,
  viewer_school_id UUID,
  probability DOUBLE PRECISION CHECK (probability BETWEEN 0 AND 1),
  threshold DOUBLE PRECISION NOT NULL CHECK (threshold BETWEEN 0 AND 1),
  threshold_version TEXT NOT NULL,
  model_version TEXT NOT NULL,
  would_allow BOOLEAN NOT NULL,
  reason TEXT NOT NULL,
  observed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (session_id, post_id)
);
CREATE INDEX cross_school_shadow_observed_idx ON public.cross_school_shadow_decisions(observed_at);
CREATE INDEX cross_school_shadow_post_idx ON public.cross_school_shadow_decisions(post_id);
ALTER TABLE public.cross_school_shadow_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cross_school_shadow_decisions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cross_school_shadow_decisions TO service_role;

CREATE FUNCTION recommendation_private.observe_item()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE c public.cross_school_configuration%ROWTYPE; viewer UUID;
BEGIN
  BEGIN
    IF NEW.position = 1 THEN
      DELETE FROM public.cross_school_shadow_decisions WHERE (session_id, post_id) IN (
        SELECT session_id, post_id FROM public.cross_school_shadow_decisions
        WHERE observed_at < clock_timestamp() - INTERVAL '7 days' ORDER BY observed_at LIMIT 1000);
    END IF;
    SELECT * INTO c FROM public.cross_school_configuration WHERE singleton;
    IF NOT c.shadow_enabled OR c.model_version IS NULL OR
      MOD(hashtextextended(NEW.session_id::TEXT, 20260909) & 9223372036854775807, 100) >= c.shadow_sample_percentage
    THEN RETURN NEW; END IF;
    SELECT user_id INTO viewer FROM public.feed_sessions WHERE id = NEW.session_id;
    INSERT INTO public.cross_school_shadow_decisions(session_id, post_id, origin_school_id,
      viewer_school_id, probability, threshold, threshold_version, model_version, would_allow, reason)
    SELECT NEW.session_id, NEW.post_id, d.origin_school_id, d.viewer_school_id, d.probability,
      c.threshold, c.threshold_version, c.model_version, d.would_allow, d.reason
    FROM recommendation_private.decision(NEW.post_id, viewer) d
    ON CONFLICT (session_id, post_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN RAISE LOG 'cross_school_shadow_failure';
  END;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cross_school_observe_item AFTER INSERT ON public.feed_session_items
  FOR EACH ROW EXECUTE FUNCTION recommendation_private.observe_item();

CREATE FUNCTION public.get_cross_school_metrics()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp AS $$
DECLARE result JSONB;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501'; END IF;
  WITH c AS (SELECT * FROM public.cross_school_configuration WHERE singleton),
  active AS (SELECT f.id, f.origin_school_id FROM public.forum_posts f JOIN public.posts p ON p.id = f.id
    WHERE p.status = 'active' AND NOT p.is_private),
  scores AS (SELECT s.* FROM public.cross_school_scores s JOIN c ON c.model_version = s.model_version
    JOIN public.post_embeddings e ON e.post_id = s.post_id AND e.embedding_version = s.embedding_version
      AND e.input_hash = s.input_hash AND e.cross_school_revision = s.embedding_revision AND e.status = 'ready'),
  hist AS (SELECT LEAST(9, floor(probability * 10)::INTEGER) AS bin, count(*) AS n
    FROM scores WHERE probability IS NOT NULL GROUP BY 1)
  SELECT jsonb_build_object(
    'model_version', c.model_version, 'threshold', c.threshold, 'threshold_version', c.threshold_version,
    'scored', (SELECT count(*) FROM scores WHERE probability IS NOT NULL),
    'stored_scoring_failures', (SELECT count(*) FROM scores WHERE failure_reason IS NOT NULL),
    'above_threshold', (SELECT count(*) FROM scores WHERE probability >= c.threshold),
    'probability_histogram_deciles', COALESCE((SELECT jsonb_object_agg(bin, n) FROM hist), '{}'::JSONB),
    'active_public_forum_posts', (SELECT count(*) FROM active),
    'missing_origin', (SELECT count(*) FROM active WHERE origin_school_id IS NULL),
    'missing_embedding', (SELECT count(*) FROM active a WHERE NOT EXISTS (
      SELECT 1 FROM public.post_embeddings e WHERE e.post_id = a.id AND e.status = 'ready'
        AND e.embedding_version = 'cheese-semantic-v1' AND e.model = 'gemini-embedding-2' AND e.input_format_version = 1)),
    'dimension_mismatch', (SELECT count(*) FROM public.post_embeddings e WHERE e.status = 'ready'
      AND extensions.vector_dims(e.embedding) <> 768),
    'shadow_population', 'sampled V1 shaped session items; not all eligible posts',
    'shadow_foreign_allowed_7d', (SELECT count(*) FROM public.cross_school_shadow_decisions d
      WHERE observed_at >= clock_timestamp() - INTERVAL '7 days' AND d.model_version = c.model_version
        AND d.threshold_version = c.threshold_version AND d.origin_school_id <> d.viewer_school_id AND d.would_allow),
    'shadow_foreign_rejected_7d', (SELECT count(*) FROM public.cross_school_shadow_decisions d
      WHERE observed_at >= clock_timestamp() - INTERVAL '7 days' AND d.model_version = c.model_version
        AND d.threshold_version = c.threshold_version AND d.origin_school_id <> d.viewer_school_id AND NOT d.would_allow)
  ) INTO result FROM c;
  RETURN result;
END;
$$;

-- Exact audited V1 bodies are a precondition: abort rather than overwrite a drifted ranker.
DO $patch$
DECLARE definition TEXT;
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure)
       <> '2710a9a30cb117ba176d2f507ae5201b'
     OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure)
       <> '65e602fc1507e513b7814e17622e5df0'
     OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.get_recommendation_feed_page(uuid,integer,integer)'::regprocedure)
       <> '53af1f9501fa51a589268a6061796b48' THEN
    RAISE EXCEPTION 'V1 baseline drifted: re-audit before inserting V2';
  END IF;
  SELECT pg_get_functiondef('public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure) INTO definition;
  definition := replace(definition, 'AND post_row.is_private = FALSE',
    'AND post_row.is_private = FALSE' || E'\n      AND recommendation_private.allowed(post_row.id, p_user_id)');
  EXECUTE definition;
  SELECT pg_get_functiondef('public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure) INTO definition;
  definition := replace(definition, 'AND session.expires_at > clock_timestamp()',
    'AND session.expires_at > clock_timestamp() AND recommendation_private.session_valid(session.id)');
  definition := replace(definition, 'AND post_row.is_private = FALSE AND post_row.user_id <> v_me',
    'AND post_row.is_private = FALSE AND post_row.user_id <> v_me AND recommendation_private.allowed(post_row.id, v_me)');
  -- Hold policy stable across ranking's existing three shaping passes.
  definition := replace(definition, 'SELECT * INTO v_config FROM public.recommendation_configuration WHERE singleton;',
    'PERFORM 1 FROM public.cross_school_configuration WHERE singleton FOR SHARE;' || E'\n  SELECT * INTO v_config FROM public.recommendation_configuration WHERE singleton;');
  EXECUTE definition;
END;
$patch$;

-- Extra composite attribute is backward-compatible with decoders ignoring unknown fields.
ALTER TYPE public.recommendation_feed_mode ADD ATTRIBUTE cross_school_gate_enabled BOOLEAN;
DO $patch$
DECLARE definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.get_recommendation_feed_mode()'::regprocedure) INTO definition;
  IF strpos(definition, 'RETURN v_result;') = 0 THEN RAISE EXCEPTION 'Unexpected V1 mode body'; END IF;
  EXECUTE replace(definition, 'RETURN v_result;',
    'v_result.cross_school_gate_enabled := recommendation_private.gate_active(v_me); RETURN v_result;');
END;
$patch$;

CREATE OR REPLACE FUNCTION public.get_recommendation_feed_page(
  p_session_id UUID, p_offset INTEGER DEFAULT 0, p_limit INTEGER DEFAULT 20
)
RETURNS TABLE(session_id UUID, post_id UUID, "position" INTEGER)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.feed_sessions s WHERE s.id = p_session_id
      AND s.user_id = auth.uid() AND NOT s.is_shadow AND s.expires_at > clock_timestamp())
     AND NOT recommendation_private.session_valid(p_session_id) THEN
    RAISE EXCEPTION 'recommendation_session_stale' USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY SELECT item.session_id, item.post_id, item.position
  FROM public.feed_session_items item JOIN public.feed_sessions session ON session.id = item.session_id
  WHERE session.id = p_session_id AND session.user_id = auth.uid()
    AND session.is_shadow = FALSE AND session.expires_at > clock_timestamp()
  ORDER BY item.position
  OFFSET GREATEST(0, COALESCE(p_offset, 0)) LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 20));
END;
$$;

-- Client-side featured content must use this same gate, never a second classifier.
CREATE FUNCTION public.filter_cross_school_recommendation_posts(p_post_ids UUID[])
RETURNS SETOF UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;
  IF cardinality(p_post_ids) > 100 THEN RAISE EXCEPTION 'At most 100 posts'; END IF;
  RETURN QUERY SELECT p.id FROM public.posts p WHERE p.id = ANY(p_post_ids)
    AND p.type = 'forum' AND public.can_view_post(p.id)
    AND recommendation_private.allowed(p.id, auth.uid());
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA recommendation_private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA recommendation_private TO service_role;
REVOKE ALL ON FUNCTION public.get_cross_school_metrics() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_cross_school_metrics() TO service_role;
REVOKE ALL ON FUNCTION public.filter_cross_school_recommendation_posts(UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.filter_cross_school_recommendation_posts(UUID[]) TO authenticated, service_role;
COMMIT;
