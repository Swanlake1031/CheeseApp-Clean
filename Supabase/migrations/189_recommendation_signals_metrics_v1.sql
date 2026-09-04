-- Cheese Recommendation System V1: events, derived signal state, profiles,
-- per-user hides, and precomputed post metrics.
-- Existing likes/favorites/comments remain the business source of truth.

BEGIN;

CREATE TABLE public.user_hidden_forum_posts (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX user_hidden_forum_posts_post_idx
  ON public.user_hidden_forum_posts(post_id);

CREATE TABLE public.recommendation_events (
  event_id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  feed_session_id UUID,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'impression', 'qualified_impression', 'meaningful_read', 'open',
    'like', 'unlike', 'save', 'unsave', 'comment', 'reply', 'share', 'hide'
  )),
  feed_position INTEGER CHECK (feed_position IS NULL OR feed_position >= 1),
  algorithm_version TEXT NOT NULL DEFAULT 'cheese-rec-v1',
  ranking_score DOUBLE PRECISION,
  semantic_score DOUBLE PRECISION,
  engagement_score DOUBLE PRECISION,
  freshness_score DOUBLE PRECISION,
  quality_score DOUBLE PRECISION,
  author_score DOUBLE PRECISION,
  exploration_score DOUBLE PRECISION,
  visible_fraction DOUBLE PRECISION CHECK (
    visible_fraction IS NULL OR visible_fraction BETWEEN 0 AND 1
  ),
  dwell_ms INTEGER CHECK (dwell_ms IS NULL OR dwell_ms >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE UNIQUE INDEX recommendation_events_session_dedupe_idx
  ON public.recommendation_events(user_id, post_id, feed_session_id, event_type)
  WHERE feed_session_id IS NOT NULL
    AND event_type IN ('impression', 'qualified_impression', 'meaningful_read', 'open');
CREATE INDEX recommendation_events_post_type_created_idx
  ON public.recommendation_events(post_id, event_type, created_at DESC);
CREATE INDEX recommendation_events_user_post_created_idx
  ON public.recommendation_events(user_id, post_id, created_at DESC);

CREATE TABLE public.user_post_signal_state (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  has_meaningful_read BOOLEAN NOT NULL DEFAULT FALSE,
  is_liked BOOLEAN NOT NULL DEFAULT FALSE,
  is_saved BOOLEAN NOT NULL DEFAULT FALSE,
  has_commented BOOLEAN NOT NULL DEFAULT FALSE,
  has_replied BOOLEAN NOT NULL DEFAULT FALSE,
  effective_weight SMALLINT NOT NULL DEFAULT 0
    CHECK (effective_weight IN (0, 1, 3, 5, 6, 8)),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX user_post_signal_positive_idx
  ON public.user_post_signal_state(user_id, post_id)
  WHERE effective_weight > 0;
CREATE INDEX user_post_signal_state_post_idx
  ON public.user_post_signal_state(post_id);

CREATE TABLE public.user_interest_profiles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  raw_embedding extensions.vector(768),
  normalized_embedding extensions.vector(768),
  total_weight INTEGER NOT NULL DEFAULT 0 CHECK (total_weight >= 0),
  interaction_count INTEGER NOT NULL DEFAULT 0 CHECK (interaction_count >= 0),
  embedding_version TEXT NOT NULL DEFAULT 'cheese-semantic-v1',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK (
    (total_weight = 0 AND raw_embedding IS NULL AND normalized_embedding IS NULL)
    OR (total_weight > 0 AND raw_embedding IS NOT NULL AND normalized_embedding IS NOT NULL)
  )
);

CREATE TABLE public.post_recommendation_metrics (
  post_id UUID PRIMARY KEY REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  qualified_impressions_24h INTEGER NOT NULL DEFAULT 0 CHECK (qualified_impressions_24h >= 0),
  likes_24h INTEGER NOT NULL DEFAULT 0 CHECK (likes_24h >= 0),
  comments_24h INTEGER NOT NULL DEFAULT 0 CHECK (comments_24h >= 0),
  saves_24h INTEGER NOT NULL DEFAULT 0 CHECK (saves_24h >= 0),
  shares_24h INTEGER NOT NULL DEFAULT 0 CHECK (shares_24h >= 0),
  e_raw DOUBLE PRECISION NOT NULL DEFAULT 0,
  e_normalized DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK (e_normalized BETWEEN 0 AND 1),
  unique_commenters INTEGER NOT NULL DEFAULT 0 CHECK (unique_commenters >= 0),
  reply_count INTEGER NOT NULL DEFAULT 0 CHECK (reply_count >= 0),
  total_qualified_impressions INTEGER NOT NULL DEFAULT 0 CHECK (total_qualified_impressions >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.user_hidden_forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recommendation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_post_signal_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_interest_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_recommendation_metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own hidden forum posts"
ON public.user_hidden_forum_posts FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()));
CREATE POLICY "Users can read own recommendation events"
ON public.recommendation_events FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON TABLE public.user_hidden_forum_posts,
  public.recommendation_events, public.user_post_signal_state,
  public.user_interest_profiles, public.post_recommendation_metrics
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.user_hidden_forum_posts, public.recommendation_events
  TO authenticated;
GRANT ALL ON public.user_hidden_forum_posts, public.recommendation_events,
  public.user_post_signal_state, public.user_interest_profiles,
  public.post_recommendation_metrics TO service_role;

CREATE OR REPLACE FUNCTION public.rebuild_user_interest_profile(
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_config public.recommendation_configuration%ROWTYPE;
  v_sum REAL[] := array_fill(0::REAL, ARRAY[768]);
  v_values REAL[];
  v_signal RECORD;
  v_norm DOUBLE PRECISION := 0;
  v_total_weight INTEGER := 0;
  v_interaction_count INTEGER := 0;
BEGIN
  IF p_user_id IS NULL THEN RETURN; END IF;
  SELECT * INTO v_config FROM public.recommendation_configuration WHERE singleton;

  FOR v_signal IN
    SELECT state.effective_weight, embedding.embedding
    FROM public.user_post_signal_state state
    JOIN public.post_embeddings embedding
      ON embedding.post_id = state.post_id
      AND embedding.embedding_version = v_config.embedding_version
      AND embedding.model = v_config.embedding_model
      AND embedding.input_format_version = v_config.input_format_version
      AND embedding.status = 'ready'
    WHERE state.user_id = p_user_id
      AND state.effective_weight > 0
  LOOP
    v_values := v_signal.embedding::REAL[];
    FOR v_index IN 1..768 LOOP
      v_sum[v_index] := v_sum[v_index]
        + v_signal.effective_weight * v_values[v_index];
    END LOOP;
    v_total_weight := v_total_weight + v_signal.effective_weight;
    v_interaction_count := v_interaction_count + 1;
  END LOOP;

  IF v_total_weight = 0 THEN
    INSERT INTO public.user_interest_profiles (
      user_id, raw_embedding, normalized_embedding, total_weight,
      interaction_count, embedding_version, updated_at
    ) VALUES (
      p_user_id, NULL, NULL, 0, 0, v_config.embedding_version, clock_timestamp()
    )
    ON CONFLICT (user_id) DO UPDATE
    SET raw_embedding = NULL, normalized_embedding = NULL,
        total_weight = 0, interaction_count = 0,
        embedding_version = EXCLUDED.embedding_version,
        updated_at = EXCLUDED.updated_at;
    RETURN;
  END IF;

  FOR v_index IN 1..768 LOOP
    v_norm := v_norm + v_sum[v_index] * v_sum[v_index];
  END LOOP;
  v_norm := SQRT(v_norm);

  IF v_norm <= 0 OR v_norm >= 'Infinity'::DOUBLE PRECISION
     OR v_norm = 'NaN'::DOUBLE PRECISION THEN
    RAISE EXCEPTION 'User profile vector norm invalid' USING ERRCODE = '22003';
  END IF;

  INSERT INTO public.user_interest_profiles (
    user_id, raw_embedding, normalized_embedding, total_weight,
    interaction_count, embedding_version, updated_at
  ) VALUES (
    p_user_id,
    v_sum::extensions.vector(768),
    (SELECT array_agg((value / v_norm)::REAL ORDER BY ordinal)::extensions.vector(768)
     FROM unnest(v_sum) WITH ORDINALITY AS normalized(value, ordinal)),
    v_total_weight, v_interaction_count, v_config.embedding_version,
    clock_timestamp()
  )
  ON CONFLICT (user_id) DO UPDATE
  SET raw_embedding = EXCLUDED.raw_embedding,
      normalized_embedding = EXCLUDED.normalized_embedding,
      total_weight = EXCLUDED.total_weight,
      interaction_count = EXCLUDED.interaction_count,
      embedding_version = EXCLUDED.embedding_version,
      updated_at = EXCLUDED.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_user_post_signal_state(
  p_user_id UUID,
  p_post_id UUID
)
RETURNS SMALLINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_existing public.user_post_signal_state%ROWTYPE;
  v_read BOOLEAN := FALSE;
  v_liked BOOLEAN;
  v_saved BOOLEAN;
  v_commented BOOLEAN;
  v_replied BOOLEAN;
  v_weight SMALLINT;
BEGIN
  IF p_user_id IS NULL OR p_post_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.forum_posts WHERE id = p_post_id)
  THEN RETURN 0; END IF;

  SELECT * INTO v_existing
  FROM public.user_post_signal_state
  WHERE user_id = p_user_id AND post_id = p_post_id;
  IF FOUND THEN v_read := v_existing.has_meaningful_read; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.likes
    WHERE user_id = p_user_id AND target_type = 'post' AND target_id = p_post_id
  ) INTO v_liked;
  SELECT EXISTS (
    SELECT 1 FROM public.favorites
    WHERE user_id = p_user_id AND post_id = p_post_id
  ) INTO v_saved;
  SELECT EXISTS (
    SELECT 1 FROM public.comments
    WHERE user_id = p_user_id AND post_id = p_post_id
      AND parent_id IS NULL AND is_deleted = FALSE
  ) INTO v_commented;
  SELECT EXISTS (
    SELECT 1 FROM public.comments
    WHERE user_id = p_user_id AND post_id = p_post_id
      AND parent_id IS NOT NULL AND is_deleted = FALSE
  ) INTO v_replied;

  v_weight := CASE
    WHEN v_replied THEN 8
    WHEN v_commented THEN 6
    WHEN v_saved THEN 5
    WHEN v_liked THEN 3
    WHEN v_read THEN 1
    ELSE 0
  END;

  INSERT INTO public.user_post_signal_state (
    user_id, post_id, has_meaningful_read, is_liked, is_saved,
    has_commented, has_replied, effective_weight, updated_at
  ) VALUES (
    p_user_id, p_post_id, v_read, v_liked, v_saved,
    v_commented, v_replied, v_weight, clock_timestamp()
  )
  ON CONFLICT (user_id, post_id) DO UPDATE
  SET has_meaningful_read = EXCLUDED.has_meaningful_read,
      is_liked = EXCLUDED.is_liked,
      is_saved = EXCLUDED.is_saved,
      has_commented = EXCLUDED.has_commented,
      has_replied = EXCLUDED.has_replied,
      effective_weight = EXCLUDED.effective_weight,
      updated_at = EXCLUDED.updated_at;

  PERFORM public.rebuild_user_interest_profile(p_user_id);
  RETURN v_weight;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_rebuild_profiles_for_post_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE v_user_id UUID;
