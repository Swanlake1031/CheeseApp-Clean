-- Actual ranker/session regressions. Synthetic data and temporary function
-- substitutions are transaction-local and all roll back. Never run on production.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT no_plan();
SELECT is(md5(replace(prosrc,
 'LEAST(0.15, 0.05 * GREATEST(0, eligible.ignored_count - 1))',
 'LEAST(0.45, 0.15 * GREATEST(0, eligible.ignored_count - 1))')),
 '9c118d72c1953fa9b05480d5833bfb85','entire audited ranker unchanged except two penalty constants')
FROM pg_proc WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure;
SELECT ok(strpos(prosrc,'LEAST(0.15, 0.05 * GREATEST(0, eligible.ignored_count - 1))')>0,
 'new penalty is actually installed') FROM pg_proc WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure;
SELECT is(md5(prosrc),'4c9dfa65352fd43c72bd83c49dae8e8d','session creation and all diversity passes unchanged')
FROM pg_proc WHERE oid='public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure;
SELECT is(md5(prosrc),'fdb4ac4d1601c0fd4385df59a7c1b913','fixed-session paging unchanged')
FROM pg_proc WHERE oid='public.get_recommendation_feed_page(uuid,integer,integer)'::regprocedure;
SELECT is(md5(prosrc),'cd78f40306f76145c8259d4ef94063d9','chronological continuation unchanged')
FROM pg_proc WHERE oid='public.get_forum_continuation_page(uuid[],timestamptz,uuid,integer)'::regprocedure;
SELECT is(ARRAY[semantic_weight,engagement_weight,freshness_weight,quality_weight,author_weight,exploration_weight],
 ARRAY[0.40,0.20,0.15,0.10,0.05,0.10]::float8[],'all six production feature weights unchanged') FROM recommendation_configuration;

-- Freeze rank-time in BOTH variants, so freshness cannot drift during comparison.
DO $$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure) INTO d;
 d:=replace(d,'clock_timestamp()','transaction_timestamp()'); EXECUTE d;
 EXECUTE replace(replace(d,'public.rank_forum_recommendations_v1(', 'public.test_ignore_before('),
  'LEAST(0.15, 0.05 * GREATEST(0, eligible.ignored_count - 1))',
  'LEAST(0.45, 0.15 * GREATEST(0, eligible.ignored_count - 1))');
 SELECT pg_get_functiondef('public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure) INTO d;
 d:=replace(d,'clock_timestamp()','transaction_timestamp()'); EXECUTE d;
 EXECUTE replace(replace(d,'public.create_recommendation_feed_session(', 'public.test_ignore_before_session('),
  'public.rank_forum_recommendations_v1(', 'public.test_ignore_before(');
END $$;
CREATE FUNCTION pg_temp.uid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('19041700-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;
INSERT INTO auth.users(id,email) SELECT pg_temp.uid(n),'ignore-'||n||'@test.invalid' FROM generate_series(1,8)n;
CREATE TEMP TABLE cases(n integer,ignored integer,expected float8);
INSERT INTO cases VALUES(101,0,0),(102,1,0),(103,2,0.05),(104,3,0.10),(105,4,0.15),(106,10,0.15);
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private,created_at)
SELECT pg_temp.uid(c.n),pg_temp.uid(2),p.school_id,'forum','Ignore regression','Rollback fixture','active',false,false,transaction_timestamp()
FROM cases c CROSS JOIN profiles p WHERE p.id=pg_temp.uid(1);
INSERT INTO forum_posts(id,board_id,allow_comments,is_pinned,is_locked)
SELECT pg_temp.uid(n),(SELECT id FROM forum_boards WHERE status<>'archived' ORDER BY id LIMIT 1),true,false,false FROM cases;
SET CONSTRAINTS ALL IMMEDIATE;
INSERT INTO post_recommendation_metrics(post_id,e_normalized)
SELECT pg_temp.uid(n),1 FROM cases ON CONFLICT(post_id) DO UPDATE SET e_normalized=1;
INSERT INTO recommendation_events(event_id,user_id,post_id,event_type,created_at)
SELECT gen_random_uuid(),pg_temp.uid(1),pg_temp.uid(c.n),'qualified_impression',transaction_timestamp()-interval '1 hour'
FROM cases c CROSS JOIN LATERAL generate_series(1,c.ignored) i;
-- Distractors must not count: outside seven days, another viewer, wrong event.
INSERT INTO recommendation_events(event_id,user_id,post_id,event_type,created_at)
SELECT gen_random_uuid(),pg_temp.uid(1),pg_temp.uid(101),'qualified_impression',transaction_timestamp()-interval '8 days' FROM generate_series(1,10);
INSERT INTO recommendation_events(event_id,user_id,post_id,event_type,created_at)
SELECT gen_random_uuid(),pg_temp.uid(3),pg_temp.uid(101),'qualified_impression',transaction_timestamp() FROM generate_series(1,10);
INSERT INTO recommendation_events(event_id,user_id,post_id,event_type,created_at)
SELECT gen_random_uuid(),pg_temp.uid(1),pg_temp.uid(101),'impression',transaction_timestamp() FROM generate_series(1,10);
UPDATE recommendation_configuration SET rollout_percentage=100;
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
CREATE TEMP TABLE actual AS SELECT * FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80);
CREATE TEMP TABLE previous AS SELECT * FROM test_ignore_before(pg_temp.uid(1),NULL,80);
SELECT ok(abs(a.repeat_ignore_penalty-c.expected)<1e-12,'ignored_count='||c.ignored||' penalty='||c.expected)
FROM cases c LEFT JOIN actual a ON a.post_id=pg_temp.uid(c.n) ORDER BY c.n;
SELECT is((SELECT count(*) FROM actual JOIN cases c ON post_id=pg_temp.uid(c.n)),6::bigint,
 'all six ignored-count cases remain eligible, including ten ignores');
