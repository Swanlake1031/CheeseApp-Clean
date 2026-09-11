BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT no_plan();
CREATE FUNCTION pg_temp.uid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('61558000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;
INSERT INTO schools(id,name,city) VALUES (pg_temp.uid(901),'Continuation A','Test'),(pg_temp.uid(902),'Continuation B','Test');
INSERT INTO auth.users(id,email) SELECT pg_temp.uid(n),'continuation-'||n||'@test.invalid' FROM generate_series(1,3)n;
UPDATE profiles SET school_id=pg_temp.uid(901) WHERE id IN(pg_temp.uid(1),pg_temp.uid(2));
UPDATE profiles SET school_id=pg_temp.uid(902) WHERE id=pg_temp.uid(3);
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private,created_at)
SELECT pg_temp.uid(n),pg_temp.uid(CASE WHEN n=186 THEN 3 ELSE 2 END),
 pg_temp.uid(CASE WHEN n=186 THEN 902 ELSE 901 END),'forum','Continuation test','Rollback only','active',false,n=184,'2026-09-01 00:00:00.123456+00'
FROM generate_series(101,186)n;
INSERT INTO forum_posts(id,board_id,allow_comments,is_pinned,is_locked)
SELECT pg_temp.uid(n),(SELECT id FROM forum_boards WHERE status<>'archived' ORDER BY id LIMIT 1),true,false,false
FROM generate_series(101,186)n;
SET CONSTRAINTS ALL IMMEDIATE;
INSERT INTO user_hidden_forum_posts(user_id,post_id) VALUES(pg_temp.uid(1),pg_temp.uid(185));
INSERT INTO cross_school_models(version,artifact,approved_for_filtering)
SELECT 'v1-continuation-test',jsonb_build_object('schema_version',1,'model_name','cross-school-logistic','version','v1-continuation-test',
 'embedding_model','gemini-embedding-2','embedding_version','cheese-semantic-v1','dimension',768,
 'input_format_version',1,'weights',ARRAY[2::float8]||array_fill(0::float8,ARRAY[767]),'bias',0,
 'threshold',0.55,'threshold_version','test-055','dataset_version','synthetic-db-test',
 'trained_at','2026-09-09T00:00:00Z','metrics','{}'::jsonb),true;
UPDATE recommendation_configuration SET rollout_percentage=100;
UPDATE cross_school_configuration SET model_version='v1-continuation-test',threshold_version='test-055',scoring_enabled=true,gate_enabled=true,rollout_percentage=100;
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.uid(1),'role','authenticated')::text,true);
SELECT set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
CREATE TEMP TABLE exclusions AS SELECT array_agg(pg_temp.uid(n)) ids FROM generate_series(101,160)n;
GRANT SELECT ON exclusions TO authenticated;
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM get_forum_continuation_page('{}',NULL,NULL,999)),20::bigint,'page size capped at 20');
SELECT throws_ok($q$SELECT * FROM get_forum_continuation_page('{}',now(),NULL,20)$q$,'22023','Both cursor fields are required','partial cursor rejected');
CREATE TEMP TABLE page1 AS SELECT * FROM get_forum_continuation_page((SELECT ids FROM exclusions));
SELECT is((SELECT count(*) FROM page1),20::bigint,'continuation beyond initial 60 returns full first page');
SELECT is((SELECT max(post_id::text) FROM page1),pg_temp.uid(183)::text,'private hidden and foreign missing-score rows excluded');
SELECT is((SELECT min(post_id::text) FROM page1),pg_temp.uid(164)::text,'same-timestamp UUID tie breaker is stable');
CREATE TEMP TABLE page2 AS SELECT * FROM get_forum_continuation_page((SELECT ids FROM exclusions),'2026-09-01 00:00:00.123456+00',pg_temp.uid(164),20);
SELECT is((SELECT count(*) FROM page2),3::bigint,'second page continues after rank-session cap');
SELECT is((SELECT count(*) FROM page1 JOIN page2 USING(post_id)),0::bigint,'no duplicate pages');
SELECT is((SELECT count(*) FROM get_forum_continuation_page((SELECT ids FROM exclusions),'2026-09-01 00:00:00.123456+00',pg_temp.uid(161),20)),0::bigint,'empty terminal page means exhausted not artificial cap');
RESET ROLE;
UPDATE posts SET status='deleted' WHERE id=pg_temp.uid(170);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM get_forum_continuation_page((SELECT ids FROM exclusions),'2026-09-01 00:00:00.123456+00',pg_temp.uid(164),20)),3::bigint,'deleting earlier row does not skip later rows');
RESET ROLE;
INSERT INTO user_blocks(blocker_id,blocked_id) VALUES(pg_temp.uid(1),pg_temp.uid(2));
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM get_forum_continuation_page()),0::bigint,'blocked author excluded on continuation');
RESET ROLE;
SELECT set_config('request.jwt.claims','{}',true);
SELECT throws_ok('SELECT * FROM get_forum_continuation_page()','42501','Authentication required','unauthenticated call rejected');
SELECT * FROM finish();
ROLLBACK;
