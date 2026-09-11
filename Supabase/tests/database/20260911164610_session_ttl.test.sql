-- Local only. All fixtures and default changes roll back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT plan(5);
SELECT is(pg_get_expr(d.adbin,d.adrelid), '(clock_timestamp() + ''00:15:00''::interval)',
 'authoritative new-session default is 15 minutes')
FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum
WHERE d.adrelid='public.feed_sessions'::regclass AND a.attname='expires_at';
SELECT is(md5(prosrc),'57371e8ce9c0c0d556736ac4886da953','resolver including strict expiry comparator is unchanged')
FROM pg_proc WHERE oid='public.resolve_home_forum_session()'::regprocedure;
INSERT INTO auth.users(id,email) VALUES('16461000-0000-4000-8000-000000000001','ttl@test.invalid');
ALTER TABLE public.feed_sessions ALTER COLUMN expires_at SET DEFAULT clock_timestamp()+interval '20 minutes';
CREATE TEMP TABLE old_session AS
WITH inserted AS (INSERT INTO feed_sessions(user_id) VALUES('16461000-0000-4000-8000-000000000001') RETURNING *)
SELECT * FROM inserted;
ALTER TABLE public.feed_sessions ALTER COLUMN expires_at SET DEFAULT clock_timestamp()+interval '15 minutes';
SELECT results_eq('SELECT * FROM feed_sessions WHERE id=(SELECT id FROM old_session)',
 'SELECT * FROM old_session','changing default leaves all existing stored session fields untouched');
SELECT ok((SELECT abs(extract(epoch FROM expires_at-created_at)-1200)<1 FROM old_session),
 'pre-change session retains its 20-minute lifetime');
WITH inserted AS (INSERT INTO feed_sessions(user_id) VALUES('16461000-0000-4000-8000-000000000001') RETURNING *)
SELECT ok(abs(extract(epoch FROM expires_at-created_at)-900)<1,'post-change session stores a 15-minute lifetime') FROM inserted;
SELECT * FROM finish();
ROLLBACK;
