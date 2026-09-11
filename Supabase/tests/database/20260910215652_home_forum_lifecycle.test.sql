-- Isolated rollback-only lifecycle regression. Never run against production.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT no_plan();
CREATE FUNCTION pg_temp.uid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('21565200-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;
SELECT is(md5(prosrc),'956bf92f2fbab03a50d7d8ed96c7b61f','softer ignore policy and full ranker remain untouched') FROM pg_proc WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure;
SELECT is(md5(prosrc),'4c9dfa65352fd43c72bd83c49dae8e8d','original session shaping implementation untouched') FROM pg_proc WHERE oid='public.create_recommendation_feed_session(boolean,boolean,uuid)'::regprocedure;
SELECT is(md5(prosrc),'cd78f40306f76145c8259d4ef94063d9','continuation implementation untouched') FROM pg_proc WHERE oid='public.get_forum_continuation_page(uuid[],timestamptz,uuid,integer)'::regprocedure;
SELECT ok(strpos(prosrc,'pg_advisory_xact_lock')>0,'resolver serializes concurrent creation per account') FROM pg_proc WHERE oid='public.resolve_home_forum_session()'::regprocedure;
SELECT ok(NOT has_function_privilege('anon','public.resolve_home_forum_session()','EXECUTE'),'anonymous role cannot resolve sessions');
INSERT INTO auth.users(id,email) SELECT pg_temp.uid(n),'lifecycle-'||n||'@test.invalid' FROM generate_series(1,3)n;
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private,created_at)
SELECT pg_temp.uid(n),pg_temp.uid(2),p.school_id,'forum','Lifecycle fixture','Rollback only','active',false,false,now()
FROM generate_series(101,125)n CROSS JOIN profiles p WHERE p.id=pg_temp.uid(1);
INSERT INTO forum_posts(id,board_id,allow_comments,is_pinned,is_locked)
SELECT pg_temp.uid(n),(SELECT id FROM forum_boards WHERE status<>'archived' ORDER BY id LIMIT 1),true,false,false FROM generate_series(101,125)n;
SET CONSTRAINTS ALL IMMEDIATE;
UPDATE recommendation_configuration SET rollout_percentage=100;
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
CREATE TEMP TABLE responses(label text PRIMARY KEY,payload jsonb);
INSERT INTO responses VALUES('first',resolve_home_forum_session());
SELECT is((SELECT payload->>'reason' FROM responses WHERE label='first'),'missing_session','first load creates only when missing');
SELECT ok((SELECT NOT (payload->>'reused')::boolean FROM responses WHERE label='first'),'new session reported honestly');
SELECT ok((SELECT abs(extract(epoch FROM ((payload->>'expires_at')::timestamptz-(payload->>'created_at')::timestamptz))-900)<1 FROM responses WHERE label='first'),'15 minute lifetime for new sessions');
CREATE TEMP TABLE original_items AS SELECT * FROM feed_session_items WHERE session_id=(SELECT (payload->>'session_id')::uuid FROM responses WHERE label='first');

