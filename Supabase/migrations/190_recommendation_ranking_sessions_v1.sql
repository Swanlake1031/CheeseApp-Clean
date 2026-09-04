-- Cheese Recommendation System V1: exact ranking, deterministic shaping,
-- stable feed sessions, rollout selection, and service-only debug inspection.

BEGIN;

CREATE TABLE public.feed_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  algorithm_version TEXT NOT NULL DEFAULT 'cheese-rec-v1',
  embedding_version TEXT NOT NULL DEFAULT 'cheese-semantic-v1',
  is_shadow BOOLEAN NOT NULL DEFAULT FALSE,
  eligible_post_count INTEGER NOT NULL DEFAULT 0 CHECK (eligible_post_count >= 0),
  embedding_coverage DOUBLE PRECISION NOT NULL DEFAULT 0
    CHECK (embedding_coverage BETWEEN 0 AND 1),
  is_cold_start BOOLEAN NOT NULL DEFAULT TRUE,
  ranking_ms INTEGER CHECK (ranking_ms IS NULL OR ranking_ms >= 0),
  shaping_ms INTEGER CHECK (shaping_ms IS NULL OR shaping_ms >= 0),
  deferred_author_count INTEGER NOT NULL DEFAULT 0 CHECK (deferred_author_count >= 0),
  deferred_semantic_count INTEGER NOT NULL DEFAULT 0 CHECK (deferred_semantic_count >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp() + INTERVAL '20 minutes'
);

CREATE INDEX feed_sessions_user_expiry_idx
  ON public.feed_sessions(user_id, is_shadow, expires_at DESC, created_at DESC);

CREATE TABLE public.feed_session_items (
  session_id UUID NOT NULL REFERENCES public.feed_sessions(id) ON DELETE CASCADE,
  post_id UUID NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  position INTEGER NOT NULL CHECK (position BETWEEN 1 AND 60),
  ranking_score DOUBLE PRECISION NOT NULL,
  base_ranking_score DOUBLE PRECISION NOT NULL CHECK (base_ranking_score BETWEEN 0 AND 1),
  semantic_score DOUBLE PRECISION NOT NULL CHECK (semantic_score BETWEEN 0 AND 1),
  engagement_score DOUBLE PRECISION NOT NULL CHECK (engagement_score BETWEEN 0 AND 1),
  freshness_score DOUBLE PRECISION NOT NULL CHECK (freshness_score BETWEEN 0 AND 1),
  quality_score DOUBLE PRECISION NOT NULL CHECK (quality_score BETWEEN 0 AND 1),
  author_score DOUBLE PRECISION NOT NULL CHECK (author_score BETWEEN 0 AND 1),
  exploration_score DOUBLE PRECISION NOT NULL CHECK (exploration_score BETWEEN 0 AND 1),
  repeat_ignore_penalty DOUBLE PRECISION NOT NULL CHECK (repeat_ignore_penalty BETWEEN 0 AND 0.45),
  shaping_pass SMALLINT NOT NULL DEFAULT 1 CHECK (shaping_pass BETWEEN 1 AND 3),
  shaping_reason TEXT,
  PRIMARY KEY (session_id, position),
  UNIQUE (session_id, post_id)
);

CREATE INDEX feed_session_items_post_idx
  ON public.feed_session_items(post_id);

ALTER TABLE public.feed_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feed_session_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own feed sessions"
ON public.feed_sessions FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) AND is_shadow = FALSE);
CREATE POLICY "Users can read own feed session items"
ON public.feed_session_items FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.feed_sessions session
  WHERE session.id = feed_session_items.session_id
    AND session.user_id = (SELECT auth.uid()) AND session.is_shadow = FALSE
));

REVOKE ALL ON TABLE public.feed_sessions, public.feed_session_items
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.feed_sessions, public.feed_session_items TO service_role;

ALTER TABLE public.recommendation_events
  ADD CONSTRAINT recommendation_events_feed_session_fk
  FOREIGN KEY (feed_session_id) REFERENCES public.feed_sessions(id) ON DELETE SET NULL;

