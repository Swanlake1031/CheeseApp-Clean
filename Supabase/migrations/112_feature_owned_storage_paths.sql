-- Make the H2 post-media staging contract the server-side write boundary.
-- Public reads and owner deletes remain compatible with historical objects;
-- new inserts and overwrites require an exact feature-owned staged identity.

BEGIN;

CREATE OR REPLACE FUNCTION public.can_write_staged_post_media_object(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_parts TEXT[];
  v_me UUID := auth.uid();
  v_post_id UUID;
  v_operation_id UUID;
  v_order_index INTEGER;
BEGIN
  IF v_me IS NULL OR p_name IS NULL THEN
    RETURN FALSE;
  END IF;

  v_parts := string_to_array(p_name, '/');
  IF array_length(v_parts, 1) <> 5
     OR v_parts[1] <> LOWER(v_me::TEXT)
     OR v_parts[2] <> 'posts'
     OR v_parts[3] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_parts[4] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_parts[5] !~ '^00[0-5]\.jpg$'
  THEN
    RETURN FALSE;
  END IF;

  v_post_id := v_parts[3]::UUID;
  v_operation_id := v_parts[4]::UUID;
  v_order_index := LEFT(v_parts[5], 3)::INTEGER;

  RETURN EXISTS (
    SELECT 1
    FROM public.post_media_staging stage
    WHERE stage.owner_id = v_me
      AND stage.post_id = v_post_id
      AND stage.operation_id = v_operation_id
      AND stage.bucket = 'post-images'
      AND stage.object_path = p_name
      AND stage.order_index = v_order_index
      AND stage.status IN ('planned', 'uploaded', 'finalized')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.can_write_staged_post_media_object(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_write_staged_post_media_object(TEXT)
  TO authenticated, service_role;

DROP POLICY IF EXISTS "Authenticated can upload post images" ON storage.objects;
DROP POLICY IF EXISTS "Owners can upload staged post images" ON storage.objects;
CREATE POLICY "Owners can upload staged post images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'post-images'
  AND public.can_write_staged_post_media_object(name)
);

DROP POLICY IF EXISTS "Users can update own post images" ON storage.objects;
DROP POLICY IF EXISTS "Owners can update staged post images" ON storage.objects;
CREATE POLICY "Owners can update staged post images"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'post-images'
  AND owner = auth.uid()
  AND public.can_write_staged_post_media_object(name)
)
WITH CHECK (
  bucket_id = 'post-images'
  AND owner = auth.uid()
  AND public.can_write_staged_post_media_object(name)
);

-- Historical objects may not have an H2 staging row. Preserve exact owner-only
-- deletion so legacy reconciliation and cleanup can remove known objects.
DROP POLICY IF EXISTS "Users can delete own post images" ON storage.objects;
CREATE POLICY "Users can delete own post images"
ON storage.objects
FOR DELETE
TO authenticated
USING (bucket_id = 'post-images' AND owner = auth.uid());

COMMIT;

NOTIFY pgrst, 'reload schema';
