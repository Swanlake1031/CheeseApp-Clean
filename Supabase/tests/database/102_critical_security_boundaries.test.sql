BEGIN;

SELECT no_plan();

-- Stable local-only fixture identities from Supabase/seed.sql.
-- A = ...001, B = ...002, C = ...003.
UPDATE public.profiles
SET
  phone = '+1-555-0101',
  wechat_id = 'private-a'
WHERE id = '00000000-0000-0000-0000-000000000001'::UUID;

UPDATE public.profiles
SET
  phone = '+1-555-0102',
  wechat_id = 'private-b',
  bio = 'private-bio'
WHERE id = '00000000-0000-0000-0000-000000000002'::UUID;

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
)
ON CONFLICT DO NOTHING;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  fixture.id,
  fixture.user_id,
  profile.school_id,
  fixture.type,
  fixture.title,
  fixture.description,
  'active',
  fixture.is_anonymous,
  fixture.is_private
FROM (
  VALUES
    (
      '51000000-0000-0000-0000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'forum',
      'C4 named public forum',
      'named public body',
      FALSE,
      FALSE
    ),
    (
      '51000000-0000-0000-0000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'forum',
      'C4 anonymous public forum',
      'anonymous public body',
      TRUE,
      FALSE
    ),
    (
      '51000000-0000-0000-0000-000000000003'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'forum',
      'C4 anonymous private forum',
      'private-forum-secret',
      TRUE,
      TRUE
    ),
    (
      '52000000-0000-0000-0000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'secondhand',
      'C4 private market item',
      'private-market-secret',
      FALSE,
      TRUE
    ),
    (
      '52000000-0000-0000-0000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000003'::UUID,
      'secondhand',
      'C4 public market item',
      'public-market-body',
      FALSE,
      FALSE
    )
) AS fixture(id, user_id, type, title, description, is_anonymous, is_private)
JOIN public.profiles profile ON profile.id = fixture.user_id
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked
)
VALUES
  (
    '51000000-0000-0000-0000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID,
    TRUE, FALSE, FALSE
  ),
  (
    '51000000-0000-0000-0000-000000000002'::UUID,
    'f0000000-0000-0000-0000-000000000001'::UUID,
    TRUE, FALSE, FALSE
  ),
  (
    '51000000-0000-0000-0000-000000000003'::UUID,
    'f0000000-0000-0000-0000-000000000001'::UUID,
    TRUE, FALSE, FALSE
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, is_negotiable, is_free, quantity
)
VALUES
  (
    '52000000-0000-0000-0000-000000000001'::UUID,
    10, 'digital_electronics', 'good', TRUE, FALSE, 1
  ),
  (
    '52000000-0000-0000-0000-000000000002'::UUID,
    20, 'digital_electronics', 'good', TRUE, FALSE, 1
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.post_images (post_id, url, order_index)
VALUES
  (
    '51000000-0000-0000-0000-000000000003'::UUID,
    'https://storage.invalid/private-forum-secret.jpg',
    0
  ),
  (
    '52000000-0000-0000-0000-000000000001'::UUID,
    'https://storage.invalid/private-market-secret.jpg',
    0
  );

INSERT INTO public.conversations (
  id,
  user1_id,
  user2_id,
  related_post_id,
  last_message_at,
  last_message_preview,
  user1_unread_count,
  user2_unread_count
)
VALUES (
  '61000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000003'::UUID,
  '52000000-0000-0000-0000-000000000002'::UUID,
  NOW(),
  'C4 chat fixture',
  1,
  0
)
ON CONFLICT (id) DO UPDATE SET
  last_message_at = EXCLUDED.last_message_at,
  last_message_preview = EXCLUDED.last_message_preview,
  user1_unread_count = EXCLUDED.user1_unread_count;

INSERT INTO public.messages (
  id,
  conversation_id,
  sender_id,
  content,
  message_type,
  metadata,
  is_read,
  is_deleted
)
VALUES (
  '61000000-0000-0000-0000-000000000002'::UUID,
  '61000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000003'::UUID,
  'C4 chat fixture',
  'text',
  '{}'::JSONB,
  FALSE,
  FALSE
)
ON CONFLICT (id) DO UPDATE SET
  is_read = FALSE,
  read_at = NULL;

INSERT INTO public.push_notification_jobs (
  recipient_user_id,
  kind,
  title,
  body,
  payload,
  source_type,
  source_key,
  status,
  available_at
)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  'security_test',
  'Security test',
  'Disposable fixture',
  '{}'::JSONB,
  'security_test',
  'c4-claim',
  'pending',
  NOW()
)
ON CONFLICT (recipient_user_id, source_type, source_key) DO UPDATE
SET status = 'pending', available_at = NOW(), attempts = 0;

