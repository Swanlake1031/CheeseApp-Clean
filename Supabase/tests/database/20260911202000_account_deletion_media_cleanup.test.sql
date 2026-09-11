BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_temp;

SELECT plan(16);

INSERT INTO auth.users (id, email)
VALUES
  ('20202000-0000-4000-8000-000000000001', 'deletion-media-owner@example.invalid'),
  ('20202000-0000-4000-8000-000000000002', 'deletion-media-recipient@example.invalid');

INSERT INTO public.conversations (id, user1_id, user2_id)
VALUES (
  '20202000-0000-4000-8000-000000000003',
  '20202000-0000-4000-8000-000000000001',
  '20202000-0000-4000-8000-000000000002'
);

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '20202000-0000-4000-8000-000000000009',
  '20202000-0000-4000-8000-000000000002',
  'Account deletion fixture group'
);

INSERT INTO public.chat_group_members (group_id, user_id, role)
VALUES
  (
    '20202000-0000-4000-8000-000000000009',
    '20202000-0000-4000-8000-000000000002',
    'owner'
  ),
  (
    '20202000-0000-4000-8000-000000000009',
    '20202000-0000-4000-8000-000000000001',
    'member'
  );

INSERT INTO storage.objects (bucket_id, name, owner)
VALUES
  (
    'avatars',
    '20202000-0000-4000-8000-000000000001/covers/deletion-cover.jpg',
    '20202000-0000-4000-8000-000000000001'
  ),
  (
    'post-images',
    '20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg',
    '20202000-0000-4000-8000-000000000001'
  ),
  (
    'chat-images',
    'direct/20202000-0000-4000-8000-000000000003/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000006.jpg',
    '20202000-0000-4000-8000-000000000001'
  ),
  (
    'chat-images',
    'group/20202000-0000-4000-8000-000000000009/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000013.jpg',
    '20202000-0000-4000-8000-000000000001'
  ),
  (
    'content-studio-drafts',
    '20202000-0000-4000-8000-000000000001/drafts/20202000-0000-4000-8000-000000000018/20202000-0000-4000-8000-000000000019.jpg',
    NULL
  );

INSERT INTO public.moderated_media (bucket, object_path, user_id, sha256, model)
VALUES
  (
    'post-images',
    '20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg',
    '20202000-0000-4000-8000-000000000001',
    repeat('a', 64),
    'test'
  ),
  (
    'chat-images',
    'direct/20202000-0000-4000-8000-000000000003/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000006.jpg',
    '20202000-0000-4000-8000-000000000001',
    repeat('b', 64),
    'test'
  ),
  (
    'chat-images',
    'group/20202000-0000-4000-8000-000000000009/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000013.jpg',
    '20202000-0000-4000-8000-000000000001',
    repeat('c', 64),
    'test'
  );

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status, is_anonymous, is_private
)
SELECT
  '20202000-0000-4000-8000-000000000004',
  profile.id,
  profile.school_id,
  'forum',
  'Deletion media fixture',
  'A post whose stored image and copied cards must be erased with its account.',
  'active',
  FALSE,
  FALSE
FROM public.profiles AS profile
WHERE profile.id = '20202000-0000-4000-8000-000000000001';

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status, is_anonymous, is_private
)
SELECT
  '20202000-0000-4000-8000-000000000011',
  profile.id,
  profile.school_id,
  'forum',
  'Recipient post',
  'A surviving post that receives an account-deleted comment.',
  'active',
  FALSE,
  FALSE
FROM public.profiles AS profile
WHERE profile.id = '20202000-0000-4000-8000-000000000002';

INSERT INTO public.user_interest_profiles (user_id)
VALUES ('20202000-0000-4000-8000-000000000001');

INSERT INTO public.content_studio_drafts (
  id, user_id, content_type, title, payload
)
VALUES (
  '20202000-0000-4000-8000-000000000018',
  '20202000-0000-4000-8000-000000000001',
  'forum',
  'Deletion draft fixture',
  '{
    "media": [{
      "path":"20202000-0000-4000-8000-000000000001/drafts/20202000-0000-4000-8000-000000000018/20202000-0000-4000-8000-000000000019.jpg",
      "contentType":"image/jpeg",
      "size":1
    }]
  }'::jsonb
);

INSERT INTO public.post_images (post_id, url, order_index, bucket, object_path)
VALUES (
  '20202000-0000-4000-8000-000000000004',
  'https://zeuivahkowbxmfzsnagt.supabase.co/storage/v1/object/public/post-images/20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg',
  0,
  'post-images',
  '20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg'
);

