BEGIN;

SELECT plan(33);

SELECT is(
  (SELECT embedding_model FROM public.recommendation_configuration WHERE singleton),
  'gemini-embedding-2',
  'Gemini Embedding 2 is the only configured V1 model'
);
SELECT is(
  (SELECT embedding_dimension FROM public.recommendation_configuration WHERE singleton),
  768,
  'embedding dimension is centralized at 768'
);
SELECT ok(
  ABS((SELECT semantic_weight + engagement_weight + freshness_weight
    + quality_weight + author_weight + exploration_weight
    FROM public.recommendation_configuration WHERE singleton) - 1.0) < 0.000001,
  'ranking weights sum to one'
);

INSERT INTO auth.users(id, email)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'recommendation-alice@test.invalid'),
  ('00000000-0000-0000-0000-000000000002', 'recommendation-bob@test.invalid')
ON CONFLICT (id) DO NOTHING;

WITH test_users(id, email, full_name) AS (
  VALUES
    ('00000000-0000-0000-0000-000000000001'::UUID,
      'recommendation-alice@test.invalid', 'Recommendation Alice'),
    ('00000000-0000-0000-0000-000000000002'::UUID,
      'recommendation-bob@test.invalid', 'Recommendation Bob')
), test_school AS (
  SELECT id, name FROM public.schools
  WHERE active = TRUE
  ORDER BY CASE WHEN name = 'McMaster University' THEN 0 ELSE 1 END, name
  LIMIT 1
)
INSERT INTO public.profiles(id, email, full_name, university, school_id)
SELECT test_users.id, test_users.email, test_users.full_name,
  test_school.name, test_school.id
FROM test_users CROSS JOIN test_school
ON CONFLICT (id) DO NOTHING;

UPDATE public.recommendation_configuration
SET rollout_percentage = 100, shadow_enabled = TRUE;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  '19000000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum', 'Vector test title', 'Vector test body', 'active',
  FALSE, FALSE, clock_timestamp()
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments, is_pinned, is_locked)
SELECT
  '19000000-0000-4000-8000-000000000001'::UUID,
  board.id, TRUE, FALSE, FALSE
FROM public.forum_boards board
WHERE board.status <> 'archived'
ORDER BY board.id LIMIT 1;

