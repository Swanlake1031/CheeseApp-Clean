BEGIN;

SELECT no_plan();

SELECT has_column(
  'public',
  'post_images',
  'bucket',
  'post_images persists the exact Storage bucket'
);

SELECT has_column(
  'public',
  'post_images',
  'object_path',
  'post_images persists the exact Storage object path'
);

SELECT col_is_null(
  'public',
  'post_images',
  'bucket',
  'legacy post image bucket remains nullable during compatibility rollout'
);

SELECT col_is_null(
  'public',
  'post_images',
  'object_path',
  'legacy post image path remains nullable during compatibility rollout'
);

SELECT function_privs_are(
  'public',
  'publish_forum_post',
  ARRAY['uuid', 'uuid', 'uuid', 'text', 'text', 'boolean', 'boolean', 'boolean'],
  'anon',
  ARRAY[]::TEXT[],
  'anonymous clients cannot execute the Forum publish contract'
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
      '10400000-0000-4000-8000-000000000001'::UUID,
      '10400000-0000-4000-8000-000000000010'::UUID,
      'forum',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/000.jpg",
          "order_index":0
        },
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/001.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/001.jpg",
          "order_index":1
        },
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/002.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000001/002.jpg",
          "order_index":2
        }
      ]'::JSONB
    )
  ),
  3::BIGINT,
  'Forum media staging records every planned object before upload'
);

SELECT public.mark_post_media_uploaded(
  '10400000-0000-4000-8000-000000000001'::UUID,
  upload_index
)
FROM generate_series(0, 2) AS upload_index;

SELECT is(
  public.publish_forum_post(
    '10400000-0000-4000-8000-000000000010'::UUID,
    '10400000-0000-4000-8000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID,
    'Transactional Forum post',
    'Complete Forum body',
    FALSE,
    FALSE,
    TRUE
  ),
  '10400000-0000-4000-8000-000000000010'::UUID,
  'Forum publish returns the caller-generated post UUID'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts post
    JOIN public.forum_posts forum ON forum.id = post.id
    WHERE post.id = '10400000-0000-4000-8000-000000000010'::UUID
      AND post.user_id = '00000000-0000-0000-0000-000000000001'::UUID
      AND post.status = 'active'
  ),
  1::BIGINT,
  'Forum base and detail rows commit together as one visible post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images image
    WHERE image.post_id = '10400000-0000-4000-8000-000000000010'::UUID
      AND image.bucket = 'post-images'
      AND image.object_path IS NOT NULL
  ),
  3::BIGINT,
  'all finalized Forum metadata contains exact Storage identities'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  1::BIGINT,
  'the complete post is visible through the Forum read contract'
);

SELECT is(
  public.publish_forum_post(
    '10400000-0000-4000-8000-000000000010'::UUID,
    '10400000-0000-4000-8000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID,
    'Transactional Forum post',
    'Complete Forum body',
    FALSE,
    FALSE,
    TRUE
  ),
  '10400000-0000-4000-8000-000000000010'::UUID,
  'repeating the same publish request is idempotent'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  1::BIGINT,
  'idempotent retry does not create a duplicate base post'
);

SELECT throws_like(
  $$SELECT public.publish_forum_post(
    '10400000-0000-4000-8000-000000000010'::UUID,
    '10400000-0000-4000-8000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID,
    'Conflicting retry title',
    'Complete Forum body',
    FALSE,
    FALSE,
    TRUE
  )$$,
  '%idempotency conflict%',
  'reusing a publish UUID with different content fails explicitly'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '10400000-0000-4000-8000-000000000002'::UUID,
      '10400000-0000-4000-8000-000000000020'::UUID,
      'forum',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000020/10400000-0000-4000-8000-000000000002/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000020/10400000-0000-4000-8000-000000000002/000.jpg",
          "order_index":0
        }
      ]'::JSONB
    )
  ),
  1::BIGINT,
  'incomplete publication fixture stages one image'
);

