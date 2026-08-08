-- ============================================
-- 009_enable_all_rls.sql
-- Post-migration hardening
-- ============================================
--
-- 作用：
-- 1) 再次确保核心表启用 RLS（安全兜底）
-- 2) 为 public schema 的 plpgsql 函数固定 search_path
-- 3) 将关键视图改为 security_invoker，避免越权访问风险
-- 4) 刷新 PostgREST schema cache

-- 1) RLS safety net
ALTER TABLE IF EXISTS public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.post_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.rent_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.secondhand_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.ride_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.team_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.view_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.ride_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.messages ENABLE ROW LEVEL SECURITY;

-- 2) Fix mutable search_path for public plpgsql functions
DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_catalog.pg_get_function_identity_arguments(p.oid) AS function_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname = 'public'
      AND l.lanname = 'plpgsql'
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path = public, auth, extensions;',
      fn.schema_name,
      fn.function_name,
      fn.function_args
    );
  END LOOP;
END
$$;

-- 3) Force invoker rights on read views
ALTER VIEW IF EXISTS public.rent_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.secondhand_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.ride_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.team_posts_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.forum_posts_view SET (security_invoker = true);

-- 4) Refresh PostgREST cache
NOTIFY pgrst, 'reload schema';
