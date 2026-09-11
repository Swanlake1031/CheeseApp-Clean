-- Synthetic fixtures only. Every fixture, extension and clock substitution rolls back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_temp;
SELECT no_plan();

CREATE FUNCTION pg_temp.uid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('29000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
CREATE FUNCTION pg_temp.vec(n real) RETURNS extensions.vector LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY[n] || array_fill(0::real, ARRAY[767]))::extensions.vector
$$;
CREATE FUNCTION pg_temp.allow_post(n integer) RETURNS boolean LANGUAGE sql AS $$
  SELECT recommendation_private.allowed(pg_temp.uid(n),pg_temp.uid(1))
$$;
SELECT ok(NOT gate_enabled AND NOT scoring_enabled AND NOT shadow_enabled,
  'V2 defaults are all off') FROM cross_school_configuration;
-- Normalize only the separately tested ignore-policy adjustment for the historical
-- fingerprint. The baseline clone below keeps the CURRENT penalty in both rankers.
SELECT is(md5(replace(replace(prosrc,E'\n      AND recommendation_private.allowed(post_row.id, p_user_id)',''),
  'LEAST(0.15, 0.05 * GREATEST(0, eligible.ignored_count - 1))',
  'LEAST(0.45, 0.15 * GREATEST(0, eligible.ignored_count - 1))')),
  '2710a9a30cb117ba176d2f507ae5201b','rank body differs from audited V1 only by eligibility and reviewed ignore policy')
FROM pg_proc WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure;

-- Freeze time in BOTH rankers within this rollback transaction: otherwise freshness
-- drifts between calls. Reconstruct baseline only after the audited body hash check.
DO $$ DECLARE d text; BEGIN
  SELECT pg_get_functiondef('public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure) INTO d;
  d:=replace(d,'clock_timestamp()','transaction_timestamp()'); EXECUTE d;
  EXECUTE replace(replace(d,'public.rank_forum_recommendations_v1(', 'public.test_v2_baseline_rank('),
    E'\n      AND recommendation_private.allowed(post_row.id, p_user_id)','');
  SELECT pg_get_functiondef('public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure) INTO d;
  d:=replace(d,'clock_timestamp()','transaction_timestamp()'); EXECUTE d;
  d:=replace(d,'public.create_recommendation_feed_session(', 'public.test_v2_baseline_session(');
  d:=replace(d,' AND recommendation_private.session_valid(session.id)','');
  d:=replace(d,' AND recommendation_private.allowed(post_row.id, v_me)','');
  d:=replace(d,E'PERFORM 1 FROM public.cross_school_configuration WHERE singleton FOR SHARE;\n  ','');
  d:=replace(d,'public.rank_forum_recommendations_v1(', 'public.test_v2_baseline_rank('); EXECUTE d;
END $$;
INSERT INTO schools(id,name,city) VALUES (pg_temp.uid(901),'V2 Test School A','Test'),(pg_temp.uid(902),'V2 Test School B','Test');
INSERT INTO auth.users(id,email) SELECT pg_temp.uid(n),'v2-'||n||'@test.invalid' FROM generate_series(1,13)n;
INSERT INTO profiles(id,email,full_name,university,school_id)
SELECT pg_temp.uid(n),'v2-'||n||'@test.invalid','V2 User '||n,
  CASE WHEN n<=2 THEN 'V2 Test School A' ELSE 'V2 Test School B' END,
  pg_temp.uid(CASE WHEN n<=2 THEN 901 ELSE 902 END) FROM generate_series(1,13)n
ON CONFLICT(id) DO UPDATE SET school_id=excluded.school_id,university=excluded.university;
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private,created_at)
SELECT pg_temp.uid(n),pg_temp.uid(CASE WHEN n=101 THEN 2 ELSE 3+n%11 END),
  pg_temp.uid(CASE WHEN n=101 THEN 901 ELSE 902 END),'forum','V2 fixture '||n,'Database test only',
  'active',false,false,transaction_timestamp()-((n-101)||' minutes')::interval FROM generate_series(101,190)n;
INSERT INTO forum_posts(id,board_id,allow_comments,is_pinned,is_locked)
SELECT pg_temp.uid(n),(SELECT id FROM forum_boards WHERE status<>'archived' ORDER BY id LIMIT 1),true,false,false
FROM generate_series(101,190)n;
SET CONSTRAINTS ALL IMMEDIATE;
UPDATE recommendation_configuration SET rollout_percentage=100,shadow_enabled=true;
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
SELECT ok(pg_temp.allow_post(102),'off permits foreign post without score');
SELECT results_eq('SELECT * FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80)',
  'SELECT * FROM test_v2_baseline_rank(pg_temp.uid(1),NULL,80)','off: exact Top 80 IDs/order/all score components match V1');
CREATE TEMP TABLE sessions(label text primary key,id uuid);
INSERT INTO sessions VALUES ('baseline',test_v2_baseline_session(true,false,NULL)),('off',create_recommendation_feed_session(true,false,NULL));
SELECT results_eq($q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='off') ORDER BY position$q$,
 $q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='baseline') ORDER BY position$q$,
 'off: all shaped items, scores, positions and shaping reasons match V1');
