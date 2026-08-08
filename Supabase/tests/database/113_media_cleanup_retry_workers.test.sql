BEGIN;

SELECT plan(26);

SELECT has_table(
  'public',
  'chat_media_cleanup_backlog',
  'chat cleanup obligations are stored durably'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.claim_chat_media_cleanup_batch(integer,uuid)',
    'EXECUTE'
  ),
  'authenticated clients cannot lease worker cleanup jobs'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.prepare_chat_media_cleanup(text,uuid,text,text)',
    'EXECUTE'
  ),
  'anonymous clients cannot prepare Chat cleanup obligations'
);

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
    '11300000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002'
  ),
  (
    '11300000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000004'
  );

INSERT INTO public.chat_groups (id, owner_id, name)
VALUES (
  '11300000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000001',
  'Cleanup retry test group'
);

INSERT INTO public.chat_group_members (group_id, user_id, role)
VALUES
  (
    '11300000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000001',
    'owner'
  ),
  (
    '11300000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000002',
    'member'
  );

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.prepare_chat_media_cleanup(
    'direct',
    '11300000-0000-4000-8000-000000000001',
    'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000001.jpg'
  ) IS NOT NULL,
  'a direct participant reserves the exact object before upload'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.get_my_chat_media_cleanup_backlog()
    WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000001.jpg'
      AND status = 'pending'
      AND reason = 'upload_reserved'
      AND next_attempt_at > NOW()
  ),
  'the upload reservation is observable and has a grace period'
);

SELECT throws_ok(
  $$
    SELECT public.prepare_chat_media_cleanup(
      'direct',
      '11300000-0000-4000-8000-000000000002'::UUID,
      'direct/11300000-0000-4000-8000-000000000002/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000002.jpg'
    )
  $$,
  '42501',
  NULL,
  'a non-participant cannot reserve media in another conversation'
);

SELECT lives_ok(
  $$
    SELECT public.mark_chat_media_cleanup_attempt(
      (
        SELECT id FROM public.chat_media_cleanup_backlog
        WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000001.jpg'
      ),
      FALSE,
      'storage_delete:-1009'
    )
  $$,
  'an app-side deletion failure is recorded without being swallowed'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.get_my_chat_media_cleanup_backlog()
    WHERE attempt_count = 1
      AND status = 'pending'
      AND last_error_code = 'storage_delete:-1009'
      AND next_attempt_at > NOW()
  ),
  'a transient failure remains pending with backoff and a safe error code'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT COUNT(*) FROM public.get_my_chat_media_cleanup_backlog()),
  0::BIGINT,
  'another account cannot read the first account cleanup backlog'
);

SELECT throws_ok(
  $$
    SELECT public.resolve_chat_media_cleanup(
      (
        SELECT id FROM public.chat_media_cleanup_backlog
        WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000001.jpg'
      )
    )
  $$,
  'P0002',
  NULL,
  'another account cannot resolve the first account obligation'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$
    SELECT public.resolve_chat_media_cleanup(
      (
        SELECT id FROM public.chat_media_cleanup_backlog
        WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000001.jpg'
      )
    )
  $$,
  'the owner can acknowledge media retained by a sent message'
);

SELECT ok(
  public.prepare_chat_media_cleanup(
    'direct',
    '11300000-0000-4000-8000-000000000001',
    'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
  ) IS NOT NULL,
  'a second exact direct upload reservation is created'
);

RESET ROLE;

INSERT INTO public.messages (
  id, conversation_id, sender_id, content, message_type, metadata, is_deleted
)
VALUES (
  '11320000-0000-4000-8000-000000000001',
  '11300000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'private direct image',
  'image',
  '{
    "image_bucket":"chat-images",
    "image_object_path":"direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg",
    "image_scope":"direct",
    "image_scope_id":"11300000-0000-4000-8000-000000000001"
  }'::JSONB,
  FALSE
);

UPDATE public.chat_media_cleanup_backlog
SET next_attempt_at = NOW() - INTERVAL '1 minute'
WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg';

SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_chat_media_cleanup_batch(
      20,
      '11330000-0000-4000-8000-000000000001'
    )
  ),
  0::BIGINT,
  'the worker never deletes a stale reservation referenced by an active message'
);

RESET ROLE;

SELECT is(
  (
    SELECT status || ':' || resolution
    FROM public.chat_media_cleanup_backlog
    WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
  ),
  'resolved:retained_by_message',
  'the active message check resolves the stale upload obligation'
);

UPDATE public.messages
SET is_deleted = TRUE
WHERE id = '11320000-0000-4000-8000-000000000001';

SELECT is(
  (
    SELECT status || ':' || reason
    FROM public.chat_media_cleanup_backlog
    WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
  ),
  'pending:message_deleted',
  'soft deletion reopens an exact cleanup obligation'
);

SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_chat_media_cleanup_batch(
      20,
      '11330000-0000-4000-8000-000000000002'
    )
  ),
  1::BIGINT,
  'the worker leases the due Chat cleanup exactly once'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_chat_media_cleanup_batch(
      20,
      '11330000-0000-4000-8000-000000000003'
    )
  ),
  0::BIGINT,
  'an active lease cannot be claimed by another worker'
);

SELECT lives_ok(
  $$
    SELECT public.complete_chat_media_cleanup_job(
      (
        SELECT id FROM public.chat_media_cleanup_backlog
        WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
      ),
      '11330000-0000-4000-8000-000000000002'::UUID,
      FALSE,
      'storage_http_503'
    )
  $$,
  'the worker records a transient Storage deletion failure'
);

RESET ROLE;

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.chat_media_cleanup_backlog
    WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
      AND status = 'pending'
      AND attempt_count = 1
      AND next_attempt_at > NOW()
      AND last_error_code = 'storage_http_503'
  ),
  'the worker failure is retryable, observable, and backed off'
);

UPDATE public.chat_media_cleanup_backlog
SET attempt_count = 7,
    next_attempt_at = NOW() - INTERVAL '1 minute'
WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg';

SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_chat_media_cleanup_batch(
      20,
      '11330000-0000-4000-8000-000000000004'
    )
  ),
  1::BIGINT,
  'a due retry can be leased again after backoff'
);

SELECT lives_ok(
  $$
    SELECT public.complete_chat_media_cleanup_job(
      (
        SELECT id FROM public.chat_media_cleanup_backlog
        WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
      ),
      '11330000-0000-4000-8000-000000000004'::UUID,
      FALSE,
      'storage_http_503'
    )
  $$,
  'the eighth failed attempt is recorded'
);

RESET ROLE;

SELECT is(
  (
    SELECT status || ':' || attempt_count::TEXT
    FROM public.chat_media_cleanup_backlog
    WHERE object_path = 'direct/11300000-0000-4000-8000-000000000001/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000003.jpg'
  ),
  'blocked:8',
  'repeated failure becomes an explicit blocked obligation'
);

INSERT INTO public.group_messages (
  id, group_id, sender_id, content, message_type, metadata, is_deleted
)
VALUES (
  '11320000-0000-4000-8000-000000000002',
  '11300000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000001',
  'private group image',
  'image',
  '{
    "image_bucket":"chat-images",
    "image_object_path":"group/11300000-0000-4000-8000-000000000003/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000004.jpg",
    "image_scope":"group",
    "image_scope_id":"11300000-0000-4000-8000-000000000003"
  }'::JSONB,
  FALSE
);

UPDATE public.group_messages
SET is_deleted = TRUE
WHERE id = '11320000-0000-4000-8000-000000000002';

SELECT is(
  (
    SELECT scope || ':' || status || ':' || reason
    FROM public.chat_media_cleanup_backlog
    WHERE object_path = 'group/11300000-0000-4000-8000-000000000003/00000000-0000-0000-0000-000000000001/11310000-0000-4000-8000-000000000004.jpg'
  ),
  'group:pending:group_message_deleted',
  'group message deletion creates its own feature-scoped cleanup obligation'
);

INSERT INTO public.post_media_cleanup_backlog (
  id, owner_id, post_id, bucket, object_path, stored_url, status, reason,
  next_attempt_at
)
VALUES (
  '11340000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '11340000-0000-4000-8000-000000000002',
  'post-images',
  '00000000-0000-0000-0000-000000000001/posts/11340000-0000-4000-8000-000000000002/11340000-0000-4000-8000-000000000003/000.jpg',
  'http://127.0.0.1:54321/storage/v1/object/public/post-images/exact-test-object',
  'pending',
  'delete_post',
  NOW() - INTERVAL '1 minute'
);

SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_post_media_cleanup_batch(
      20,
      '11350000-0000-4000-8000-000000000001'
    )
  ),
  1::BIGINT,
  'the existing post cleanup backlog is leased by the same bounded executor'
);

SELECT lives_ok(
  $$
    SELECT public.complete_post_media_cleanup_job(
      '11340000-0000-4000-8000-000000000001'::UUID,
      '11350000-0000-4000-8000-000000000001'::UUID,
      TRUE,
      NULL
    )
  $$,
  'successful post Storage deletion resolves the leased obligation'
);

RESET ROLE;

SELECT is(
  (
    SELECT status || ':' || attempt_count::TEXT
    FROM public.post_media_cleanup_backlog
    WHERE id = '11340000-0000-4000-8000-000000000001'
  ),
  'resolved:1',
  'post cleanup completion is persisted and observable'
);

SELECT * FROM finish();
ROLLBACK;
