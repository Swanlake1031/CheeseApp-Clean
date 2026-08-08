BEGIN;

SELECT plan(4);

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
      '12100000-0000-4000-8000-000000000001'::UUID,
      '12100000-0000-4000-8000-000000000010'::UUID,
      'forum',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/12100000-0000-4000-8000-000000000010/12100000-0000-4000-8000-000000000001/000.jpg",
          "url":"https://example.invalid/000.jpg",
          "order_index":0
        },
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/12100000-0000-4000-8000-000000000010/12100000-0000-4000-8000-000000000001/001.jpg",
          "url":"https://example.invalid/001.jpg",
          "order_index":1
        }
      ]'::JSONB
    )
  ),
  2::BIGINT,
  'the initial media operation stages both selected images'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '12100000-0000-4000-8000-000000000001'::UUID,
      '12100000-0000-4000-8000-000000000010'::UUID,
      'forum',
      '[{
        "bucket":"post-images",
        "object_path":"00000000-0000-0000-0000-000000000001/posts/12100000-0000-4000-8000-000000000010/12100000-0000-4000-8000-000000000001/000.jpg",
        "url":"https://example.invalid/000.jpg",
        "order_index":0
      }]'::JSONB
    )
  ),
  1::BIGINT,
  'a retry can safely remove a previously staged image'
);

SELECT is(
  (
    SELECT staging.status
    FROM public.post_media_staging AS staging
    WHERE staging.operation_id = '12100000-0000-4000-8000-000000000001'::UUID
      AND staging.order_index = 1
  ),
  'cleanup_pending'::TEXT,
  'the removed staging row is marked for cleanup'
);

SELECT is(
  (
    SELECT cleanup.reason
    FROM public.post_media_cleanup_backlog AS cleanup
    JOIN public.post_media_staging AS staging
      ON staging.id = cleanup.source_staging_id
    WHERE staging.operation_id = '12100000-0000-4000-8000-000000000001'::UUID
      AND staging.order_index = 1
  ),
  'publish_selection_changed'::TEXT,
  'the removed object has an explicit cleanup obligation'
);

SELECT * FROM finish();
ROLLBACK;
