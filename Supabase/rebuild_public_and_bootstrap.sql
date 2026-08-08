-- ============================================================================
-- PUBLIC SCHEMA RESET (DESTRUCTIVE)
--
-- Use this in a new/throwaway environment when schema is messy and you want a
-- clean rebuild from migration files.
-- ============================================================================

BEGIN;

-- 1) Drop and recreate public schema
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- 2) Restore standard Supabase/public grants
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT CREATE ON SCHEMA public TO postgres, service_role;

-- Keep default object privileges predictable for API roles
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

-- 3) Ensure extension required by migrations exists
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

COMMIT;

-- ============================================================================
-- NEXT STEP (manual)
-- Run every Supabase/migrations/*.sql file in filename order, through the
-- latest migration. Do not stop at an early file list copied from this script;
-- the live schema cleanup for retired modules is append-only and currently
-- lives in the latest numbered migration.
--
-- Optional: run Supabase/seed.sql for test data.
-- ============================================================================