BEGIN
  FOR v_user_id IN
    SELECT DISTINCT state.user_id
    FROM public.user_post_signal_state state
    WHERE state.post_id = NEW.post_id AND state.effective_weight > 0
  LOOP
    PERFORM public.rebuild_user_interest_profile(v_user_id);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_post_embeddings_rebuild_user_profiles
AFTER INSERT OR UPDATE OF status, input_hash, embedding
ON public.post_embeddings
FOR EACH ROW
EXECUTE FUNCTION public.trg_rebuild_profiles_for_post_embedding();

CREATE OR REPLACE FUNCTION public.trg_refresh_recommendation_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF TG_TABLE_NAME = 'likes' THEN
    IF COALESCE(NEW.target_type, OLD.target_type) = 'post' THEN
      PERFORM public.refresh_user_post_signal_state(
        COALESCE(NEW.user_id, OLD.user_id), COALESCE(NEW.target_id, OLD.target_id)
      );
    END IF;
  ELSIF TG_TABLE_NAME = 'favorites' THEN
    PERFORM public.refresh_user_post_signal_state(
      COALESCE(NEW.user_id, OLD.user_id), COALESCE(NEW.post_id, OLD.post_id)
    );
  ELSIF TG_TABLE_NAME = 'comments' THEN
    PERFORM public.refresh_user_post_signal_state(
      COALESCE(NEW.user_id, OLD.user_id), COALESCE(NEW.post_id, OLD.post_id)
    );
    IF TG_OP = 'UPDATE'
       AND (OLD.user_id, OLD.post_id) IS DISTINCT FROM (NEW.user_id, NEW.post_id)
    THEN
      PERFORM public.refresh_user_post_signal_state(OLD.user_id, OLD.post_id);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_likes_refresh_recommendation_signal
