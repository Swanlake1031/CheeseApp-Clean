BEGIN;

SELECT no_plan();

SELECT function_privs_are(
  'public',
  'publish_secondhand_post',
  ARRAY[
    'uuid', 'uuid', 'text', 'text', 'boolean', 'boolean', 'numeric',
    'text', 'text', 'boolean', 'timestamp with time zone'
  ],
  'anon',
  ARRAY[]::TEXT[],
  'anonymous clients cannot execute the Secondhand publish contract'
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
      '10500000-0000-4000-8000-000000000001'::UUID,
      '10500000-0000-4000-8000-000000000010'::UUID,
      'secondhand',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000010/10500000-0000-4000-8000-000000000001/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-secondhand-0.jpg",
          "order_index":0
        },
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000010/10500000-0000-4000-8000-000000000001/001.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-secondhand-1.jpg",
          "order_index":1
        },
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000010/10500000-0000-4000-8000-000000000001/002.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-secondhand-2.jpg",
          "order_index":2
        }
      ]'::JSONB
    )
  ),
  3::BIGINT,
  'Secondhand stages every exact object identity before upload'
);

SELECT public.mark_post_media_uploaded(
  '10500000-0000-4000-8000-000000000001'::UUID,
  upload_index
)
FROM generate_series(0, 2) AS upload_index;

SELECT is(
  public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000010'::UUID,
    '10500000-0000-4000-8000-000000000001'::UUID,
    'Transactional desk lamp',
    'Complete Secondhand listing',
    FALSE,
    FALSE,
    18.50,
    'furniture',
    'good',
    FALSE,
    '2030-01-31T23:59:59Z'::TIMESTAMPTZ
  ),
  '10500000-0000-4000-8000-000000000010'::UUID,
  'Secondhand publish returns the client-generated UUID'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts post
    JOIN public.secondhand_posts listing ON listing.id = post.id
    WHERE post.id = '10500000-0000-4000-8000-000000000010'::UUID
      AND post.user_id = '00000000-0000-0000-0000-000000000001'::UUID
      AND post.type = 'secondhand'
      AND post.status = 'active'
      AND listing.price = 18.50
      AND listing.category = 'home_appliances'
      AND listing.condition = 'good'
  ),
  1::BIGINT,
  'Secondhand base and detail rows commit as one complete active listing'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images image
    WHERE image.post_id = '10500000-0000-4000-8000-000000000010'::UUID
      AND image.bucket = 'post-images'
      AND image.object_path IS NOT NULL
  ),
  3::BIGINT,
  'all Secondhand image metadata retains exact Storage identities'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.secondhand_posts_view
    WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  1::BIGINT,
  'only the complete Secondhand listing is visible through its read contract'
);

SELECT is(
  (
    SELECT is_complete
    FROM public.get_secondhand_publish_status(
      '10500000-0000-4000-8000-000000000010'::UUID
    )
  ),
  TRUE,
  'Secondhand publication status requires base, detail, and required image metadata'
);

SELECT is(
  public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000010'::UUID,
    '10500000-0000-4000-8000-000000000001'::UUID,
    'Transactional desk lamp',
    'Complete Secondhand listing',
    FALSE,
    FALSE,
    18.50,
    'furniture',
    'good',
    FALSE,
    (
      SELECT expires_at
      FROM public.secondhand_posts
      WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
    )
  ),
  '10500000-0000-4000-8000-000000000010'::UUID,
  'repeating the identical Secondhand request is idempotent'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  1::BIGINT,
  'Secondhand idempotency creates exactly one base post'
);

SELECT throws_like(
  $$SELECT public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000010'::UUID,
    '10500000-0000-4000-8000-000000000001'::UUID,
    'Conflicting retry',
    'Complete Secondhand listing',
    FALSE,
    FALSE,
    18.50,
    'furniture',
    'good',
    FALSE,
    (
      SELECT expires_at
      FROM public.secondhand_posts
      WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
    )
  )$$,
  '%idempotency conflict%',
  'reusing a Secondhand publish UUID with changed content fails explicitly'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '10500000-0000-4000-8000-000000000002'::UUID,
      '10500000-0000-4000-8000-000000000020'::UUID,
      'secondhand',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000020/10500000-0000-4000-8000-000000000002/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-incomplete.jpg",
          "order_index":0
        }
      ]'::JSONB
    )
  ),
  1::BIGINT,
  'incomplete Secondhand publication fixture stages one image'
);

SELECT throws_like(
  $$SELECT public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000020'::UUID,
    '10500000-0000-4000-8000-000000000002'::UUID,
    'Incomplete listing',
    'Must remain invisible',
    FALSE,
    FALSE,
    10,
    'other',
    'fair',
    TRUE,
    '2030-01-31T23:59:59Z'::TIMESTAMPTZ
  )$$,
  '%media upload is incomplete%',
  'Secondhand finalization rejects an incomplete upload'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10500000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'incomplete Secondhand publication leaves no base post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.secondhand_posts_view
    WHERE id = '10500000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'incomplete Secondhand publication is not visible'
);

