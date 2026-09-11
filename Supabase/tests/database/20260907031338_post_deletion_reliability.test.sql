BEGIN;
SET LOCAL statement_timeout = '8s';
SELECT plan(8);

SELECT is((SELECT count(*) FROM pg_indexes WHERE schemaname = 'public'
  AND indexname IN ('view_history_post_id_idx', 'system_messages_post_id_idx',
    'content_mentions_post_id_idx', 'cheese_ai_interactions_post_id_idx')),
  4::BIGINT, 'post deletion dependencies have lookup indexes');

CREATE TEMP TABLE deletion_fixture ON COMMIT DROP AS
SELECT gen_random_uuid() AS post_id, user_id AS owner_id, school_id
FROM public.posts LIMIT 1;

INSERT INTO public.posts(id, user_id, school_id, type, title, is_private)
SELECT post_id, owner_id, school_id, 'secondhand', 'Deletion regression fixture', TRUE
FROM deletion_fixture;
INSERT INTO public.secondhand_posts(id, price, category, condition)
SELECT post_id, 10, 'daily_essentials', 'good' FROM deletion_fixture;
INSERT INTO public.post_images(post_id, url, bucket, object_path, order_index)
SELECT post_id, 'https://example.invalid/deletion-test.jpg', 'post-images',
  owner_id || '/posts/' || post_id || '/deletion-test.jpg', 0 FROM deletion_fixture;

SELECT set_config('request.jwt.claim.sub', gen_random_uuid()::TEXT, TRUE);
SELECT throws_ok(format('SELECT public.delete_secondhand_post_with_media(%L::uuid)',
  (SELECT post_id FROM deletion_fixture)), '42501',
  'Secondhand post not found or not deletable', 'another user cannot delete the fixture');
SELECT is((SELECT count(*) FROM public.posts WHERE id = (SELECT post_id FROM deletion_fixture)),
  1::BIGINT, 'unauthorized attempt preserves the post');

SELECT set_config('request.jwt.claim.sub', (SELECT owner_id::TEXT FROM deletion_fixture), TRUE);
SELECT lives_ok(format('SELECT public.delete_secondhand_post_with_media(%L::uuid)',
  (SELECT post_id FROM deletion_fixture)), 'owner deletion completes within statement budget');
SELECT is((SELECT count(*) FROM public.posts WHERE id = (SELECT post_id FROM deletion_fixture)),
  0::BIGINT, 'owner deletion removes the post');
SELECT is((SELECT count(*) FROM public.post_images WHERE post_id = (SELECT post_id FROM deletion_fixture)),
  0::BIGINT, 'image metadata cascades with deletion');
SELECT is((SELECT count(*) FROM public.post_media_cleanup_backlog
  WHERE post_id = (SELECT post_id FROM deletion_fixture) AND status = 'pending'),
  1::BIGINT, 'exact media cleanup obligation survives deletion');
SELECT lives_ok(format('SELECT public.delete_secondhand_post_with_media(%L::uuid)',
  (SELECT post_id FROM deletion_fixture)), 'repeating completed deletion is safe');

SELECT * FROM finish();
ROLLBACK;