SELECT throws_like(
  $$SELECT public.publish_forum_post(
    '10400000-0000-4000-8000-000000000020'::UUID,
    '10400000-0000-4000-8000-000000000002'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID,
    'Incomplete upload',
    'Must remain invisible',
    FALSE,
    FALSE,
    TRUE
  )$$,
  '%media upload is incomplete%',
  'publication finalization rejects an incomplete upload'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10400000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'incomplete publication creates no base post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '10400000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'incomplete publication is never publicly visible'
);

SELECT public.mark_post_media_uploaded(
  '10400000-0000-4000-8000-000000000002'::UUID,
  0
);

SELECT throws_like(
  $$SELECT public.publish_forum_post(
    '10400000-0000-4000-8000-000000000020'::UUID,
    '10400000-0000-4000-8000-000000000002'::UUID,
    'f0000000-0000-0000-0000-000000000099'::UUID,
    'Invalid board transaction',
    'Must roll back base and media metadata',
    FALSE,
    FALSE,
    TRUE
  )$$,
  '%active Forum board%',
  'a Forum detail failure aborts the transactional publication'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10400000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'detail failure rolls back the base post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10400000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'detail failure leaves no final image metadata'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.abandon_post_media_operation(
      '10400000-0000-4000-8000-000000000002'::UUID,
      'publication_failed'
    )
  ),
  1::BIGINT,
  'failed finalization creates an observable exact-path cleanup obligation'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_post_media_cleanup_backlog(
      '10400000-0000-4000-8000-000000000020'::UUID
    )
    WHERE status = 'pending'
      AND bucket = 'post-images'
      AND object_path IS NOT NULL
  ),
  1::BIGINT,
  'known failed-publication media is retryable from the cleanup backlog'
);

SELECT public.mark_post_media_cleanup_attempt(
  (
    SELECT cleanup_id
    FROM public.get_my_post_media_cleanup_backlog(
      '10400000-0000-4000-8000-000000000020'::UUID
    )
    LIMIT 1
  ),
  FALSE,
  'storage.timeout'
);

SELECT is(
  (
    SELECT attempt_count
    FROM public.get_my_post_media_cleanup_backlog(
      '10400000-0000-4000-8000-000000000020'::UUID
    )
    LIMIT 1
  ),
  1,
  'transient Storage deletion failure remains pending and increments attempts'
);

-- Prepare one new image for an edit, retain the first original image, and
-- remove the other two.
SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '10400000-0000-4000-8000-000000000003'::UUID,
      '10400000-0000-4000-8000-000000000010'::UUID,
      'forum',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000003/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/00000000-0000-0000-0000-000000000001/posts/10400000-0000-4000-8000-000000000010/10400000-0000-4000-8000-000000000003/000.jpg",
          "order_index":0
        }
      ]'::JSONB
    )
  ),
  1::BIGINT,
  'Forum edit stages its replacement image independently'
);

SELECT public.mark_post_media_uploaded(
  '10400000-0000-4000-8000-000000000003'::UUID,
  0
);

SELECT lives_ok(
  format(
    $sql$
      SELECT public.update_forum_post_with_media(
        '10400000-0000-4000-8000-000000000010'::UUID,
        '10400000-0000-4000-8000-000000000003'::UUID,
        'f0000000-0000-0000-0000-000000000002'::UUID,
        'Transactional Forum post edited',
        'Complete Forum body edited',
        FALSE,
        FALSE,
        TRUE,
        ARRAY[%L::UUID]
      )
    $sql$,
    (
      SELECT image.id::TEXT
      FROM public.post_images image
      WHERE image.post_id = '10400000-0000-4000-8000-000000000010'::UUID
      ORDER BY image.order_index
      LIMIT 1
    )
  ),
  'Forum edit atomically retains, removes, and adds image metadata'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  2::BIGINT,
  'Forum replacement leaves one retained and one new image'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_media_cleanup_backlog
    WHERE post_id = '10400000-0000-4000-8000-000000000010'::UUID
      AND reason = 'forum_image_removed'
      AND status = 'pending'
  ),
  2::BIGINT,
  'removed Forum images each create an exact-path cleanup obligation'
);

