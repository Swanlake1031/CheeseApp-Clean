-- New sessions only: improve personalization freshness while retaining stability.
-- Existing expires_at values, functions, ranking and lazy expiry are untouched.
-- Rollback requires a new migration restoring the default; never rewrite rows.
BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE public.feed_sessions IN ACCESS EXCLUSIVE MODE;
DO $$
DECLARE current_default text;
BEGIN
  SELECT pg_get_expr(d.adbin, d.adrelid) INTO current_default
  FROM pg_attrdef d JOIN pg_attribute a
    ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  WHERE d.adrelid = 'public.feed_sessions'::regclass AND a.attname = 'expires_at';
  IF current_default IS DISTINCT FROM '(clock_timestamp() + ''00:20:00''::interval)' THEN
    RAISE EXCEPTION 'Unexpected recommendation expiry default: %', current_default;
  END IF;
END;
$$;
ALTER TABLE public.feed_sessions ALTER COLUMN expires_at
  SET DEFAULT clock_timestamp() + INTERVAL '15 minutes';
COMMIT;