-- Catalog and grant invariants.
SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prosecdef
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(COALESCE(procedure.proconfig, ARRAY[]::TEXT[])) setting
        WHERE setting LIKE 'search_path=pg_catalog,%'
      )
  ),
  0::BIGINT,
  'every public SECURITY DEFINER has a fixed pg_catalog-first search_path'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prosecdef
      AND has_function_privilege('anon', procedure.oid, 'EXECUTE')
      AND procedure.oid <> 'public.get_public_forum_share_post(uuid)'::REGPROCEDURE
  ),
  0::BIGINT,
  'anon can execute no definer except the narrow public Forum share RPC'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.prorettype = 'trigger'::REGTYPE
      AND has_function_privilege('authenticated', procedure.oid, 'EXECUTE')
  ),
  0::BIGINT,
  'authenticated clients cannot execute trigger entry points'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.enqueue_push_notification_job(uuid,text,text,text,jsonb,text,text,text,text)',
    'EXECUTE'
  ),
  'authenticated clients cannot invoke the internal push enqueue primitive'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.claim_push_notification_jobs(integer,text)',
    'EXECUTE'
  ),
  'anon cannot claim push jobs'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.claim_push_notification_jobs(integer,text)',
    'EXECUTE'
  ),
  'authenticated users cannot claim push jobs'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.claim_push_notification_jobs(integer,text)',
    'EXECUTE'
  ),
  'service role can claim push jobs'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.request_push_dispatch(text,boolean)',
    'EXECUTE'
  ),
  'authenticated users cannot manually dispatch push jobs'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.configure_cheese_official_msaf_post(uuid)',
    'EXECUTE'
  ),
  'authenticated users cannot invoke trusted official-profile bootstrap'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'profile_public_view'
      AND column_name IN (
        'email', 'phone', 'wechat_id', 'profile_completed', 'deactivated_at',
        'created_at', 'updated_at'
      )
  ),
  0::BIGINT,
  'public profile contract contains no private or internal columns'
);

SELECT ok(
  NOT (
    SELECT 'user_id' = ANY(COALESCE(procedure.proargnames, ARRAY[]::TEXT[]))
    FROM pg_proc procedure
    WHERE procedure.oid = 'public.get_public_forum_share_post(uuid)'::REGPROCEDURE
  ),
  'public Forum share RPC has no author user_id output'
);

-- Anonymous matrix.
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config('request.jwt.claim.role', 'anon', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
SET LOCAL ROLE anon;

SELECT ok(
  NOT has_table_privilege(current_user, 'public.profiles', 'SELECT'),
  'anonymous role cannot read raw profiles'
);

SELECT throws_like(
  $$SELECT * FROM public.get_user_conversations(
    '00000000-0000-0000-0000-000000000001'::UUID
  )$$,
  '%permission denied%',
  'anonymous role cannot invoke authenticated chat RPCs'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_public_forum_share_post(
      '51000000-0000-0000-0000-000000000001'::UUID
    )
  ),
  1::BIGINT,
  'anonymous public share can read an active public Forum post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_public_forum_share_post(
      '51000000-0000-0000-0000-000000000003'::UUID
    )
  ),
  0::BIGINT,
  'anonymous public share cannot read a private Forum post'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_public_forum_share_post(
      '51000000-0000-0000-0000-000000000002'::UUID
    )
    WHERE user_name IS NOT NULL OR user_avatar IS NOT NULL
  ),
  0::BIGINT,
  'anonymous public share masks anonymous author display identity'
);

RESET ROLE;

-- Authenticated user A: self flows work and supplied B identities are rejected.
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
  (SELECT COUNT(*) FROM public.profiles),
  1::BIGINT,
  'user A can read exactly their own private profile row'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000002'::UUID
  ),
  0::BIGINT,
  'user A cannot read user B raw profile'
);

SELECT lives_ok(
  $$UPDATE public.profiles
    SET bio = COALESCE(bio, '')
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID$$,
  'user A can still edit their own profile'
);

SELECT lives_ok(
  $$UPDATE public.profiles
    SET bio = 'forbidden'
    WHERE id = '00000000-0000-0000-0000-000000000002'::UUID$$,
  'an update hidden by profile RLS completes without leaking row existence'
);

RESET ROLE;

SELECT is(
  (
    SELECT bio
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000002'::UUID
  ),
  'private-bio',
  'user A cannot edit user B profile'
);

SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000002'::UUID
  ),
  1::BIGINT,
  'A blocking B retains B public profile so A can identify and unblock B'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000003'::UUID
  ),
  1::BIGINT,
  'an unblocked public profile remains visible'
);

SELECT throws_like(
  $$SELECT * FROM public.get_user_conversations(
    '00000000-0000-0000-0000-000000000002'::UUID
  )$$,
  '%identity mismatch%',
  'user A cannot list user B conversations'
);

SELECT throws_like(
  $$SELECT * FROM public.get_user_chat_groups(
    '00000000-0000-0000-0000-000000000002'::UUID
  )$$,
  '%identity mismatch%',
  'user A cannot list user B chat groups'
);

