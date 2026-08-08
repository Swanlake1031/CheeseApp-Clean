BEGIN;

SELECT plan(14);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.can_write_staged_post_media_object(text)',
    'EXECUTE'
  ),
  'anonymous clients cannot invoke the staged-object authorization helper'
);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '11200000-0000-4000-8000-000000000001'::UUID,
      '11200000-0000-4000-8000-000000000010'::UUID,
      'forum',
      '[{
        "bucket":"post-images",
        "object_path":"00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg",
        "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg",
        "order_index":0
      }]'::JSONB
    )
  ),
  1::BIGINT,
  'the feature RPC creates the exact staged identity before upload'
);

SELECT ok(
  public.can_write_staged_post_media_object(
    '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg'
  ),
  'the exact feature-owned staged object is writable'
);

SELECT ok(
  NOT public.can_write_staged_post_media_object(
    '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/001.jpg'
  ),
  'a same-prefix object without a staging row is denied'
);

SELECT ok(
  NOT public.can_write_staged_post_media_object(
    '00000000-0000-0000-0000-000000000001/random.jpg'
  ),
  'the legacy arbitrary post-images path is denied for new writes'
);

SELECT ok(
  NOT public.can_write_staged_post_media_object(
    '00000000-0000-0000-0000-000000000002/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg'
  ),
  'a different user namespace is denied'
);

SELECT ok(
  NOT public.can_write_staged_post_media_object(
    '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/006.jpg'
  ),
  'an out-of-contract image index is denied'
);

SELECT lives_ok(
  $$
    INSERT INTO storage.objects (bucket_id, name, owner)
    VALUES (
      'post-images',
      '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg',
      '00000000-0000-0000-0000-000000000001'
    )
  $$,
  'the Storage INSERT policy accepts the exact staged object'
);

SELECT throws_like(
  $$
    INSERT INTO storage.objects (bucket_id, name, owner)
    VALUES (
      'post-images',
      '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/001.jpg',
      '00000000-0000-0000-0000-000000000001'
    )
  $$,
  '%row-level security policy%',
  'the Storage INSERT policy rejects an untracked object'
);

SELECT lives_ok(
  $$
    UPDATE storage.objects
    SET metadata = '{"verified":true}'::JSONB
    WHERE bucket_id = 'post-images'
      AND name = '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg'
  $$,
  'owner overwrite remains allowed for the exact staged identity'
);

SELECT throws_like(
  $$
    UPDATE storage.objects
    SET name = '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/001.jpg'
    WHERE bucket_id = 'post-images'
      AND name = '00000000-0000-0000-0000-000000000001/posts/11200000-0000-4000-8000-000000000010/11200000-0000-4000-8000-000000000001/000.jpg'
  $$,
  '%row-level security policy%',
  'an owner cannot rename a staged object to an untracked identity'
);

RESET ROLE;

INSERT INTO storage.objects (bucket_id, name, owner)
VALUES (
  'post-images',
  '00000000-0000-0000-0000-000000000001/legacy-object.jpg',
  '00000000-0000-0000-0000-000000000001'
);

SET LOCAL ROLE authenticated;
SELECT set_config('storage.allow_delete_query', 'true', TRUE);

SELECT lives_ok(
  $$
    DELETE FROM storage.objects
    WHERE bucket_id = 'post-images'
      AND name = '00000000-0000-0000-0000-000000000001/legacy-object.jpg'
  $$,
  'owner-only deletion remains available for reconciled legacy cleanup'
);

RESET ROLE;

SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Owners can upload staged post images'
  ),
  1::BIGINT,
  'the staged post-image INSERT policy is installed'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated can upload post images'
  ),
  0::BIGINT,
  'the legacy unscoped post-image INSERT policy is removed'
);

SELECT * FROM finish();
ROLLBACK;
