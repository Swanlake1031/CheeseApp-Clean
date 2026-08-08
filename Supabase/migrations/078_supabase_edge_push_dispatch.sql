-- 078_supabase_edge_push_dispatch.sql
-- Route push delivery through a Supabase Edge Function instead of an external worker.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS public.push_dispatch_settings (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton = TRUE),
  function_url TEXT NOT NULL,
  dispatch_token TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.push_dispatch_settings DISABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_dispatch_settings FROM anon, authenticated;
GRANT SELECT, UPDATE ON public.push_dispatch_settings TO service_role;

CREATE OR REPLACE FUNCTION public.touch_push_dispatch_settings_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_push_dispatch_settings_updated_at ON public.push_dispatch_settings;
CREATE TRIGGER trg_push_dispatch_settings_updated_at
BEFORE UPDATE ON public.push_dispatch_settings
FOR EACH ROW
EXECUTE FUNCTION public.touch_push_dispatch_settings_updated_at();

INSERT INTO public.push_dispatch_settings (
  singleton,
  function_url,
  dispatch_token,
  enabled
)
VALUES (
  TRUE,
  'https://zeuivahkowbxmfzsnagt.supabase.co/functions/v1/push-dispatch',
  REPLACE(gen_random_uuid()::text, '-', '') || REPLACE(gen_random_uuid()::text, '-', ''),
  TRUE
)
ON CONFLICT (singleton) DO NOTHING;

CREATE OR REPLACE FUNCTION public.request_push_dispatch(
  p_reason TEXT DEFAULT 'enqueue',
  p_force BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url TEXT;
  v_token TEXT;
  v_request_id BIGINT;
BEGIN
  SELECT function_url, dispatch_token
    INTO v_url, v_token
  FROM public.push_dispatch_settings
  WHERE singleton = TRUE
    AND enabled = TRUE;

  IF NULLIF(BTRIM(COALESCE(v_url, '')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  IF NULLIF(BTRIM(COALESCE(v_token, '')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'reason', COALESCE(NULLIF(BTRIM(COALESCE(p_reason, '')), ''), 'enqueue'),
      'force', COALESCE(p_force, FALSE)
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-dispatch-token', v_token
    )
  )
  INTO v_request_id;

  RETURN v_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_push_dispatch(TEXT, BOOLEAN)
  TO service_role;

CREATE OR REPLACE FUNCTION public.request_push_dispatch_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.request_push_dispatch(TG_TABLE_NAME, FALSE);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_request_push_dispatch_after_messages ON public.messages;
CREATE TRIGGER trg_request_push_dispatch_after_messages
AFTER INSERT ON public.messages
FOR EACH STATEMENT
EXECUTE FUNCTION public.request_push_dispatch_after_insert();

DROP TRIGGER IF EXISTS trg_request_push_dispatch_after_group_messages ON public.group_messages;
CREATE TRIGGER trg_request_push_dispatch_after_group_messages
AFTER INSERT ON public.group_messages
FOR EACH STATEMENT
EXECUTE FUNCTION public.request_push_dispatch_after_insert();

DROP TRIGGER IF EXISTS trg_request_push_dispatch_after_comments ON public.comments;
CREATE TRIGGER trg_request_push_dispatch_after_comments
AFTER INSERT ON public.comments
FOR EACH STATEMENT
EXECUTE FUNCTION public.request_push_dispatch_after_insert();

DROP TRIGGER IF EXISTS trg_request_push_dispatch_after_likes ON public.likes;
CREATE TRIGGER trg_request_push_dispatch_after_likes
AFTER INSERT ON public.likes
FOR EACH STATEMENT
EXECUTE FUNCTION public.request_push_dispatch_after_insert();

DO $$
BEGIN
  IF to_regprocedure('cron.schedule(text,text,text)') IS NOT NULL THEN
    PERFORM cron.schedule(
      'dispatch-push-notification-retries',
      '* * * * *',
      $cron$
      SELECT public.request_push_dispatch('cron', TRUE);
      $cron$
    );
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