SELECT throws_like(
  $$SELECT * FROM public.get_mutual_follow_profiles(
    '00000000-0000-0000-0000-000000000002'::UUID,
    10
  )$$,
  '%identity mismatch%',
  'user A cannot list user B mutual follows'
);

SELECT ok(
  to_regprocedure(
    'public.create_secondhand_post(uuid,text,text,numeric,text,text,numeric,boolean,boolean,text,boolean,integer,boolean)'
  ) IS NULL,
  'legacy marketplace writer with caller-selected user identity is removed'
);

SELECT throws_like(
  $$SELECT public.get_or_create_conversation(
    '00000000-0000-0000-0000-000000000002'::UUID,
    '00000000-0000-0000-0000-000000000003'::UUID,
    NULL
  )$$,
  '%identity mismatch%',
  'user A cannot create a conversation as user B'
);

SELECT throws_like(
  $$SELECT public.mark_messages_as_read(
    '60000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID
  )$$,
  '%identity mismatch%',
  'user A cannot mark messages as user B'
);

SELECT lives_ok(
  $$SELECT * FROM public.get_user_conversations(
    '00000000-0000-0000-0000-000000000001'::UUID
  )$$,
  'user A conversation flow still works'
);

SELECT lives_ok(
  $$SELECT public.mark_messages_as_read(
    '61000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID
  )$$,
  'user A can mark messages in their own conversation as read'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.messages
    WHERE id = '61000000-0000-0000-0000-000000000002'::UUID
      AND is_read = TRUE
  ),
  1::BIGINT,
  'the authenticated chat operation updates the intended message'
);

SELECT lives_ok(
  $$SELECT public.upsert_user_push_token(
    'c4-disposable-token',
    'ios',
    'security-test'
  )$$,
  'required authenticated push-token flow still works'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '51000000-0000-0000-0000-000000000002'::UUID
      AND user_id = '00000000-0000-0000-0000-000000000001'::UUID
      AND viewer_owns_post = TRUE
  ),
  1::BIGINT,
  'anonymous Forum owner receives ownership and their own id'
);

RESET ROLE;

-- Authenticated user B: reverse block direction is also enforced.
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'B cannot see A public profile when A blocked B'
);

RESET ROLE;

-- Authenticated user C is an unblocked non-owner Forum viewer.
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000003',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '51000000-0000-0000-0000-000000000002'::UUID
      AND user_id IS NULL
      AND user_name IS NULL
      AND user_avatar IS NULL
      AND viewer_owns_post = FALSE
  ),
  1::BIGINT,
  'non-owner anonymous Forum output has no stable author identity'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '51000000-0000-0000-0000-000000000001'::UUID
      AND user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  1::BIGINT,
  'named Forum output retains the public author id'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '51000000-0000-0000-0000-000000000003'::UUID
  ),
  0::BIGINT,
  'private Forum post is absent from the authenticated Forum feed'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_posts('private-forum-secret', 'forum', 20)
  ),
  0::BIGINT,
  'private Forum post is absent from search'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_posts('private-market-secret', 'market', 20)
  ),
  0::BIGINT,
  'private marketplace post is absent from search'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id IN (
      '51000000-0000-0000-0000-000000000003'::UUID,
      '52000000-0000-0000-0000-000000000001'::UUID
    )
  ),
  0::BIGINT,
  'private posts are absent from direct non-owner PostgREST reads'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts
    WHERE id = '51000000-0000-0000-0000-000000000002'::UUID
  ),
  0::BIGINT,
  'anonymous Forum base rows cannot reveal author_id through direct PostgREST'
);

SELECT ok(
  public.can_view_post(
    '51000000-0000-0000-0000-000000000002'::UUID
  ),
  'anonymous Forum content remains interactable through a non-identifying visibility check'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_images
    WHERE post_id IN (
      '51000000-0000-0000-0000-000000000003'::UUID,
      '52000000-0000-0000-0000-000000000001'::UUID
    )
  ),
  0::BIGINT,
  'private media metadata is absent from direct non-owner reads'
);

RESET ROLE;

-- Service role: raw operational access works, while public/Worker contracts
-- still apply independent privacy filters.
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

SELECT ok(
  (SELECT COUNT(*) FROM public.profiles) >= 3,
  'service role retains full operational profile access'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.forum_posts_view
    WHERE id = '51000000-0000-0000-0000-000000000003'::UUID
  ),
  0::BIGINT,
  'service-role Forum view still excludes private posts'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.secondhand_posts_view
    WHERE id = '52000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'service-role Worker marketplace view still excludes private posts'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_public_forum_share_post(
      '51000000-0000-0000-0000-000000000003'::UUID
    )
  ),
  0::BIGINT,
  'service-role public share RPC still excludes private posts'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.claim_push_notification_jobs(100, 'c4-test-worker')
    WHERE kind = 'security_test'
  ),
  1::BIGINT,
  'service role can execute the intended push claim operation'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