-- Make ANY ranking call fail, proving valid resolution does not recompute even
-- after ranking-input changes, foreground-like requests and repeated pulls.
CREATE TEMP TABLE original_rank AS SELECT pg_get_functiondef('public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure) AS definition;
DO $$ DECLARE d text; BEGIN SELECT definition INTO d FROM original_rank;
 EXECUTE replace(d,'config.semantic_weight * features.s','(1.0 / 0.0) + config.semantic_weight * features.s'); END $$;
INSERT INTO post_recommendation_metrics(post_id,e_normalized) VALUES(pg_temp.uid(101),0.9) ON CONFLICT(post_id) DO UPDATE SET e_normalized=0.9;
INSERT INTO responses VALUES('normal',resolve_home_forum_session()),('pull1',resolve_home_forum_session()),('pull2',resolve_home_forum_session()),('foreground',resolve_home_forum_session()),('restart',resolve_home_forum_session());
SELECT is(payload->>'session_id',(SELECT payload->>'session_id' FROM responses WHERE label='first'),label||' reuses same session without rank call') FROM responses WHERE label<>'first' ORDER BY label;
SELECT ok((SELECT bool_and((payload->>'reused')::boolean) FROM responses WHERE label<>'first'),'all subsequent resolutions report reuse');
SELECT is((SELECT count(*) FROM feed_sessions WHERE user_id=pg_temp.uid(1) AND NOT is_shadow),1::bigint,'repeated requests do not create duplicate sessions');
SELECT results_eq('SELECT * FROM feed_session_items WHERE session_id=(SELECT (payload->>''session_id'')::uuid FROM responses WHERE label=''first'') ORDER BY position',
 'SELECT * FROM original_items ORDER BY position','ranking inputs and pulls cannot rewrite stored scores or positions');
-- Freeze only the resolver clock in a rollback-only test clone. This exercises
-- its real strict boundary without sleeping or racing a one-second interval.
CREATE FUNCTION pg_temp.resolver_clock() RETURNS timestamptz LANGUAGE sql AS $$
 SELECT current_setting('test.resolver_time')::timestamptz
$$;
DO $$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.resolve_home_forum_session()'::regprocedure) INTO d;
 EXECUTE replace(replace(d, 'public.resolve_home_forum_session()', 'public.test_ttl_resolver()'),
                 'clock_timestamp()', 'pg_temp.resolver_clock()');
END $$;
SELECT set_config('test.resolver_time',
 ((SELECT (payload->>'created_at')::timestamptz FROM responses WHERE label='first') + interval '14 minutes 59 seconds')::text,true);
SELECT is(test_ttl_resolver()->>'session_id',
 (SELECT payload->>'session_id' FROM responses WHERE label='first'),
 'T+14:59 reuses session without invoking trapped ranker');
SELECT set_config('test.resolver_time',
 (SELECT payload->>'expires_at' FROM responses WHERE label='first'),true);
SELECT throws_ok('SELECT test_ttl_resolver()', '22012', 'division by zero',
 'exact expiry is invalid and invokes ranking for replacement');
SELECT set_config('test.resolver_time',
 ((SELECT (payload->>'expires_at')::timestamptz FROM responses WHERE label='first') + interval '1 second')::text,true);
SELECT throws_ok('SELECT test_ttl_resolver()', '22012', 'division by zero',
 'after expiry invokes ranking for replacement');
DO $$ DECLARE d text; BEGIN SELECT definition INTO d FROM original_rank; EXECUTE d; END $$;
INSERT INTO responses VALUES('boundary-replacement',test_ttl_resolver());
SELECT isnt((SELECT payload->>'session_id' FROM responses WHERE label='boundary-replacement'),
 (SELECT payload->>'session_id' FROM responses WHERE label='first'),'expired boundary replaces session after real ranking succeeds');
-- Remove only this rollback-only extra fixture so original lifecycle counts remain exact.
DELETE FROM feed_sessions WHERE id=(SELECT (payload->>'session_id')::uuid FROM responses WHERE label='boundary-replacement');

UPDATE feed_sessions SET expires_at=now()-interval '1 second' WHERE id=(SELECT (payload->>'session_id')::uuid FROM responses WHERE label='first');
SELECT is((SELECT count(*) FROM feed_sessions WHERE user_id=pg_temp.uid(1) AND NOT is_shadow),1::bigint,'expiry itself creates nothing');
INSERT INTO responses VALUES('expired-normal',resolve_home_forum_session());
SELECT isnt((SELECT payload->>'session_id' FROM responses WHERE label='expired-normal'),(SELECT payload->>'session_id' FROM responses WHERE label='first'),'next normal request creates S2 after expiry');
SELECT is((SELECT payload->>'reason' FROM responses WHERE label='expired-normal'),'expired_session','expiry creation reason recorded');
UPDATE feed_sessions SET expires_at=now()-interval '1 second' WHERE user_id=pg_temp.uid(1);
INSERT INTO responses VALUES('expired-pull',resolve_home_forum_session());
SELECT is((SELECT payload->>'reason' FROM responses WHERE label='expired-pull'),'expired_session','pull after expiry creates because expired, not gesture');
SELECT isnt((SELECT payload->>'session_id' FROM responses WHERE label='expired-pull'),(SELECT payload->>'session_id' FROM responses WHERE label='expired-normal'),'expired pull gets new identity');

SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(3),'role','authenticated')::text,true);
INSERT INTO responses VALUES('account-b',resolve_home_forum_session());
SELECT isnt((SELECT payload->>'session_id' FROM responses WHERE label='account-b'),(SELECT payload->>'session_id' FROM responses WHERE label='expired-pull'),'another account cannot reuse A session');
SELECT is((SELECT user_id FROM feed_sessions WHERE id=(SELECT (payload->>'session_id')::uuid FROM responses WHERE label='account-b')),pg_temp.uid(3),'resolved session belongs to current account');
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT is(resolve_home_forum_session()->>'session_id',(SELECT payload->>'session_id' FROM responses WHERE label='expired-pull'),'return to A can reuse its still-valid server session');

INSERT INTO user_hidden_forum_posts(user_id,post_id) VALUES(pg_temp.uid(1),pg_temp.uid(101));
INSERT INTO responses VALUES('hidden',resolve_home_forum_session());
SELECT is((SELECT payload->>'reason' FROM responses WHERE label='hidden'),'server_policy_invalidated','visibility invalidation legitimately creates new session');
SELECT ok(NOT EXISTS(SELECT 1 FROM responses r,jsonb_array_elements(r.payload->'items') i WHERE r.label='hidden' AND (i->>'post_id')::uuid=pg_temp.uid(101)),'hidden post absent from new protected candidate set');
SELECT is((SELECT count(*) FROM validate_home_forum_posts(ARRAY[pg_temp.uid(101),pg_temp.uid(102)])),1::bigint,'cached continuation validation removes hidden items');
INSERT INTO user_blocks(blocker_id,blocked_id) VALUES(pg_temp.uid(1),pg_temp.uid(2));
SELECT is((SELECT count(*) FROM validate_home_forum_posts(ARRAY[pg_temp.uid(102)])),0::bigint,'cached continuation retains block protection');
DELETE FROM user_blocks WHERE blocker_id=pg_temp.uid(1);
UPDATE posts SET is_private=true WHERE id=pg_temp.uid(102);
SELECT is((SELECT count(*) FROM validate_home_forum_posts(ARRAY[pg_temp.uid(102)])),0::bigint,'cached continuation retains private protection');
SELECT set_config('request.jwt.claims','{}',true);
SELECT throws_ok('SELECT resolve_home_forum_session()','42501','Authentication required','unauthenticated resolution fails closed');
SELECT throws_ok('SELECT * FROM validate_home_forum_posts(ARRAY[]::uuid[])','42501','Authentication required','unauthenticated continuation validation fails closed');
SELECT * FROM finish();
ROLLBACK;