SELECT public.mark_post_media_uploaded(
  '10500000-0000-4000-8000-000000000002'::UUID,
  0
);

SELECT throws_like(
  $$SELECT public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000020'::UUID,
    '10500000-0000-4000-8000-000000000002'::UUID,
    'Invalid detail transaction',
    'Must roll back completely',
    FALSE,
    FALSE,
    10,
    'unsupported',
    'fair',
    TRUE,
    '2030-01-31T23:59:59Z'::TIMESTAMPTZ
  )$$,
  '%Unsupported Secondhand category%',
  'a Secondhand detail validation failure aborts publication'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10500000-0000-4000-8000-000000000020'::UUID
  ),
  0::BIGINT,
  'Secondhand detail failure leaves no base row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.abandon_post_media_operation(
      '10500000-0000-4000-8000-000000000002'::UUID,
      'publication_failed'
    )
  ),
  1::BIGINT,
  'failed Secondhand finalization creates an exact cleanup obligation'
);

SELECT public.mark_post_media_cleanup_attempt(
  (
    SELECT cleanup_id
    FROM public.get_my_post_media_cleanup_backlog(
      '10500000-0000-4000-8000-000000000020'::UUID
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
      '10500000-0000-4000-8000-000000000020'::UUID
    )
    LIMIT 1
  ),
  1,
  'Secondhand Storage deletion failure remains pending and observable'
);

-- Inject a post_images insert failure to prove base, detail, and partial
-- metadata all roll back together.
SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '10500000-0000-4000-8000-000000000003'::UUID,
      '10500000-0000-4000-8000-000000000030'::UUID,
      'secondhand',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000030/10500000-0000-4000-8000-000000000003/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-metadata-failure.jpg",
          "order_index":0
        }
      ]'::JSONB
    )
  ),
  1::BIGINT,
  'metadata failure fixture stages one image'
);

SELECT public.mark_post_media_uploaded(
  '10500000-0000-4000-8000-000000000003'::UUID,
  0
);

RESET ROLE;

CREATE FUNCTION public.test_105_fail_secondhand_image_metadata()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.post_id = '10500000-0000-4000-8000-000000000030'::UUID THEN
    RAISE EXCEPTION 'injected Secondhand image metadata failure';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_105_fail_secondhand_image_metadata
BEFORE INSERT ON public.post_images
FOR EACH ROW
EXECUTE FUNCTION public.test_105_fail_secondhand_image_metadata();

SET LOCAL ROLE authenticated;

SELECT throws_like(
  $$SELECT public.publish_secondhand_post(
    '10500000-0000-4000-8000-000000000030'::UUID,
    '10500000-0000-4000-8000-000000000003'::UUID,
    'Metadata failure listing',
    'Must roll back',
    FALSE,
    FALSE,
    12,
    'other',
    'good',
    FALSE,
    '2030-01-31T23:59:59Z'::TIMESTAMPTZ
  )$$,
  '%injected Secondhand image metadata failure%',
  'injected image metadata failure aborts Secondhand finalization'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10500000-0000-4000-8000-000000000030'::UUID
  ),
  0::BIGINT,
  'metadata failure rolls back the Secondhand base row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.secondhand_posts
    WHERE id = '10500000-0000-4000-8000-000000000030'::UUID
  ),
  0::BIGINT,
  'metadata failure rolls back the Secondhand detail row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10500000-0000-4000-8000-000000000030'::UUID
  ),
  0::BIGINT,
  'metadata failure leaves no finalized image rows'
);

RESET ROLE;
DROP TRIGGER test_105_fail_secondhand_image_metadata ON public.post_images;
DROP FUNCTION public.test_105_fail_secondhand_image_metadata();
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.abandon_post_media_operation(
      '10500000-0000-4000-8000-000000000003'::UUID,
      'metadata_failed'
    )
  ),
  1::BIGINT,
  'metadata failure retains the exact path for compensating cleanup'
);

-- Replace two images with one new image while retaining the original cover.
SELECT is(
  (
    SELECT COUNT(*)
    FROM public.prepare_post_media_operation(
      '10500000-0000-4000-8000-000000000004'::UUID,
      '10500000-0000-4000-8000-000000000010'::UUID,
      'secondhand',
      '[
        {
          "bucket":"post-images",
          "object_path":"00000000-0000-0000-0000-000000000001/posts/10500000-0000-4000-8000-000000000010/10500000-0000-4000-8000-000000000004/000.jpg",
          "url":"http://127.0.0.1:54321/storage/v1/object/public/post-images/105-secondhand-new.jpg",
          "order_index":0
        }
      ]'::JSONB
    )
  ),
  1::BIGINT,
  'Secondhand edit stages one replacement image'
);

SELECT public.mark_post_media_uploaded(
  '10500000-0000-4000-8000-000000000004'::UUID,
  0
);

