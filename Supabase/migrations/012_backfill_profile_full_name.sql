-- ============================================
-- 012_backfill_profile_full_name.sql
-- 回填历史用户 full_name，减少 *_posts_view 中 user_name 为 NULL 的情况
-- ============================================

UPDATE profiles
SET full_name = split_part(email, '@', 1),
    updated_at = NOW()
WHERE (full_name IS NULL OR btrim(full_name) = '')
  AND email IS NOT NULL
  AND btrim(email) <> '';

NOTIFY pgrst, 'reload schema';