INSERT INTO public.comments (
  id, post_id, user_id, parent_id, content, is_anonymous, like_count, is_deleted
)
VALUES (
  '20202000-0000-4000-8000-000000000012',
  '20202000-0000-4000-8000-000000000011',
  '20202000-0000-4000-8000-000000000001',
  NULL,
  'deletion comment original secret',
  FALSE,
  0,
  FALSE
);

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type, metadata, is_deleted
)
VALUES
  (
    '20202000-0000-4000-8000-000000000007',
    '20202000-0000-4000-8000-000000000003',
    '20202000-0000-4000-8000-000000000001',
    'account deletion photo',
    'image',
    '{
      "image_bucket":"chat-images",
      "image_object_path":"direct/20202000-0000-4000-8000-000000000003/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000006.jpg",
      "image_scope":"direct",
      "image_scope_id":"20202000-0000-4000-8000-000000000003"
    }'::jsonb,
    FALSE
  ),
  (
    '20202000-0000-4000-8000-000000000008',
    '20202000-0000-4000-8000-000000000003',
    '20202000-0000-4000-8000-000000000001',
    'direct message original secret',
    'text',
    '{}'::jsonb,
    FALSE
  ),
  (
    '20202000-0000-4000-8000-000000000015',
    '20202000-0000-4000-8000-000000000003',
    '20202000-0000-4000-8000-000000000002',
    'Shared a post',
    'text',
    '{
      "shared_post_card": {
        "post_id":"20202000-0000-4000-8000-000000000004",
        "post_kind":"forum",
        "title":"Deletion media fixture",
        "summary":"A copied post title and summary"
      }
    }'::jsonb,
    FALSE
  ),
  (
    '20202000-0000-4000-8000-000000000016',
    '20202000-0000-4000-8000-000000000003',
    '20202000-0000-4000-8000-000000000002',
    'I quoted the deleted message',
    'text',
    '{
      "quoted_message": {
        "message_id":"20202000-0000-4000-8000-000000000008",
        "sender_name":"Deletion owner",
        "preview":"direct message original secret",
        "message_type":"text"
      }
    }'::jsonb,
    FALSE
  );

INSERT INTO public.group_messages (
  id, group_id, sender_id, content, message_type, metadata, is_deleted
)
VALUES
  (
    '20202000-0000-4000-8000-000000000010',
    '20202000-0000-4000-8000-000000000009',
    '20202000-0000-4000-8000-000000000001',
    'account deletion group photo',
    'image',
    '{
      "image_bucket":"chat-images",
      "image_object_path":"group/20202000-0000-4000-8000-000000000009/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000013.jpg",
      "image_scope":"group",
      "image_scope_id":"20202000-0000-4000-8000-000000000009"
    }'::jsonb,
    FALSE
  ),
  (
    '20202000-0000-4000-8000-000000000014',
    '20202000-0000-4000-8000-000000000009',
    '20202000-0000-4000-8000-000000000001',
    'group message original secret',
    'text',
    '{}'::jsonb,
    FALSE
  );

UPDATE public.conversations
SET last_message_preview = 'direct message original secret'
WHERE id = '20202000-0000-4000-8000-000000000003';

INSERT INTO public.system_messages (
  recipient_user_id, event_id, kind, title, body, actor_user_id, post_id,
  comment_id, content_kind, cta_kind
)
VALUES (
  '20202000-0000-4000-8000-000000000002',
  'deletion-comment-copy',
  'post_comment',
  'A comment copied into notification storage',
  'deletion comment original secret',
  '20202000-0000-4000-8000-000000000001',
  '20202000-0000-4000-8000-000000000011',
  '20202000-0000-4000-8000-000000000012',
  'comment',
  'view_post'
);

INSERT INTO public.push_notification_jobs (
  recipient_user_id, kind, title, body, payload, source_type, source_key
)
VALUES (
  '20202000-0000-4000-8000-000000000002',
  'direct_message',
  'Deletion owner',
  'direct message original secret',
  '{
    "sender_id":"20202000-0000-4000-8000-000000000001",
    "message_id":"20202000-0000-4000-8000-000000000008"
  }'::jsonb,
  'messages',
  '20202000-0000-4000-8000-000000000008'
);

SELECT set_config(
  'request.jwt.claim.sub',
  '20202000-0000-4000-8000-000000000001',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"20202000-0000-4000-8000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.deactivate_my_account(),
  'account deletion completes while media deletion jobs are prepared'
);