SELECT lives_ok(
  format(
    $sql$
      SELECT public.update_secondhand_post_with_media(
        '10500000-0000-4000-8000-000000000010'::UUID,
        '10500000-0000-4000-8000-000000000004'::UUID,
        'Transactional desk lamp edited',
        'Edited description',
        FALSE,
        17,
        'like_new',
        TRUE,
        ARRAY[%L::UUID]
      )
    $sql$,
    (
      SELECT image.id::TEXT
      FROM public.post_images image
      WHERE image.post_id = '10500000-0000-4000-8000-000000000010'::UUID
      ORDER BY image.order_index
      LIMIT 1
    )
  ),
  'Secondhand edit atomically updates fields and image metadata'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  2::BIGINT,
  'Secondhand edit leaves one retained and one new image'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_media_cleanup_backlog
    WHERE post_id = '10500000-0000-4000-8000-000000000010'::UUID
      AND reason = 'secondhand_image_removed'
      AND status = 'pending'
  ),
  2::BIGINT,
  'each removed Secondhand image creates an exact retryable cleanup item'
);

SELECT lives_ok(
  format(
    $sql$
      SELECT public.update_secondhand_post_with_media(
        '10500000-0000-4000-8000-000000000010'::UUID,
        '10500000-0000-4000-8000-000000000004'::UUID,
        'Transactional desk lamp edited',
        'Edited description',
        FALSE,
        17,
        'like_new',
        TRUE,
        ARRAY[%L::UUID]
      )
    $sql$,
    (
      SELECT image.id::TEXT
      FROM public.post_images image
      WHERE image.post_id = '10500000-0000-4000-8000-000000000010'::UUID
        AND image.id NOT IN (
          SELECT stage.id
          FROM public.post_media_staging stage
          WHERE stage.operation_id = '10500000-0000-4000-8000-000000000004'::UUID
        )
      LIMIT 1
    )
  ),
  'repeating a Secondhand media edit is idempotent'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  2::BIGINT,
  'repeated Secondhand edit does not duplicate media metadata'
);

SELECT lives_ok(
  $$SELECT public.delete_secondhand_post_with_media(
    '10500000-0000-4000-8000-000000000010'::UUID
  )$$,
  'Secondhand deletion transaction completes'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Secondhand deletion removes the base row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.secondhand_posts
    WHERE id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Secondhand deletion cascades the detail row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id = '10500000-0000-4000-8000-000000000010'::UUID
  ),
  0::BIGINT,
  'Secondhand deletion removes database image metadata'
);

SELECT ok(
  (
    SELECT COUNT(*)
    FROM public.post_media_cleanup_backlog
    WHERE post_id = '10500000-0000-4000-8000-000000000010'::UUID
      AND bucket = 'post-images'
      AND object_path IS NOT NULL
  ) >= 4,
  'Secondhand deletion preserves every known cleanup obligation'
);

SELECT lives_ok(
  $$SELECT public.delete_secondhand_post_with_media(
    '10500000-0000-4000-8000-000000000010'::UUID
  )$$,
  'Secondhand deletion retry is idempotent while cleanup remains'
);

RESET ROLE;

-- A URL-only legacy listing must produce an explicit unresolved obligation,
-- never a guessed Storage path.
INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '10500000-0000-4000-8000-000000000040'::UUID,
  profile.id,
  profile.school_id,
  'secondhand',
  'Legacy Secondhand listing',
  'Legacy URL-only media',
  'active',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (
  id, price, is_negotiable, is_free, category, condition,
  can_ship, quantity, expires_at
)
VALUES (
  '10500000-0000-4000-8000-000000000040'::UUID,
  5, FALSE, FALSE, 'other', 'fair', FALSE, 1,
  '2030-01-31T23:59:59Z'::TIMESTAMPTZ
);

INSERT INTO public.post_images (id, post_id, url, order_index)
VALUES (
  '10500000-0000-4000-8000-000000000041'::UUID,
  '10500000-0000-4000-8000-000000000040'::UUID,
  'https://legacy.example.test/untrusted/object.jpg',
  0
);

SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$SELECT public.delete_secondhand_post_with_media(
    '10500000-0000-4000-8000-000000000040'::UUID
  )$$,
  'legacy Secondhand database deletion still completes'
);

SELECT is(
  (
    SELECT status
    FROM public.get_my_post_media_cleanup_backlog(
      '10500000-0000-4000-8000-000000000040'::UUID
    )
    LIMIT 1
  ),
  'unresolved',
  'legacy Secondhand cleanup is explicit and unresolved'
);

SELECT is(
  (
    SELECT object_path
    FROM public.get_my_post_media_cleanup_backlog(
      '10500000-0000-4000-8000-000000000040'::UUID
    )
    LIMIT 1
  ),
  NULL::TEXT,
  'legacy Secondhand cleanup never guesses an object path'
);

SELECT * FROM finish();

ROLLBACK;
