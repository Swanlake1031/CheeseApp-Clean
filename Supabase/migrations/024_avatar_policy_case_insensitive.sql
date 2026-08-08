-- ============================================
-- 024_avatar_policy_case_insensitive.sql
-- Make avatar folder policy resilient to UUID letter case
-- Safe to run multiple times
-- ============================================

DROP POLICY IF EXISTS "Authenticated can upload own avatars" ON storage.objects;
CREATE POLICY "Authenticated can upload own avatars"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'avatars'
  AND lower((storage.foldername(name))[1]) = auth.uid()::text
);

DROP POLICY IF EXISTS "Users can update own avatars" ON storage.objects;
CREATE POLICY "Users can update own avatars"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'avatars'
  AND lower((storage.foldername(name))[1]) = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'avatars'
  AND lower((storage.foldername(name))[1]) = auth.uid()::text
);

DROP POLICY IF EXISTS "Users can delete own avatars" ON storage.objects;
CREATE POLICY "Users can delete own avatars"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'avatars'
  AND lower((storage.foldername(name))[1]) = auth.uid()::text
);

NOTIFY pgrst, 'reload schema';