SELECT is(
  (SELECT COUNT(*) FROM public.post_embedding_jobs
   WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  1::BIGINT,
  'forum publication enqueues one asynchronous embedding job'
);
SELECT is(
  public.enqueue_forum_post_embedding('19000000-0000-4000-8000-000000000001'),
  (SELECT id FROM public.post_embedding_jobs
   WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  'same canonical input reuses the idempotent job'
);
SELECT is(
  (SELECT COUNT(*) FROM public.post_embedding_jobs
   WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  1::BIGINT,
  'same input hash never duplicates work'
);

-- The provider may be unavailable or deliberately disabled. A pending vector
-- record must not remove an otherwise eligible forum post from ranking or a
-- signed-in user's feed session.
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.post_embeddings
    WHERE post_id = '19000000-0000-4000-8000-000000000001'
      AND (status = 'ready' OR embedding IS NOT NULL)
  ),
  'eligible forum post has no materialized embedding while its job is pending'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.rank_forum_recommendations_v1(
      '00000000-0000-0000-0000-000000000002', NULL, 80
    )
    WHERE post_id = '19000000-0000-4000-8000-000000000001'
  ),
  'exact ranking retains an eligible forum post with no materialized embedding'
);
SELECT is(
  (
    SELECT semantic_score
    FROM public.rank_forum_recommendations_v1(
      '00000000-0000-0000-0000-000000000002', NULL, 80
    )
    WHERE post_id = '19000000-0000-4000-8000-000000000001'
  ),
  0.5::DOUBLE PRECISION,
  'unembedded eligible post uses the neutral semantic fallback'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;
SELECT ok(
  set_config(
    'test.no_embedding_session_id',
    public.create_recommendation_feed_session(TRUE, FALSE, NULL)::TEXT,
    TRUE
  ) IS NOT NULL,
  'signed-in user can create a recommendation session with no materialized vector'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.get_recommendation_feed_page(
      current_setting('test.no_embedding_session_id')::UUID, 0, 20
    )
    WHERE post_id = '19000000-0000-4000-8000-000000000001'
  ),
  'session page remains non-empty and includes the unembedded eligible forum post'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

DO $$
DECLARE v_values REAL[] := array_fill(0::REAL, ARRAY[768]);
BEGIN
  v_values[1] := 1;
  UPDATE public.post_embeddings
  SET embedding = v_values::extensions.vector(768), status = 'ready',
      generated_at = clock_timestamp()
  WHERE post_id = '19000000-0000-4000-8000-000000000001';
  UPDATE public.post_embedding_jobs
  SET status = 'ready'
  WHERE post_id = '19000000-0000-4000-8000-000000000001';
END;
$$;

UPDATE public.posts SET description = 'Changed vector test body'
WHERE id = '19000000-0000-4000-8000-000000000001';

SELECT is(
  (SELECT COUNT(*) FROM public.post_embedding_jobs
   WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  2::BIGINT,
  'changed semantic text creates a new hash-aware job'
);
SELECT is(
  (SELECT COUNT(*) FROM public.post_embedding_jobs
   WHERE post_id = '19000000-0000-4000-8000-000000000001'
     AND status = 'superseded'),
  1::BIGINT,
  'the prior embedding job becomes superseded'
);

DO $$
DECLARE v_values REAL[] := array_fill(0::REAL, ARRAY[768]);
BEGIN
  v_values[1] := 1;
  UPDATE public.post_embeddings
  SET embedding = v_values::extensions.vector(768), status = 'ready',
      generated_at = clock_timestamp()
  WHERE post_id = '19000000-0000-4000-8000-000000000001';
  UPDATE public.post_embedding_jobs SET status = 'ready'
  WHERE post_id = '19000000-0000-4000-8000-000000000001'
    AND status = 'pending';
END;
$$;

SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (public.get_recommendation_feed_mode()).algorithm_version,
  'cheese-rec-v1',
  'server-side 100 percent rollout selects V1 without an iOS constant'
);
SELECT ok(
  (public.get_recommendation_feed_mode()).use_recommendations,
  'server-side mode explicitly tells clients whether to use recommendations'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

SELECT ok(
  public.record_recommendation_event(
    '19000000-0000-4000-8000-000000000010',
    '19000000-0000-4000-8000-000000000001', NULL, 'open', NULL, NULL, NULL
  ),
  'detail open records an idempotent recommendation event'
);
SELECT is(
  (SELECT effective_weight FROM public.user_post_signal_state
   WHERE user_id = auth.uid()
     AND post_id = '19000000-0000-4000-8000-000000000001'),
  1::SMALLINT,
  'meaningful read transitions weight from zero to one'
);

INSERT INTO public.likes(user_id, target_type, target_id)
VALUES (auth.uid(), 'post', '19000000-0000-4000-8000-000000000001');
SELECT is(
  (SELECT effective_weight FROM public.user_post_signal_state
   WHERE user_id = auth.uid()
     AND post_id = '19000000-0000-4000-8000-000000000001'),
  3::SMALLINT,
  'read then like uses max weight three instead of addition'
);
DELETE FROM public.likes
WHERE user_id = auth.uid() AND target_type = 'post'
  AND target_id = '19000000-0000-4000-8000-000000000001';
SELECT is(
  (SELECT effective_weight FROM public.user_post_signal_state
   WHERE user_id = auth.uid()
     AND post_id = '19000000-0000-4000-8000-000000000001'),
  1::SMALLINT,
  'unlike returns to read weight one'
);

INSERT INTO public.favorites(user_id, post_id)
VALUES (auth.uid(), '19000000-0000-4000-8000-000000000001');
INSERT INTO public.comments(id, post_id, user_id, content, is_anonymous)
VALUES (
  '19000000-0000-4000-8000-000000000020',
  '19000000-0000-4000-8000-000000000001', auth.uid(), 'top level', FALSE
);
DELETE FROM public.favorites
WHERE user_id = auth.uid()
  AND post_id = '19000000-0000-4000-8000-000000000001';
SELECT is(
  (SELECT effective_weight FROM public.user_post_signal_state
   WHERE user_id = auth.uid()
     AND post_id = '19000000-0000-4000-8000-000000000001'),
  6::SMALLINT,
  'comment remains strongest at six after unsave'
);

INSERT INTO public.comments(
  id, post_id, user_id, parent_id, content, is_anonymous
) VALUES (
  '19000000-0000-4000-8000-000000000021',
  '19000000-0000-4000-8000-000000000001', auth.uid(),
  '19000000-0000-4000-8000-000000000020', 'reply', FALSE
);
SELECT is(
  (SELECT effective_weight FROM public.user_post_signal_state
   WHERE user_id = auth.uid()
     AND post_id = '19000000-0000-4000-8000-000000000001'),
  8::SMALLINT,
  'reply dominates current positive signals at eight'
);
SELECT ok(
  ABS((SELECT (normalized_embedding::REAL[])[1]
       FROM public.user_interest_profiles WHERE user_id = auth.uid()) - 1.0) < 0.0001,
  'normalized user profile has unit direction'
);
SELECT is(
  (SELECT total_weight FROM public.user_interest_profiles WHERE user_id = auth.uid()),
  8,
  'profile total weight reflects the strongest signal once per post'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

INSERT INTO public.post_recommendation_metrics (
  post_id, e_normalized, unique_commenters, reply_count,
  total_qualified_impressions, updated_at
) VALUES (
  '19000000-0000-4000-8000-000000000001', 0.8, 5, 10, 0, clock_timestamp()
)
ON CONFLICT (post_id) DO UPDATE SET
  e_normalized = 0.8, unique_commenters = 5, reply_count = 10,
  total_qualified_impressions = 0;

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

INSERT INTO public.user_follows(follower_id, following_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;

SELECT ok(
  (SELECT semantic_score > 0.999 FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  'semantic score maps identical unit vectors to one'
);
SELECT is(
  (SELECT quality_score FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  1::DOUBLE PRECISION,
  'discussion quality clamps at one'
);
SELECT is(
  (SELECT author_score FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  1::DOUBLE PRECISION,
  'following author affinity is one'
);
SELECT is(
  (SELECT exploration_score FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  1::DOUBLE PRECISION,
  'zero qualified impressions produces exploration one'
);
SELECT ok(
  (SELECT freshness_score > 0.99 FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  'new post freshness is approximately one'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT ok(
  set_config(
    'test.recommendation_session_id',
    public.create_recommendation_feed_session(TRUE, FALSE, NULL)::TEXT,
    TRUE
  ) IS NOT NULL,
  'explicit low-level creation creates a stable recommendation session (not Home pull semantics)'
);
SELECT ok(
  (SELECT COUNT(*) BETWEEN 1 AND 20
   FROM public.get_recommendation_feed_page(
     current_setting('test.recommendation_session_id')::UUID, 0, 20
   )),
  'session page returns a bounded shaped page without regeneration'
);
SELECT is(
  (SELECT COUNT(*) FROM public.get_recommendation_feed_page(
    '19000000-0000-4000-8000-000000000099'::UUID, 0, 20
  )),
  0::BIGINT,
  'a user cannot fetch another users session'
);

SELECT ok(
  public.record_recommendation_event(
    '19000000-0000-4000-8000-000000000030',
    '19000000-0000-4000-8000-000000000001', NULL, 'hide', NULL, NULL, NULL
  ),
  'hide event creates a per-user exclusion without changing global post status'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT is(
  (SELECT COUNT(*) FROM public.rank_forum_recommendations_v1(
    '00000000-0000-0000-0000-000000000002', NULL, 80
  ) WHERE post_id = '19000000-0000-4000-8000-000000000001'),
  0::BIGINT,
  'hidden post is excluded completely from subsequent exact ranking'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
