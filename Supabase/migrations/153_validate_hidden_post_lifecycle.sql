-- 153_validate_hidden_post_lifecycle.sql
--
-- Migration 152 installs these checks as NOT VALID before its post backfill.
-- Validate them in a separate transaction after all trigger events have
-- committed, so the database records that every historical row conforms.

BEGIN;

ALTER TABLE public.posts
  VALIDATE CONSTRAINT posts_hidden_reason_check;

ALTER TABLE public.posts
  VALIDATE CONSTRAINT posts_hidden_metadata_consistent_check;

COMMIT;