CREATE INDEX recommendation_events_feed_session_created_idx
  ON public.recommendation_events(feed_session_id, created_at DESC)
  WHERE feed_session_id IS NOT NULL;

CREATE TYPE public.recommendation_feed_mode AS (
  algorithm_version TEXT,
  shadow_enabled BOOLEAN,
  use_recommendations BOOLEAN
);

CREATE OR REPLACE FUNCTION public.get_recommendation_feed_mode()
RETURNS public.recommendation_feed_mode
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_config public.recommendation_configuration%ROWTYPE;
  v_bucket BIGINT;
  v_result public.recommendation_feed_mode;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_config FROM public.recommendation_configuration WHERE singleton;
  v_bucket := MOD(
    hashtextextended(v_me::TEXT, 20260830) & 9223372036854775807,
    100
  );
  v_result.algorithm_version := CASE
    WHEN v_bucket < v_config.rollout_percentage THEN v_config.algorithm_version
    ELSE 'legacy'
  END;
  v_result.shadow_enabled := v_config.shadow_enabled;
  v_result.use_recommendations := v_bucket < v_config.rollout_percentage;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.rank_forum_recommendations_v1(
  p_user_id UUID,
  p_exclude_session_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS TABLE (
  post_id UUID,
  author_id UUID,
  semantic_score DOUBLE PRECISION,
  engagement_score DOUBLE PRECISION,
  freshness_score DOUBLE PRECISION,
  quality_score DOUBLE PRECISION,
  author_score DOUBLE PRECISION,
  exploration_score DOUBLE PRECISION,
  base_ranking_score DOUBLE PRECISION,
  repeat_ignore_penalty DOUBLE PRECISION,
  ranking_score DOUBLE PRECISION
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
  WITH config AS (
    SELECT * FROM public.recommendation_configuration WHERE singleton
  ), profile AS (
    SELECT interest.*
    FROM public.user_interest_profiles interest, config
    WHERE interest.user_id = p_user_id
      AND interest.embedding_version = config.embedding_version
      AND interest.total_weight >= 5
      AND interest.normalized_embedding IS NOT NULL
  ), eligible AS (
    SELECT
      post_row.id,
      post_row.user_id,
      post_row.created_at,
      embedding.embedding,
      metrics.e_normalized,
      metrics.unique_commenters,
      metrics.reply_count,
      metrics.total_qualified_impressions,
      EXISTS (
        SELECT 1 FROM public.user_follows follow_row
        WHERE follow_row.follower_id = p_user_id
          AND follow_row.following_id = post_row.user_id
      ) AS follows_author,
      (
        SELECT COUNT(*)::INTEGER
        FROM public.recommendation_events ignored
        LEFT JOIN public.user_post_signal_state signal
          ON signal.user_id = p_user_id AND signal.post_id = post_row.id
        WHERE ignored.user_id = p_user_id
          AND ignored.post_id = post_row.id
          AND ignored.event_type = 'qualified_impression'
          AND ignored.created_at >= clock_timestamp() - INTERVAL '7 days'
          AND COALESCE(signal.effective_weight, 0) = 0
      ) AS ignored_count
    FROM public.posts post_row
    JOIN public.forum_posts forum_row ON forum_row.id = post_row.id
    JOIN public.forum_boards board ON board.id = forum_row.board_id
    CROSS JOIN config
    LEFT JOIN public.post_embeddings embedding
      ON embedding.post_id = post_row.id
      AND embedding.embedding_version = config.embedding_version
      AND embedding.model = config.embedding_model
      AND embedding.input_format_version = config.input_format_version
      AND embedding.status = 'ready'
    LEFT JOIN public.post_recommendation_metrics metrics ON metrics.post_id = post_row.id
    WHERE post_row.type = 'forum'
      AND post_row.status = 'active'
      AND post_row.is_private = FALSE
      AND board.status <> 'archived'
      AND post_row.user_id <> p_user_id
      AND (
        auth.role() = 'service_role'
        OR (auth.uid() = p_user_id AND public.can_view_post(post_row.id))
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.user_blocks block_row
        WHERE (block_row.blocker_id = p_user_id AND block_row.blocked_id = post_row.user_id)
           OR (block_row.blocker_id = post_row.user_id AND block_row.blocked_id = p_user_id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.user_hidden_forum_posts hidden
        WHERE hidden.user_id = p_user_id AND hidden.post_id = post_row.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.feed_session_items served
        WHERE served.session_id = p_exclude_session_id
          AND served.post_id = post_row.id
      )
  ), features AS (
    SELECT
      eligible.*,
      CASE
        WHEN profile.user_id IS NULL OR eligible.embedding IS NULL THEN 0.5
        ELSE LEAST(1.0, GREATEST(
          0.0,
          ((-(profile.normalized_embedding <#> eligible.embedding)) + 1.0) / 2.0
        ))
      END AS s,
      LEAST(1.0, GREATEST(0.0, COALESCE(eligible.e_normalized, 0.0))) AS e,
      LEAST(1.0, GREATEST(0.0,
        POWER(2.0, -GREATEST(0.0, EXTRACT(EPOCH FROM (
          clock_timestamp() - eligible.created_at
        )) / 3600.0) / 48.0)
      )) AS f,
      LEAST(1.0, GREATEST(0.0,
        0.6 * LEAST(COALESCE(eligible.unique_commenters, 0) / 5.0, 1.0)
        + 0.4 * LEAST(COALESCE(eligible.reply_count, 0) / 10.0, 1.0)
      )) AS q,
      CASE WHEN eligible.follows_author THEN 1.0 ELSE 0.0 END AS a,
      LEAST(1.0, GREATEST(0.0,
        EXP(-COALESCE(eligible.total_qualified_impressions, 0) / 30.0)
      )) AS x,
      LEAST(0.45, 0.15 * GREATEST(0, eligible.ignored_count - 1)) AS penalty
    FROM eligible
    LEFT JOIN profile ON TRUE
  ), scored AS (
    SELECT
      features.*,
      config.semantic_weight * features.s
        + config.engagement_weight * features.e
        + config.freshness_weight * features.f
        + config.quality_weight * features.q
        + config.author_weight * features.a
        + config.exploration_weight * features.x AS base_score
    FROM features CROSS JOIN config
  )
  SELECT
    scored.id, scored.user_id, scored.s, scored.e, scored.f, scored.q,
    scored.a, scored.x, scored.base_score, scored.penalty,
    scored.base_score - scored.penalty
  FROM scored
  ORDER BY scored.base_score - scored.penalty DESC, scored.created_at DESC, scored.id DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 80), 80));
$$;

CREATE OR REPLACE FUNCTION public.create_recommendation_feed_session(
  p_force_refresh BOOLEAN DEFAULT FALSE,
  p_shadow BOOLEAN DEFAULT FALSE,
  p_user_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := COALESCE(p_user_id, auth.uid());
  v_config public.recommendation_configuration%ROWTYPE;
  v_mode public.recommendation_feed_mode;
  v_session_id UUID;
  v_candidate RECORD;
  v_selected UUID[] := ARRAY[]::UUID[];
  v_deferred UUID[] := ARRAY[]::UUID[];
  v_deferred_reason TEXT[] := ARRAY[]::TEXT[];
  v_position INTEGER := 0;
  v_author_violation BOOLEAN;
  v_semantic_violation BOOLEAN;
  v_author_deferred INTEGER := 0;
  v_semantic_deferred INTEGER := 0;
  v_rank_started TIMESTAMPTZ := clock_timestamp();
  v_rank_finished TIMESTAMPTZ;
  v_shape_finished TIMESTAMPTZ;
  v_eligible_count INTEGER;
  v_ready_count INTEGER;
  v_cold_start BOOLEAN;
  v_reason TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NOT NULL
     AND auth.role() IS DISTINCT FROM 'service_role'
     AND p_user_id IS DISTINCT FROM auth.uid()
  THEN
    RAISE EXCEPTION 'Service role required for another user' USING ERRCODE = '42501';
  END IF;
  IF p_shadow AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required for shadow sessions' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_config FROM public.recommendation_configuration WHERE singleton;
  IF p_shadow AND NOT v_config.shadow_enabled THEN RETURN NULL; END IF;
  IF NOT p_shadow THEN
    v_mode := public.get_recommendation_feed_mode();
    IF NOT v_mode.use_recommendations THEN RETURN NULL; END IF;
  END IF;

  IF NOT p_force_refresh THEN
    SELECT session.id INTO v_session_id
    FROM public.feed_sessions session
    WHERE session.user_id = v_me AND session.is_shadow = p_shadow
      AND session.algorithm_version = v_config.algorithm_version
      AND session.expires_at > clock_timestamp()
    ORDER BY session.created_at DESC LIMIT 1;
    IF FOUND THEN RETURN v_session_id; END IF;
  END IF;

  SELECT COUNT(*), COUNT(embedding.embedding),
    NOT EXISTS (
      SELECT 1 FROM public.user_interest_profiles profile
      WHERE profile.user_id = v_me
        AND profile.embedding_version = v_config.embedding_version
        AND profile.total_weight >= 5
        AND profile.normalized_embedding IS NOT NULL
    )
  INTO v_eligible_count, v_ready_count, v_cold_start
  FROM public.posts post_row
  JOIN public.forum_posts forum ON forum.id = post_row.id
  JOIN public.forum_boards board ON board.id = forum.board_id
  LEFT JOIN public.post_embeddings embedding
    ON embedding.post_id = post_row.id
    AND embedding.embedding_version = v_config.embedding_version
    AND embedding.model = v_config.embedding_model
    AND embedding.input_format_version = v_config.input_format_version
    AND embedding.status = 'ready'
  WHERE post_row.status = 'active' AND post_row.type = 'forum'
    AND post_row.is_private = FALSE AND post_row.user_id <> v_me
    AND board.status <> 'archived'
    AND (
      auth.role() = 'service_role'
      OR (auth.uid() = v_me AND public.can_view_post(post_row.id))
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks block_row
      WHERE (block_row.blocker_id = v_me AND block_row.blocked_id = post_row.user_id)
         OR (block_row.blocker_id = post_row.user_id AND block_row.blocked_id = v_me)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.user_hidden_forum_posts hidden
      WHERE hidden.user_id = v_me AND hidden.post_id = post_row.id
    );

  INSERT INTO public.feed_sessions (
    user_id, algorithm_version, embedding_version, is_shadow,
    eligible_post_count, embedding_coverage, is_cold_start
  ) VALUES (
    v_me, v_config.algorithm_version, v_config.embedding_version, p_shadow,
    v_eligible_count,
    CASE WHEN v_eligible_count = 0 THEN 0
         ELSE v_ready_count::DOUBLE PRECISION / v_eligible_count END,
    v_cold_start
  ) RETURNING id INTO v_session_id;

  v_rank_finished := clock_timestamp();

  FOR v_candidate IN
    SELECT * FROM public.rank_forum_recommendations_v1(v_me, NULL, 80)
  LOOP
    EXIT WHEN v_position >= 60;
    v_author_violation := EXISTS (
      SELECT 1
      FROM unnest(v_selected) WITH ORDINALITY selected(post_id, ordinal)
      JOIN public.posts recent ON recent.id = selected.post_id
      WHERE selected.ordinal > GREATEST(0, array_length(v_selected, 1) - 3)
        AND recent.user_id = v_candidate.author_id
    );
    v_semantic_violation := EXISTS (
      SELECT 1
      FROM unnest(v_selected) WITH ORDINALITY selected(post_id, ordinal)
      JOIN public.post_embeddings recent ON recent.post_id = selected.post_id
        AND recent.embedding_version = v_config.embedding_version AND recent.status = 'ready'
      JOIN public.post_embeddings current_embedding
        ON current_embedding.post_id = v_candidate.post_id
        AND current_embedding.embedding_version = v_config.embedding_version
        AND current_embedding.status = 'ready'
      WHERE selected.ordinal > GREATEST(0, array_length(v_selected, 1) - 3)
        AND -(current_embedding.embedding <#> recent.embedding) > 0.93
    );
    IF v_author_violation OR v_semantic_violation THEN
      v_deferred := array_append(v_deferred, v_candidate.post_id);
      v_reason := CASE
        WHEN v_author_violation AND v_semantic_violation THEN 'same_author+semantic_duplicate'
        WHEN v_author_violation THEN 'same_author'
        ELSE 'semantic_duplicate'
      END;
      v_deferred_reason := array_append(v_deferred_reason, v_reason);
      IF v_author_violation THEN v_author_deferred := v_author_deferred + 1; END IF;
      IF v_semantic_violation THEN v_semantic_deferred := v_semantic_deferred + 1; END IF;
      CONTINUE;
    END IF;
    v_position := v_position + 1;
    v_selected := array_append(v_selected, v_candidate.post_id);
    INSERT INTO public.feed_session_items VALUES (
      v_session_id, v_candidate.post_id, v_position, v_candidate.ranking_score,
      v_candidate.base_ranking_score, v_candidate.semantic_score,
      v_candidate.engagement_score, v_candidate.freshness_score,
      v_candidate.quality_score, v_candidate.author_score,
      v_candidate.exploration_score, v_candidate.repeat_ignore_penalty,
      1, NULL
    );
  END LOOP;

  IF v_position < 60 THEN
    FOR v_candidate IN
      SELECT ranked.* FROM public.rank_forum_recommendations_v1(v_me, NULL, 80) ranked
      WHERE ranked.post_id = ANY(v_deferred)
      ORDER BY ranked.ranking_score DESC, ranked.post_id DESC
    LOOP
      EXIT WHEN v_position >= 60;
      CONTINUE WHEN v_candidate.post_id = ANY(v_selected);
      v_author_violation := EXISTS (
        SELECT 1 FROM unnest(v_selected) WITH ORDINALITY selected(post_id, ordinal)
        JOIN public.posts recent ON recent.id = selected.post_id
        WHERE selected.ordinal > GREATEST(0, array_length(v_selected, 1) - 2)
          AND recent.user_id = v_candidate.author_id
      );
      v_semantic_violation := EXISTS (
        SELECT 1 FROM unnest(v_selected) WITH ORDINALITY selected(post_id, ordinal)
        JOIN public.post_embeddings recent ON recent.post_id = selected.post_id
          AND recent.embedding_version = v_config.embedding_version AND recent.status = 'ready'
        JOIN public.post_embeddings current_embedding
          ON current_embedding.post_id = v_candidate.post_id
          AND current_embedding.embedding_version = v_config.embedding_version
          AND current_embedding.status = 'ready'
        WHERE selected.ordinal > GREATEST(0, array_length(v_selected, 1) - 2)
          AND -(current_embedding.embedding <#> recent.embedding) > 0.96
      );
      CONTINUE WHEN v_author_violation OR v_semantic_violation;
      v_position := v_position + 1;
      v_selected := array_append(v_selected, v_candidate.post_id);
      INSERT INTO public.feed_session_items VALUES (
        v_session_id, v_candidate.post_id, v_position, v_candidate.ranking_score,
        v_candidate.base_ranking_score, v_candidate.semantic_score,
        v_candidate.engagement_score, v_candidate.freshness_score,
        v_candidate.quality_score, v_candidate.author_score,
        v_candidate.exploration_score, v_candidate.repeat_ignore_penalty,
        2, 'relaxed'
      );
    END LOOP;
  END IF;

  IF v_position < 60 THEN
    FOR v_candidate IN
      SELECT ranked.* FROM public.rank_forum_recommendations_v1(v_me, NULL, 80) ranked
      WHERE NOT (ranked.post_id = ANY(v_selected))
      ORDER BY ranked.ranking_score DESC, ranked.post_id DESC
    LOOP
      EXIT WHEN v_position >= 60;
      v_position := v_position + 1;
      v_selected := array_append(v_selected, v_candidate.post_id);
      INSERT INTO public.feed_session_items VALUES (
        v_session_id, v_candidate.post_id, v_position, v_candidate.ranking_score,
        v_candidate.base_ranking_score, v_candidate.semantic_score,
        v_candidate.engagement_score, v_candidate.freshness_score,
        v_candidate.quality_score, v_candidate.author_score,
        v_candidate.exploration_score, v_candidate.repeat_ignore_penalty,
        3, 'deferred_fallback'
      );
    END LOOP;
  END IF;

  v_shape_finished := clock_timestamp();
  UPDATE public.feed_sessions
  SET
    ranking_ms = GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_rank_finished - v_rank_started)) * 1000))::INTEGER,
    shaping_ms = GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_shape_finished - v_rank_finished)) * 1000))::INTEGER,
    deferred_author_count = v_author_deferred,
    deferred_semantic_count = v_semantic_deferred
  WHERE id = v_session_id;
  RETURN v_session_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_recommendation_feed_page(
  p_session_id UUID,
  p_offset INTEGER DEFAULT 0,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (session_id UUID, post_id UUID, "position" INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT item.session_id, item.post_id, item.position
  FROM public.feed_session_items item
  JOIN public.feed_sessions session ON session.id = item.session_id
  WHERE session.id = p_session_id
    AND session.user_id = auth.uid()
    AND session.is_shadow = FALSE
    AND session.expires_at > clock_timestamp()
  ORDER BY item.position
  OFFSET GREATEST(0, COALESCE(p_offset, 0))
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 20));
$$;