SELECT ok((SELECT bool_and(repeat_ignore_penalty BETWEEN 0 AND 0.15) FROM actual),'no current penalty exceeds 0.15');
SELECT ok((SELECT bool_and(repeat_ignore_penalty=0) FROM actual JOIN cases c ON post_id=pg_temp.uid(c.n) WHERE c.ignored<=1),
 'zero and one ignore produce exactly zero');
SELECT ok((SELECT bool_and(abs(ranking_score-(base_ranking_score-repeat_ignore_penalty))<1e-12) FROM actual),'score equals base minus penalty');
SELECT results_eq($q$SELECT to_jsonb(a)-'repeat_ignore_penalty'-'ranking_score' FROM actual a ORDER BY post_id$q$,
 $q$SELECT to_jsonb(p)-'repeat_ignore_penalty'-'ranking_score' FROM previous p ORDER BY post_id$q$,
 'every other returned feature/base/eligible ID equals the old production ranker');
SELECT ok((SELECT abs(base_ranking_score-0.65)<1e-12 AND abs(ranking_score-0.55)<1e-12 FROM actual WHERE post_id=pg_temp.uid(104)),
 'actual base 0.65 with three ignores now ranks 0.55');
SELECT ok((SELECT abs(base_ranking_score-0.65)<1e-12 AND abs(ranking_score-0.35)<1e-12 FROM previous WHERE post_id=pg_temp.uid(104)),
 'same actual post previously ranked 0.35');

-- Existing fixed sessions retain old persisted scores; only new sessions change.
CREATE TEMP TABLE sessions(label text PRIMARY KEY,id uuid);
INSERT INTO sessions VALUES('old',test_ignore_before_session(true,false,NULL));
CREATE TEMP TABLE old_items AS SELECT * FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label='old');
SELECT is(create_recommendation_feed_session(false,false,NULL),(SELECT id FROM sessions WHERE label='old'),
 'valid existing session reused without forced invalidation');
INSERT INTO sessions VALUES('new',create_recommendation_feed_session(true,false,NULL));
SELECT results_eq('SELECT * FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label=''old'') ORDER BY position',
 'SELECT * FROM old_items ORDER BY position','persisted old session scores and positions untouched');
SELECT ok((SELECT abs(repeat_ignore_penalty-0.10)<1e-12 FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label='new') AND post_id=pg_temp.uid(104)),
 'actual new session stores softened penalty');

INSERT INTO recommendation_events(event_id,user_id,post_id,event_type,created_at)
SELECT gen_random_uuid(),pg_temp.uid(1),pg_temp.uid(101),'qualified_impression',transaction_timestamp()-interval '7 days' FROM generate_series(1,2);
SELECT ok((SELECT abs(repeat_ignore_penalty-0.05)<1e-12 FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80) WHERE post_id=pg_temp.uid(101)),
 'exactly seven-day-old qualified impressions still count inclusively');
INSERT INTO user_post_signal_state(user_id,post_id,is_liked,effective_weight)
VALUES(pg_temp.uid(1),pg_temp.uid(106),true,3) ON CONFLICT(user_id,post_id) DO UPDATE SET effective_weight=3,is_liked=true;
SELECT is((SELECT repeat_ignore_penalty FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80) WHERE post_id=pg_temp.uid(106)),0::float8,
 'positive effective signal still suppresses ignored-count penalty');

-- Larger no-ignore pool: compare exact Top 80 and all three shaping outputs.
DELETE FROM recommendation_events WHERE user_id=pg_temp.uid(1);
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private,created_at)
SELECT pg_temp.uid(n),pg_temp.uid(2+n%7),p.school_id,'forum','Shaping fixture','Rollback fixture','active',false,false,transaction_timestamp()
FROM generate_series(107,190)n CROSS JOIN profiles p WHERE p.id=pg_temp.uid(1);
INSERT INTO forum_posts(id,board_id,allow_comments,is_pinned,is_locked)
SELECT pg_temp.uid(n),(SELECT id FROM forum_boards WHERE status<>'archived' ORDER BY id LIMIT 1),true,false,false FROM generate_series(107,190)n;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT is((SELECT count(*) FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,999)),80::bigint,'Top 80 cap preserved for a 90+ post pool');
SELECT results_eq('SELECT * FROM rank_forum_recommendations_v1(pg_temp.uid(1),NULL,80)',
 'SELECT * FROM test_ignore_before(pg_temp.uid(1),NULL,80)','without ignores, full Top 80 IDs/order/features/scores are identical');
INSERT INTO sessions VALUES('shape-old',test_ignore_before_session(true,false,NULL)),('shape-new',create_recommendation_feed_session(true,false,NULL));
SELECT is((SELECT count(*) FROM feed_session_items WHERE session_id=(SELECT id FROM sessions WHERE label='shape-new')),60::bigint,'session still capped at 60');
SELECT results_eq($q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='shape-new') ORDER BY position$q$,
 $q$SELECT to_jsonb(i)-'session_id' FROM feed_session_items i WHERE session_id=(SELECT id FROM sessions WHERE label='shape-old') ORDER BY position$q$,
 'all shaped positions, scores, pass numbers and reasons unchanged when penalties equal');
SELECT is((SELECT count(*) FROM get_recommendation_feed_page((SELECT id FROM sessions WHERE label='shape-new'),0,999)),20::bigint,'page size remains 20');
SELECT * FROM finish();
ROLLBACK;
