BEGIN;

SELECT plan(17);

-- The seed contains a conversation for the first profile pair with its own ID.
-- Replace only these test pairs inside this rolled-back transaction so every
-- object path below has a deterministic conversation scope.
DELETE FROM public.conversations
WHERE (user1_id, user2_id) IN (
  (
    '00000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID
  ),
  (
    '00000000-0000-0000-0000-000000000003'::UUID,
    '00000000-0000-0000-0000-000000000004'::UUID
  )
);

INSERT INTO public.conversations (id, user1_id, user2_id)
VALUES
  (
    '11100000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002'
  ),
  (
    '11100000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000004'
  )
ON CONFLICT DO NOTHING;

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '11100000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000001',
  'Private media test group'
)
ON CONFLICT DO NOTHING;

INSERT INTO public.chat_group_members (group_id, user_id, role)
VALUES
  (
    '11100000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000001',
    'owner'
  ),
  (
    '11100000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000002',
    'member'
  )
ON CONFLICT DO NOTHING;

INSERT INTO storage.objects (bucket_id, name, owner)
VALUES
  (
    'chat-images',
    'direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000001.jpg',
    '00000000-0000-0000-0000-000000000001'
  ),
  (
    'chat-images',
    'direct/11100000-0000-4000-8000-000000000002/00000000-0000-0000-0000-000000000003/11110000-0000-4000-8000-000000000002.jpg',
    '00000000-0000-0000-0000-000000000003'
  ),
  (
    'chat-images',
    'group/11100000-0000-4000-8000-000000000003/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000003.jpg',
    '00000000-0000-0000-0000-000000000001'
  );

SELECT is(
  (SELECT public FROM storage.buckets WHERE id = 'chat-images'),
  FALSE,
  'chat-images bucket is private'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.can_access_chat_media_object(text)', 'EXECUTE'),
  'anonymous role cannot invoke the authorization helper'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.can_access_chat_media_object('direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000001.jpg'),
  'direct chat participant can read its conversation object'
);
SELECT ok(
  public.can_write_chat_media_object('direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000004.jpg'),
  'direct chat participant can upload only under its uploader segment'
);
SELECT is(
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'chat-images'),
  2::BIGINT,
  'participant sees direct object and group object, not another conversation'
);
SELECT ok(
  NOT public.can_access_chat_media_object('direct/11100000-0000-4000-8000-000000000002/00000000-0000-0000-0000-000000000003/11110000-0000-4000-8000-000000000002.jpg'),
  'cross-conversation access is denied'
);
SELECT ok(
  public.can_access_chat_media_object('group/11100000-0000-4000-8000-000000000003/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000003.jpg'),
  'group member can read group object'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.can_access_chat_media_object('direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000001.jpg'),
  'the other direct chat participant can read the same object'
);
SELECT ok(
  NOT public.can_write_chat_media_object('direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000005.jpg'),
  'a participant cannot upload into the other participant uploader segment'
);

RESET ROLE;
DELETE FROM public.chat_group_members
WHERE group_id = '11100000-0000-4000-8000-000000000003'
  AND user_id = '00000000-0000-0000-0000-000000000002';
SET LOCAL ROLE authenticated;

SELECT ok(
  NOT public.can_access_chat_media_object('group/11100000-0000-4000-8000-000000000003/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000003.jpg'),
  'removed group member is denied'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', TRUE);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}', TRUE);
SET LOCAL ROLE authenticated;

SELECT ok(
  NOT public.can_access_chat_media_object('direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000001.jpg'),
  'direct chat non-participant is denied'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config('request.jwt.claim.role', 'anon', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
SET LOCAL ROLE anon;

SELECT is(
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'chat-images'),
  0::BIGINT,
  'anonymous role cannot read chat media objects'
);

RESET ROLE;

SELECT throws_ok(
  $$
    INSERT INTO public.messages (
      conversation_id, sender_id, content, message_type, metadata
    ) VALUES (
      '11100000-0000-4000-8000-000000000001',
      '00000000-0000-0000-0000-000000000001',
      'legacy public URL',
      'image',
      '{"image_url":"https://example.com/public.jpg"}'::JSONB
    )
  $$,
  '23514',
  NULL,
  'new direct image messages cannot store a public URL-only contract'
);

SELECT lives_ok(
  $$
    INSERT INTO public.messages (
      conversation_id, sender_id, content, message_type, metadata
    ) VALUES (
      '11100000-0000-4000-8000-000000000001',
      '00000000-0000-0000-0000-000000000001',
      'private image',
      'image',
      '{
        "image_bucket":"chat-images",
        "image_object_path":"direct/11100000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11110000-0000-4000-8000-000000000001.jpg",
        "image_scope":"direct",
        "image_scope_id":"11100000-0000-4000-8000-000000000001"
      }'::JSONB
    )
  $$,
  'new direct image metadata accepts the exact private locator'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Participants can read scoped chat images'
  ),
  1::BIGINT,
  'private read policy is installed'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Public can view chat images'
  ),
  0::BIGINT,
  'legacy public read policy is removed'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated can upload chat images'
  ),
  0::BIGINT,
  'legacy unscoped upload policy is removed'
);

SELECT * FROM finish();
ROLLBACK;