CREATE OR REPLACE FUNCTION public.inspect_recommendation_session(
  p_session_id UUID
)
RETURNS TABLE (
  "position" INTEGER, post_id UUID, author_id UUID,
  semantic_score DOUBLE PRECISION, engagement_score DOUBLE PRECISION,
  freshness_score DOUBLE PRECISION, quality_score DOUBLE PRECISION,
  author_score DOUBLE PRECISION, exploration_score DOUBLE PRECISION,
  repeat_ignore_penalty DOUBLE PRECISION, final_score DOUBLE PRECISION,
  shaping_pass SMALLINT, shaping_reason TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT item.position, item.post_id, post_row.user_id,
    item.semantic_score, item.engagement_score, item.freshness_score,
    item.quality_score, item.author_score, item.exploration_score,
    item.repeat_ignore_penalty, item.ranking_score,
    item.shaping_pass, item.shaping_reason
  FROM public.feed_session_items item
  JOIN public.posts post_row ON post_row.id = item.post_id
  WHERE item.session_id = p_session_id ORDER BY item.position;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_recommendation_shadow_users(
  p_limit INTEGER DEFAULT 20
)
RETURNS SETOF UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT profile.id
  FROM public.profiles profile
  LEFT JOIN public.view_history history ON history.user_id = profile.id
  WHERE profile.deactivated_at IS NULL
  GROUP BY profile.id
  ORDER BY MAX(history.viewed_at) DESC NULLS LAST, profile.id
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
END;
$$;

REVOKE ALL ON FUNCTION public.rank_forum_recommendations_v1(UUID, UUID, INTEGER),
  public.inspect_recommendation_session(UUID),
  public.list_recommendation_shadow_users(INTEGER)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rank_forum_recommendations_v1(UUID, UUID, INTEGER),
  public.inspect_recommendation_session(UUID),
  public.list_recommendation_shadow_users(INTEGER)
TO service_role;
REVOKE ALL ON FUNCTION public.get_recommendation_feed_mode(),
  public.create_recommendation_feed_session(BOOLEAN, BOOLEAN, UUID),
  public.get_recommendation_feed_page(UUID, INTEGER, INTEGER)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_recommendation_feed_mode(),
  public.create_recommendation_feed_session(BOOLEAN, BOOLEAN, UUID),
  public.get_recommendation_feed_page(UUID, INTEGER, INTEGER)
TO authenticated, service_role;

COMMIT;
