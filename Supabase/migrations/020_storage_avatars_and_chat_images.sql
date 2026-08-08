-- ============================================
-- 020_storage_avatars_and_chat_images.sql
-- avatars / chat-images buckets and policies
-- ============================================

-- Ensure buckets exist and are public (app uses public URLs)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  (
    'avatars',
    'avatars',
    true,
    5242880, -- 5 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
  ),
  (
    'chat-images',
    'chat-images',
    true,
    10485760, -- 10 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
  )
ON CONFLICT (id) DO UPDATE
SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Public read for avatars
DROP POLICY IF EXISTS "Public can view avatars" ON storage.objects;
CREATE POLICY "Public can view avatars"
ON storage.objects
FOR SELECT
USING (bucket_id = 'avatars');

-- Authenticated users can upload only into their own folder: {uid}/...
DROP POLICY IF EXISTS "Authenticated can upload own avatars" ON storage.objects;
CREATE POLICY "Authenticated can upload own avatars"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users can update own avatars" ON storage.objects;
CREATE POLICY "Users can update own avatars"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users can delete own avatars" ON storage.objects;
CREATE POLICY "Users can delete own avatars"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Public read for chat images
DROP POLICY IF EXISTS "Public can view chat images" ON storage.objects;
CREATE POLICY "Public can view chat images"
ON storage.objects
FOR SELECT
USING (bucket_id = 'chat-images');

-- Authenticated users can upload chat images
DROP POLICY IF EXISTS "Authenticated can upload chat images" ON storage.objects;
CREATE POLICY "Authenticated can upload chat images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'chat-images');

DROP POLICY IF EXISTS "Users can update own chat images" ON storage.objects;
CREATE POLICY "Users can update own chat images"
ON storage.objects
FOR UPDATE
TO authenticated
USING (bucket_id = 'chat-images' AND owner = auth.uid())
WITH CHECK (bucket_id = 'chat-images' AND owner = auth.uid());

DROP POLICY IF EXISTS "Users can delete own chat images" ON storage.objects;
CREATE POLICY "Users can delete own chat images"
ON storage.objects
FOR DELETE
TO authenticated
USING (bucket_id = 'chat-images' AND owner = auth.uid());

NOTIFY pgrst, 'reload schema';