SELECT is((SELECT count(*) FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label='off')),60::bigint,'fixture exercises 60-item shaping limit');
SELECT is((SELECT count(*) FROM get_recommendation_feed_page((SELECT id FROM sessions WHERE label='off'),0,999)),20::bigint,'page limit remains 20');
SELECT results_eq($q$SELECT post_id,position FROM get_recommendation_feed_page((SELECT id FROM sessions WHERE label='off'),20,20)$q$,
 $q$SELECT post_id,position FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label='baseline') ORDER BY position OFFSET 20 LIMIT 20$q$,'page two keeps V1 order');

INSERT INTO cross_school_models(version,artifact)
SELECT 'v1-test',jsonb_build_object('schema_version',1,'model_name','cross-school-logistic','version','v1-test',
 'embedding_model','gemini-embedding-2','embedding_version','cheese-semantic-v1','dimension',768,
 'input_format_version',1,'weights',ARRAY[2::float8]||array_fill(0::float8,ARRAY[767]),'bias',0,
 'threshold',0.55,'threshold_version','test-055','dataset_version','synthetic-db-test',
 'trained_at','2026-09-09T00:00:00Z','metrics','{}'::jsonb);
SELECT ok(recommendation_private.valid_model(artifact),'valid fixture model accepted') FROM cross_school_models WHERE version='v1-test';
SELECT ok(NOT recommendation_private.valid_model(artifact||'{"dimension":3}'),'wrong model dimension rejected') FROM cross_school_models WHERE version='v1-test';
SELECT ok(abs(recommendation_private.predict(artifact,pg_temp.vec(1))-0.8807970779778823)<1e-14,'SQL sigmoid/dot product matches analytic reference') FROM cross_school_models WHERE version='v1-test';
SELECT is(recommendation_private.predict(artifact,pg_temp.vec(0)),NULL::float8,'zero vector fails closed') FROM cross_school_models WHERE version='v1-test';
SELECT is(recommendation_private.predict(artifact,'[1,0]'::vector),NULL::float8,'wrong vector dimension fails closed') FROM cross_school_models WHERE version='v1-test';
SELECT is(recommendation_private.sigmoid(1000),1::float8,'positive extreme stable');
SELECT is(recommendation_private.sigmoid(-1000),0::float8,'negative extreme stable');
SELECT is(recommendation_private.sigmoid('NaN'),NULL::float8,'NaN rejected');
SELECT throws_ok($$UPDATE cross_school_models SET artifact=artifact||'{"bias":1}' WHERE version='v1-test'$$,'P0001',NULL,'model parameters immutable');
SELECT throws_ok($$UPDATE cross_school_configuration SET gate_enabled=true$$,'P0001',NULL,'cannot enable gate without model');
UPDATE cross_school_configuration SET model_version='v1-test',scoring_enabled=true,shadow_enabled=true,shadow_sample_percentage=100,threshold_version='test-055';
SELECT throws_ok($$UPDATE cross_school_configuration SET gate_enabled=true$$,'P0001',NULL,'unapproved model cannot filter');
UPDATE post_embeddings SET embedding=pg_temp.vec(CASE WHEN post_id=pg_temp.uid(103) THEN -1 ELSE 1 END),status='ready',generated_at=clock_timestamp()
WHERE post_id BETWEEN pg_temp.uid(102) AND pg_temp.uid(190);
SELECT is((SELECT count(*) FROM cross_school_scores WHERE model_version='v1-test'),89::bigint,'ready embedding trigger scores all fixture embeddings');
SELECT ok(NOT recommendation_private.score_post(pg_temp.uid(102)),'current cached score not recomputed');
SELECT results_eq('SELECT * FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80)',
 'SELECT * FROM test_v2_baseline_rank(pg_temp.uid(1),NULL,80)','shadow: exact rank scores and order match V1');
INSERT INTO sessions VALUES ('shadow',create_recommendation_feed_session(true,false,NULL)),('shadow-baseline',test_v2_baseline_session(true,false,NULL));
SELECT results_eq($q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='shadow') ORDER BY position$q$,
 $q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='shadow-baseline') ORDER BY position$q$,
 'shadow: all shaped items/components still match V1');
