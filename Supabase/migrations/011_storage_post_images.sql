-- ============================================
-- 011_storage_post_images.sql
-- post-images bucket 與存取策略
-- ============================================

-- 建立（或更新）公開圖片桶
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'post-images',
  'post-images',
  true,
  10485760, -- 10 MB
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 允許公開讀取 post-images
DROP POLICY IF EXISTS "Public can view post images" ON storage.objects;
CREATE POLICY "Public can view post images"
ON storage.objects
FOR SELECT
USING (bucket_id = 'post-images');

-- 允許登入用戶上傳到 post-images
DROP POLICY IF EXISTS "Authenticated can upload post images" ON storage.objects;
CREATE POLICY "Authenticated can upload post images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'post-images');

-- 允許用戶更新自己的 post-images 物件
DROP POLICY IF EXISTS "Users can update own post images" ON storage.objects;
CREATE POLICY "Users can update own post images"
ON storage.objects
FOR UPDATE
TO authenticated
USING (bucket_id = 'post-images' AND owner = auth.uid())
WITH CHECK (bucket_id = 'post-images' AND owner = auth.uid());

-- 允許用戶刪除自己的 post-images 物件
DROP POLICY IF EXISTS "Users can delete own post images" ON storage.objects;
CREATE POLICY "Users can delete own post images"
ON storage.objects
FOR DELETE
TO authenticated
USING (bucket_id = 'post-images' AND owner = auth.uid());

NOTIFY pgrst, 'reload schema';