RESET ROLE;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.messages
    WHERE sender_id = '20202000-0000-4000-8000-000000000001'
      AND (
        content IS DISTINCT FROM '[Deleted account content]'
        OR message_type IS DISTINCT FROM 'text'
        OR metadata IS DISTINCT FROM '{}'::jsonb
        OR COALESCE(is_deleted, FALSE) = FALSE
      )
  ),
  0::bigint,
  'direct-message text, photo metadata, and delivery rows are reduced to content-free tombstones'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.group_messages
    WHERE sender_id = '20202000-0000-4000-8000-000000000001'
      AND (
        content IS DISTINCT FROM '[Deleted account content]'
        OR message_type IS DISTINCT FROM 'text'
        OR metadata IS DISTINCT FROM '{}'::jsonb
        OR COALESCE(is_deleted, FALSE) = FALSE
      )
  ),
  0::bigint,
  'group-message text and photo metadata are reduced to content-free tombstones'
);

SELECT ok(
  (
    SELECT content = '[Deleted account content]'
       AND is_deleted
       AND metadata = '{}'::jsonb
    FROM public.messages
    WHERE id = '20202000-0000-4000-8000-000000000015'
  )
  AND (
    SELECT content = 'I quoted the deleted message'
       AND COALESCE(is_deleted, FALSE) = FALSE
       AND metadata = '{}'::jsonb
    FROM public.messages
    WHERE id = '20202000-0000-4000-8000-000000000016'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.conversations
    WHERE id = '20202000-0000-4000-8000-000000000003'
      AND last_message_preview = 'direct message original secret'
  ),
  'shared-card, quoted-preview, and conversation-preview copies do not retain deleted-account content'
);

SELECT ok(
  (
    SELECT content = '[Deleted account content]'
       AND is_deleted
       AND is_anonymous
       AND author_is_deactivated
    FROM public.comments
    WHERE id = '20202000-0000-4000-8000-000000000012'
  ),
  'an authored comment on another user post keeps only a de-identified content-free thread tombstone'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.system_messages
    WHERE body = 'deletion comment original secret'
       OR actor_user_id = '20202000-0000-4000-8000-000000000001'
       OR comment_id = '20202000-0000-4000-8000-000000000012'
  ),
  0::bigint,
  'in-app notification copies of deleted user content are removed'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.push_notification_jobs
    WHERE body = 'direct message original secret'
       OR payload ->> 'sender_id' = '20202000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'queued push copies of deleted user content are removed'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.moderated_media
    WHERE user_id = '20202000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'media-review receipts are erased with the account'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '20202000-0000-4000-8000-000000000004'
  ),
  0::bigint,
  'the post and its database image reference are removed with the account'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.user_interest_profiles
    WHERE user_id = '20202000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'account-linked recommendation vectors are erased with the account'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.content_studio_drafts
    WHERE user_id = '20202000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'content-studio draft content is erased with the account'
);

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

CREATE TEMP TABLE claimed_account_cleanup AS
SELECT *
FROM public.claim_account_media_cleanup_batch(
  50,
  '20202000-0000-4000-8000-000000000017'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM claimed_account_cleanup
    WHERE bucket IN ('avatars', 'post-images', 'chat-images', 'content-studio-drafts')
      AND object_path IN (
        '20202000-0000-4000-8000-000000000001/covers/deletion-cover.jpg',
        '20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg',
        'direct/20202000-0000-4000-8000-000000000003/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000006.jpg',
        'group/20202000-0000-4000-8000-000000000009/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000013.jpg',
        '20202000-0000-4000-8000-000000000001/drafts/20202000-0000-4000-8000-000000000018/20202000-0000-4000-8000-000000000019.jpg'
      )
  ),
  5::bigint,
  'the worker can claim avatar, post, direct-chat, group-chat, and draft objects belonging to the deleted account'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM claimed_account_cleanup
    WHERE bucket = 'post-images'
      AND object_path = '20202000-0000-4000-8000-000000000001/posts/20202000-0000-4000-8000-000000000004/20202000-0000-4000-8000-000000000005/000.jpg'
  ),
  'post-image cleanup uses its exact feature-owned object path'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM claimed_account_cleanup
    WHERE bucket = 'chat-images'
      AND object_path = 'direct/20202000-0000-4000-8000-000000000003/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000006.jpg'
  ),
  'direct-chat cleanup uses its exact feature-owned object path'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM claimed_account_cleanup
    WHERE bucket = 'chat-images'
      AND object_path = 'group/20202000-0000-4000-8000-000000000009/20202000-0000-4000-8000-000000000001/20202000-0000-4000-8000-000000000013.jpg'
  ),
  'group-chat cleanup uses its exact feature-owned object path'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM claimed_account_cleanup
    WHERE bucket = 'content-studio-drafts'
      AND object_path = '20202000-0000-4000-8000-000000000001/drafts/20202000-0000-4000-8000-000000000018/20202000-0000-4000-8000-000000000019.jpg'
  ),
  'draft cleanup uses the exact feature-owned object path even without Storage owner metadata'
);

SELECT * FROM finish();

ROLLBACK;