SELECT is((SELECT count(*) FROM cross_school_shadow_decisions WHERE session_id=(SELECT id FROM sessions WHERE label='shadow')),60::bigint,'100 percent shadow sample observes every shaped item');
SELECT ok(EXISTS(SELECT 1 FROM cross_school_shadow_decisions WHERE post_id=pg_temp.uid(103) AND NOT would_allow),'shadow observes low-score rejection without filtering');
UPDATE cross_school_models SET approved_for_filtering=true WHERE version='v1-test';
UPDATE cross_school_configuration SET gate_enabled=true,rollout_percentage=100;
SELECT ok((get_recommendation_feed_mode()).cross_school_gate_enabled,'supported client enters gate');
SELECT ok(pg_temp.allow_post(101),'same school remains eligible with no embedding or score');
SELECT ok(pg_temp.allow_post(102),'foreign high q passes');
SELECT ok(NOT pg_temp.allow_post(103),'foreign low q rejected');
UPDATE cross_school_scores SET probability=0.55 WHERE post_id=pg_temp.uid(102);
SELECT ok(pg_temp.allow_post(102),'q equals threshold passes (inclusive boundary)');
UPDATE cross_school_scores SET probability=0.549999 WHERE post_id=pg_temp.uid(102);
SELECT ok(NOT pg_temp.allow_post(102),'q just below threshold rejected');
DELETE FROM cross_school_scores WHERE post_id=pg_temp.uid(102);
SELECT ok(NOT pg_temp.allow_post(102),'missing foreign score fails closed');
SELECT ok(recommendation_private.score_post(pg_temp.uid(102)),'missing score can be backfilled');
SELECT ok(NOT (SELECT would_allow FROM recommendation_private.decision(pg_temp.uid(102),pg_temp.uid(999))),'unknown viewer school fails closed');
SELECT throws_ok($$UPDATE forum_posts SET origin_school_id=pg_temp.uid(902) WHERE id=pg_temp.uid(101)$$,'42501',NULL,'post origin cannot be reassigned');
UPDATE profiles SET school_id=pg_temp.uid(902),university='V2 Test School B' WHERE id=pg_temp.uid(2);
SELECT is((SELECT origin_school_id FROM forum_posts WHERE id=pg_temp.uid(101)),pg_temp.uid(901),'author school change does not rewrite historical origin');
SELECT throws_ok($$SELECT * FROM get_recommendation_feed_page((SELECT id FROM sessions WHERE label='off'),0,20)$$,'P0001','recommendation_session_stale','enabling gate rejects old unfiltered session');
INSERT INTO sessions VALUES ('gated',create_recommendation_feed_session(false,false,NULL));
SELECT ok((SELECT id FROM sessions WHERE label='gated')<>(SELECT id FROM sessions WHERE label='shadow'),'stale cached session is not reused');
SELECT ok(NOT EXISTS(SELECT 1 FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='gated') AND NOT recommendation_private.allowed(post_id,pg_temp.uid(1))),'every gated session item passes gate');
SELECT ok(EXISTS(SELECT 1 FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80) WHERE post_id=pg_temp.uid(101)),'same-school no-score post remains in actual ranker');
SELECT ok(NOT EXISTS(SELECT 1 FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80) WHERE post_id=pg_temp.uid(103)),'foreign low q absent from actual ranker');
SELECT is(create_recommendation_feed_session(false,false,NULL),(SELECT id FROM sessions WHERE label='gated'),'valid gated session reused');
UPDATE cross_school_configuration SET threshold=0.56,threshold_version='test-056';
SELECT ok(NOT recommendation_private.session_valid((SELECT id FROM sessions WHERE label='gated')),'threshold revision invalidates session');
INSERT INTO sessions VALUES ('gated-new',create_recommendation_feed_session(true,false,NULL));
UPDATE profiles SET school_id=pg_temp.uid(902),university='V2 Test School B' WHERE id=pg_temp.uid(1);
SELECT ok(NOT recommendation_private.session_valid((SELECT id FROM sessions WHERE label='gated-new')),'viewer school change invalidates session');
UPDATE profiles SET school_id=pg_temp.uid(901),university='V2 Test School A' WHERE id=pg_temp.uid(1);

