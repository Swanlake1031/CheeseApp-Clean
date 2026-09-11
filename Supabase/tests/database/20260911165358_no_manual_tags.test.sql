BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT plan(7);
INSERT INTO auth.users(id,email) VALUES('16535800-0000-4000-8000-000000000001','no-tags@test.invalid');
INSERT INTO posts(id,user_id,school_id,type,title,description,status,is_anonymous,is_private)
SELECT '16535800-0000-4000-8000-000000000002',id,school_id,'forum','Title only','','active',false,false
FROM profiles WHERE id='16535800-0000-4000-8000-000000000001';
INSERT INTO forum_posts(id,board_id,allow_comments)
VALUES('16535800-0000-4000-8000-000000000002',
 (SELECT id FROM forum_boards WHERE slug='casual-chat'),true);
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE before_input AS SELECT * FROM recommendation_embedding_input('16535800-0000-4000-8000-000000000002');
SELECT is((SELECT embedding_input FROM before_input),
 E'task: sentence similarity | query: Title: Title only\nBody: \nHashtags: ',
 'title-only post is valid with no manual tag in embedding input');
UPDATE forum_boards SET name='A completely different historic label' WHERE slug='casual-chat';
SELECT results_eq('SELECT * FROM recommendation_embedding_input(''16535800-0000-4000-8000-000000000002'')',
 'SELECT * FROM before_input','renaming a label changes neither vector input nor hash');
UPDATE forum_posts SET board_id=(SELECT id FROM forum_boards WHERE slug='questions')
WHERE id='16535800-0000-4000-8000-000000000002';
SELECT results_eq('SELECT * FROM recommendation_embedding_input(''16535800-0000-4000-8000-000000000002'')',
 'SELECT * FROM before_input','moving between active boards does not change semantic input');
SELECT is(md5(prosrc),'956bf92f2fbab03a50d7d8ed96c7b61f','ranker weights and softer ignore formula unchanged')
FROM pg_proc WHERE oid='public.rank_forum_recommendations_v1(uuid,uuid,integer)'::regprocedure;
SELECT is(md5(prosrc),'57371e8ce9c0c0d556736ac4886da953','session resolver unchanged')
FROM pg_proc WHERE oid='public.resolve_home_forum_session()'::regprocedure;
UPDATE posts SET title='Changed content' WHERE id='16535800-0000-4000-8000-000000000002';
SELECT isnt((SELECT input_hash FROM recommendation_embedding_input('16535800-0000-4000-8000-000000000002')),
 (SELECT input_hash FROM before_input),'actual title changes still regenerate semantic input');
SELECT ok(EXISTS(SELECT 1 FROM forum_boards WHERE name='A completely different historic label'),
 'historical label records are retained');
SELECT * FROM finish();
ROLLBACK;