AFTER INSERT OR DELETE ON public.likes
FOR EACH ROW EXECUTE FUNCTION public.trg_refresh_recommendation_signal();
CREATE TRIGGER trg_favorites_refresh_recommendation_signal
AFTER INSERT OR DELETE ON public.favorites
FOR EACH ROW EXECUTE FUNCTION public.trg_refresh_recommendation_signal();
CREATE TRIGGER trg_comments_refresh_recommendation_signal
AFTER INSERT OR DELETE OR UPDATE OF is_deleted, parent_id, user_id, post_id
ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.trg_refresh_recommendation_signal();

REVOKE ALL ON FUNCTION public.trg_rebuild_profiles_for_post_embedding(),
  public.trg_refresh_recommendation_signal()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_recommendation_event(
  p_event_id UUID,
  p_post_id UUID,
  p_feed_session_id UUID,
  p_event_type TEXT,
  p_feed_position INTEGER DEFAULT NULL,
  p_visible_fraction DOUBLE PRECISION DEFAULT NULL,
  p_dwell_ms INTEGER DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_inserted BOOLEAN;
  v_session RECORD;
BEGIN
  IF v_me IS NULL OR p_event_id IS NULL OR p_post_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_event_type NOT IN (
    'impression', 'qualified_impression', 'meaningful_read', 'open',
    'like', 'unlike', 'save', 'unsave', 'comment', 'reply', 'share', 'hide'
  ) THEN
    RAISE EXCEPTION 'Unsupported recommendation event' USING ERRCODE = '22023';
  END IF;
  IF NOT public.can_view_post(p_post_id) AND p_event_type <> 'hide' THEN
    RETURN FALSE;
  END IF;

  -- Assign the anonymous record even when an event is not tied to a feed
  -- session; dereferencing an unassigned PL/pgSQL RECORD raises at runtime.
  SELECT NULL::INTEGER AS position,
    NULL::DOUBLE PRECISION AS ranking_score,
    NULL::DOUBLE PRECISION AS semantic_score,
    NULL::DOUBLE PRECISION AS engagement_score,
    NULL::DOUBLE PRECISION AS freshness_score,
    NULL::DOUBLE PRECISION AS quality_score,
    NULL::DOUBLE PRECISION AS author_score,
    NULL::DOUBLE PRECISION AS exploration_score,
    NULL::TEXT AS algorithm_version
  INTO v_session;

  IF p_feed_session_id IS NOT NULL THEN
    SELECT item.position, item.ranking_score, item.semantic_score,
      item.engagement_score, item.freshness_score, item.quality_score,
      item.author_score, item.exploration_score, session.algorithm_version
    INTO v_session
    FROM public.feed_sessions session
    JOIN public.feed_session_items item ON item.session_id = session.id
    WHERE session.id = p_feed_session_id
      AND session.user_id = v_me
      AND item.post_id = p_post_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Feed session item ownership mismatch' USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO public.recommendation_events (
    event_id, user_id, post_id, feed_session_id, event_type, feed_position,
    algorithm_version, ranking_score, semantic_score, engagement_score,
    freshness_score, quality_score, author_score, exploration_score,
    visible_fraction, dwell_ms
  ) VALUES (
    p_event_id, v_me, p_post_id, p_feed_session_id, p_event_type,
    COALESCE(p_feed_position, v_session.position),
    COALESCE(v_session.algorithm_version, 'cheese-rec-v1'),
    v_session.ranking_score, v_session.semantic_score,
    v_session.engagement_score, v_session.freshness_score,
    v_session.quality_score, v_session.author_score,
    v_session.exploration_score, p_visible_fraction, p_dwell_ms
  )
  ON CONFLICT DO NOTHING;
  v_inserted := FOUND;

  IF p_event_type IN ('meaningful_read', 'open') THEN
    INSERT INTO public.user_post_signal_state (
      user_id, post_id, has_meaningful_read, effective_weight
    ) VALUES (v_me, p_post_id, TRUE, 1)
    ON CONFLICT (user_id, post_id) DO UPDATE
    SET has_meaningful_read = TRUE, updated_at = clock_timestamp();
    PERFORM public.refresh_user_post_signal_state(v_me, p_post_id);
  ELSIF p_event_type = 'hide' THEN
    INSERT INTO public.user_hidden_forum_posts(user_id, post_id)
    VALUES (v_me, p_post_id)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_post_recommendation_metrics(
  p_force BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF NOT p_force AND EXISTS (
    SELECT 1 FROM public.post_recommendation_metrics
    WHERE updated_at >= clock_timestamp() - INTERVAL '5 minutes'
  ) THEN RETURN FALSE; END IF;

  INSERT INTO public.post_recommendation_metrics (
    post_id, qualified_impressions_24h, likes_24h, comments_24h,
    saves_24h, shares_24h, e_raw, unique_commenters, reply_count,
    total_qualified_impressions, updated_at
  )
  SELECT
    forum.id,
    COUNT(event.event_id) FILTER (
      WHERE event.event_type = 'qualified_impression'
        AND event.created_at >= clock_timestamp() - INTERVAL '24 hours'
    )::INTEGER,
    (SELECT COUNT(*)::INTEGER FROM public.likes like_row
     WHERE like_row.target_type = 'post' AND like_row.target_id = forum.id
       AND like_row.created_at >= clock_timestamp() - INTERVAL '24 hours'),
    (SELECT COUNT(*)::INTEGER FROM public.comments comment_row
     WHERE comment_row.post_id = forum.id AND comment_row.is_deleted = FALSE
       AND comment_row.created_at >= clock_timestamp() - INTERVAL '24 hours'),
    (SELECT COUNT(*)::INTEGER FROM public.favorites favorite
     WHERE favorite.post_id = forum.id
       AND favorite.created_at >= clock_timestamp() - INTERVAL '24 hours'),
    COUNT(event.event_id) FILTER (
      WHERE event.event_type = 'share'
        AND event.created_at >= clock_timestamp() - INTERVAL '24 hours'
    )::INTEGER,
    (
      (SELECT COUNT(*) FROM public.likes like_row
       WHERE like_row.target_type = 'post' AND like_row.target_id = forum.id
         AND like_row.created_at >= clock_timestamp() - INTERVAL '24 hours')
      + 3 * (SELECT COUNT(*) FROM public.comments comment_row
       WHERE comment_row.post_id = forum.id AND comment_row.is_deleted = FALSE
         AND comment_row.created_at >= clock_timestamp() - INTERVAL '24 hours')
      + 4 * (SELECT COUNT(*) FROM public.favorites favorite
       WHERE favorite.post_id = forum.id
         AND favorite.created_at >= clock_timestamp() - INTERVAL '24 hours')
      + 2 * COUNT(event.event_id) FILTER (
        WHERE event.event_type = 'share'
          AND event.created_at >= clock_timestamp() - INTERVAL '24 hours'
      )
    ) / SQRT(
      COUNT(event.event_id) FILTER (
        WHERE event.event_type = 'qualified_impression'
          AND event.created_at >= clock_timestamp() - INTERVAL '24 hours'
      ) + 25.0
    ),
    (SELECT COUNT(DISTINCT comment_row.user_id)::INTEGER
     FROM public.comments comment_row
     WHERE comment_row.post_id = forum.id AND comment_row.is_deleted = FALSE),
    (SELECT COUNT(*)::INTEGER FROM public.comments comment_row
     WHERE comment_row.post_id = forum.id AND comment_row.is_deleted = FALSE
       AND comment_row.parent_id IS NOT NULL),
    COUNT(event.event_id) FILTER (
      WHERE event.event_type = 'qualified_impression'
    )::INTEGER,
    clock_timestamp()
  FROM public.forum_posts forum
  JOIN public.posts post_row ON post_row.id = forum.id
  LEFT JOIN public.recommendation_events event ON event.post_id = forum.id
  WHERE post_row.status = 'active'
  GROUP BY forum.id
  ON CONFLICT (post_id) DO UPDATE
  SET qualified_impressions_24h = EXCLUDED.qualified_impressions_24h,
      likes_24h = EXCLUDED.likes_24h,
      comments_24h = EXCLUDED.comments_24h,
      saves_24h = EXCLUDED.saves_24h,
      shares_24h = EXCLUDED.shares_24h,
      e_raw = COALESCE(EXCLUDED.e_raw, 0),
      unique_commenters = EXCLUDED.unique_commenters,
      reply_count = EXCLUDED.reply_count,
      total_qualified_impressions = EXCLUDED.total_qualified_impressions,
      updated_at = EXCLUDED.updated_at;

  WITH ranked AS (
    SELECT metrics.post_id,
      CASE
        WHEN MAX(metrics.e_raw) OVER () = MIN(metrics.e_raw) OVER () THEN 0.0
        ELSE percent_rank() OVER (ORDER BY metrics.e_raw, metrics.post_id)
      END AS normalized
    FROM public.post_recommendation_metrics metrics
  )
  UPDATE public.post_recommendation_metrics metrics
  SET e_normalized = LEAST(1.0, GREATEST(0.0, ranked.normalized))
  FROM ranked WHERE ranked.post_id = metrics.post_id;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.backfill_recommendation_signal_state(
  p_limit INTEGER DEFAULT 500
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE v_pair RECORD; v_count INTEGER := 0;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  FOR v_pair IN
    SELECT DISTINCT source.user_id, source.post_id
    FROM (
      SELECT like_row.user_id, like_row.target_id AS post_id
      FROM public.likes like_row JOIN public.forum_posts forum ON forum.id = like_row.target_id
      WHERE like_row.target_type = 'post'
      UNION ALL
      SELECT favorite.user_id, favorite.post_id
      FROM public.favorites favorite JOIN public.forum_posts forum ON forum.id = favorite.post_id
      UNION ALL
      SELECT comment_row.user_id, comment_row.post_id
      FROM public.comments comment_row JOIN public.forum_posts forum ON forum.id = comment_row.post_id
      WHERE comment_row.is_deleted = FALSE
    ) source
    LEFT JOIN public.user_post_signal_state state
      ON state.user_id = source.user_id AND state.post_id = source.post_id
    WHERE state.user_id IS NULL
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 500), 2000))
  LOOP
    PERFORM public.refresh_user_post_signal_state(v_pair.user_id, v_pair.post_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.rebuild_user_interest_profile(UUID),
  public.refresh_user_post_signal_state(UUID, UUID),
  public.refresh_post_recommendation_metrics(BOOLEAN),
  public.backfill_recommendation_signal_state(INTEGER)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_user_interest_profile(UUID),
  public.refresh_user_post_signal_state(UUID, UUID),
  public.refresh_post_recommendation_metrics(BOOLEAN),
  public.backfill_recommendation_signal_state(INTEGER)
TO service_role;
REVOKE ALL ON FUNCTION public.record_recommendation_event(
  UUID, UUID, UUID, TEXT, INTEGER, DOUBLE PRECISION, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_recommendation_event(
  UUID, UUID, UUID, TEXT, INTEGER, DOUBLE PRECISION, INTEGER
) TO authenticated, service_role;

COMMIT;