CREATE TEMP TABLE revisions AS SELECT cross_school_revision FROM post_embeddings WHERE post_id=pg_temp.uid(102);
UPDATE cross_school_configuration SET scoring_enabled=false,gate_enabled=false;
UPDATE post_embeddings SET embedding=pg_temp.vec(-1) WHERE post_id=pg_temp.uid(102);
SELECT is((SELECT cross_school_revision FROM post_embeddings WHERE post_id=pg_temp.uid(102)),(SELECT cross_school_revision+1 FROM revisions),'vector change at identical input hash increments cache revision');
UPDATE cross_school_configuration SET scoring_enabled=true,gate_enabled=true;
SELECT ok(NOT pg_temp.allow_post(102),'stale cached score rejected after same-hash vector change');
SELECT ok(recommendation_private.score_post(pg_temp.uid(102)),'stale vector can be rescored');
SELECT ok(NOT pg_temp.allow_post(102),'rescored low q remains rejected');
UPDATE post_embeddings SET embedding=pg_temp.vec(0) WHERE post_id=pg_temp.uid(102);
SELECT is((SELECT status FROM post_embeddings WHERE post_id=pg_temp.uid(102)),'ready','classifier failure does not roll back V1 ready embedding');
SELECT is((SELECT failure_reason FROM cross_school_scores WHERE post_id=pg_temp.uid(102)),'invalid_embedding','invalid embedding failure recorded');
SELECT ok(NOT pg_temp.allow_post(102),'invalid embedding cannot pass gate');
-- A cached invalid vector must not starve later posts in small backfill batches.
DELETE FROM cross_school_scores WHERE post_id IN (pg_temp.uid(104),pg_temp.uid(105));
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','service_role')::text,true);
SET LOCAL ROLE service_role;
SELECT is(backfill_cross_school_scores(1),1,'batch backfill advances past cached invalid embedding');
SELECT is(backfill_cross_school_scores(1),1,'next batch advances to next missing score');
SELECT is(backfill_cross_school_scores(1),0,'completed backfill is idempotent');
SELECT lives_ok('SELECT get_cross_school_metrics()','service role can read score metrics');
RESET ROLE;
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT set_config('request.headers','{}',true);
SELECT ok(NOT (get_recommendation_feed_mode()).cross_school_gate_enabled,'legacy client excluded from V2 rollout');
SELECT set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
UPDATE recommendation_configuration SET rollout_percentage=0;
SELECT ok(NOT (get_recommendation_feed_mode()).cross_school_gate_enabled,'V1 rollout zero also disables effective V2 gate');
UPDATE recommendation_configuration SET rollout_percentage=100;

-- Actual role switching, not only ACL catalog inspection.
SET LOCAL ROLE authenticated;
SELECT throws_ok('SELECT * FROM public.cross_school_scores','42501',NULL,'authenticated cannot read scores');
SELECT throws_ok('UPDATE public.cross_school_configuration SET gate_enabled=false','42501',NULL,'authenticated cannot change configuration');
SELECT throws_ok('SELECT * FROM public.cross_school_models','42501',NULL,'authenticated cannot read model');
SELECT throws_ok('SELECT * FROM public.cross_school_shadow_decisions','42501',NULL,'authenticated cannot read shadow log');
SELECT throws_ok('SELECT public.backfill_cross_school_scores(1)','42501',NULL,'authenticated cannot invoke backfill');
SELECT throws_ok('SELECT public.get_cross_school_metrics()','42501',NULL,'authenticated cannot invoke metrics');
SELECT lives_ok($$SELECT * FROM filter_cross_school_recommendation_posts(ARRAY['29000000-0000-4000-8000-000000000101'::uuid])$$,'authenticated can invoke public featured gate');
SELECT is((SELECT count(*) FROM filter_cross_school_recommendation_posts(ARRAY['29000000-0000-4000-8000-000000000103'::uuid])),0::bigint,'public featured gate excludes foreign low q');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok('SELECT * FROM public.cross_school_scores','42501',NULL,'anon cannot read scores');
SELECT throws_ok('SELECT * FROM public.filter_cross_school_recommendation_posts(ARRAY[]::uuid[])','42501',NULL,'anon cannot invoke featured gate');
RESET ROLE;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(2),'role','authenticated')::text,true);
SELECT is((SELECT count(*) FROM get_recommendation_feed_page((SELECT id FROM sessions WHERE label='gated-new'),0,20)),0::bigint,'another user cannot read real existing session');
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
UPDATE cross_school_configuration SET gate_enabled=false;
SELECT ok(NOT recommendation_private.session_valid((SELECT id FROM sessions WHERE label='gated-new')),'rollback invalidates filtered session');
SELECT results_eq('SELECT * FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80)',
 'SELECT * FROM test_v2_baseline_rank(pg_temp.uid(1),NULL,80)','rollback restores exact V1 ranking');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('cross_school_models'::regclass,'cross_school_configuration'::regclass,'cross_school_scores'::regclass,'cross_school_shadow_decisions'::regclass)),'all new public tables have RLS');
SELECT * FROM finish();
ROLLBACK;