SELECT lives_ok(
  format(
    $sql$
      SELECT public.update_forum_post_with_media(
        '10400000-0000-4000-8000-000000000010'::UUID,
        '10400000-0000-4000-8000-000000000003'::UUID,
        'f0000000-0000-0000-0000-000000000002'::UUID,
        'Transactional Forum post edited',
        'Complete Forum body edited',
        FALSE,
        FALSE,
        TRUE,
        ARRAY[%L::UUID]
      )
    $sql$,
    (
      SELECT image.id::TEXT
      FROM public.post_images image
      WHERE image.post_id = '10400000-0000-4000-8000-000000000010'::UUID
        AND image.id NOT IN (
          SELECT stage.id
          FROM public.post_media_staging stage
          WHERE stage.operation_id = '10400000-0000-4000-8000-000000000003'::UUID
        )
      LIMIT 1
    )
  ),
  'repeating a Forum media edit operation is idempotent'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  2::BIGINT,
  'repeated Forum edit does not duplicate image metadata'
);

SELECT lives_ok(
  $$SELECT public.delete_forum_post_with_media(
    '10400000-0000-4000-8000-000000000010'::UUID
  )$$,
  'Forum deletion transaction completes'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Forum deletion removes the base post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts
    WHERE id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Forum deletion cascades the detail row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10400000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Forum deletion removes image metadata'
);

SELECT ok(
  (
    SELECT COUNT(*)
    FROM public.post_media_cleanup_backlog
    WHERE post_id = '10400000-0000-4000-8000-000000000010'::UUID
      AND bucket = 'post-images'
      AND object_path IS NOT NULL
  ) >= 4,
  'Forum deletion keeps all removed/deleted known paths observable'
);

SELECT lives_ok(
  $$SELECT public.delete_forum_post_with_media(
    '10400000-0000-4000-8000-000000000010'::UUID
  )$$,
  'Forum deletion retry is idempotent while cleanup remains'
);

RESET ROLE;

-- Create a URL-only legacy Forum image as the migration owner. It deliberately
-- remains unresolved and must never produce a guessed object path.
INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '10400000-0000-4000-8000-000000000030'::UUID,
  profile.id,
  profile.school_id,
  'forum',
  'Legacy media Forum post',
  'Legacy media body',
  'active',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments)
VALUES (
  '10400000-0000-4000-8000-000000000030'::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  TRUE
);

INSERT INTO public.post_images (id, post_id, url, order_index)
VALUES (
  '10400000-0000-4000-8000-000000000031'::UUID,
  '10400000-0000-4000-8000-000000000030'::UUID,
  'https://storage.invalid/do-not-parse/legacy.jpg',
  0
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

SELECT lives_ok(
  $$SELECT public.delete_forum_post_with_media(
    '10400000-0000-4000-8000-000000000030'::UUID
  )$$,
  'legacy Forum database content can be deleted without guessing a path'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_post_media_cleanup_backlog(
      '10400000-0000-4000-8000-000000000030'::UUID
    )
    WHERE post_image_id = '10400000-0000-4000-8000-000000000031'::UUID
      AND status = 'unresolved'
      AND bucket IS NULL
      AND object_path IS NULL
      AND reason = 'legacy_object_path_unresolved'
      AND candidate_count = 0
  ),
  1::BIGINT,
  'unresolved legacy cleanup remains explicit and contains no guessed path'
);

SELECT throws_like(
  $$SELECT * FROM public.prepare_post_media_operation(
    '10400000-0000-4000-8000-000000000099'::UUID,
    '10400000-0000-4000-8000-000000000098'::UUID,
    'forum',
    '[
      {
        "bucket":"post-images",
        "object_path":"00000000-0000-0000-0000-000000000002/posts/10400000-0000-4000-8000-000000000098/10400000-0000-4000-8000-000000000099/000.jpg",
        "url":"https://storage.invalid/other-user.jpg",
        "order_index":0
      }
    ]'::JSONB
  )$$,
  '%outside the authenticated operation prefix%',
  'an authenticated user cannot stage media under another user path'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
