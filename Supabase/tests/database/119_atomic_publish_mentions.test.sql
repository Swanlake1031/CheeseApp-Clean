BEGIN;

SELECT plan(12);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.publish_forum_post_with_mentions(uuid,uuid,uuid,text,text,boolean,boolean,boolean,uuid[])',
    'EXECUTE'
  ),
  'authenticated users can call the Forum atomic mention publish contract'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.publish_forum_post_with_mentions(uuid,uuid,uuid,text,text,boolean,boolean,boolean,uuid[])',
    'EXECUTE'
  ),
  'anonymous users cannot call the Forum atomic mention publish contract'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.publish_secondhand_post_with_mentions(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,timestamp with time zone,uuid[])',
    'EXECUTE'
  ),
  'authenticated users can call the Secondhand atomic mention publish contract'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.publish_secondhand_post_with_mentions(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,timestamp with time zone,uuid[])',
    'EXECUTE'
  ),
  'anonymous users cannot call the Secondhand atomic mention publish contract'
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
  public.publish_forum_post_with_mentions(
    '71900000-0000-4000-8000-000000000001'::UUID,
    '71910000-0000-4000-8000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000001'::UUID,
    'Atomic mentions',
    'Hello @Bob',
    FALSE,
    FALSE,
    TRUE,
    ARRAY['00000000-0000-0000-0000-000000000002'::UUID]
  ),
  '71900000-0000-4000-8000-000000000001'::UUID,
  'Forum publication returns the caller-generated stable ID'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_content_mentions(
      '71900000-0000-4000-8000-000000000001'::UUID,
      NULL
    )
  ),
  1::BIGINT,
  'Forum post and stable mention commit together'
);
SELECT is(
  public.publish_forum_post_with_mentions(
    '71900000-0000-4000-8000-000000000001'::UUID,
    '71910000-0000-4000-8000-000000000001'::UUID,
    'f0000000-0000-0000-0000-000000000001'::UUID,
    'Atomic mentions',
    'Hello @Bob',
    FALSE,
    FALSE,
    TRUE,
    ARRAY['00000000-0000-0000-0000-000000000002'::UUID]
  ),
  '71900000-0000-4000-8000-000000000001'::UUID,
  'repeating the same Forum publication is idempotent'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_content_mentions(
      '71900000-0000-4000-8000-000000000001'::UUID,
      NULL
    )
  ),
  1::BIGINT,
  'idempotent retry does not duplicate mention rows'
);

RESET ROLE;

SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE recipient_user_id =
      '00000000-0000-0000-0000-000000000002'::UUID
      AND event_id =
        'mention:forum:71900000-0000-4000-8000-000000000001:00000000-0000-0000-0000-000000000002'
  ),
  1::BIGINT,
  'idempotent retry does not duplicate mention notifications'
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

SELECT throws_like(
  $$SELECT public.publish_forum_post_with_mentions(
    '71900000-0000-4000-8000-000000000002'::UUID,
    '71910000-0000-4000-8000-000000000002'::UUID,
    'f0000000-0000-0000-0000-000000000099'::UUID,
    'Must roll back',
    'Invalid board',
    FALSE,
    FALSE,
    TRUE,
    ARRAY['00000000-0000-0000-0000-000000000002'::UUID]
  )$$,
  '%active Forum board%',
  'a detail failure aborts publication before mentions commit'
);

RESET ROLE;

SELECT is(
  (
    SELECT count(*)
    FROM public.posts
    WHERE id = '71900000-0000-4000-8000-000000000002'::UUID
  ),
  0::BIGINT,
  'failed atomic publication leaves no visible base post'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.content_mentions
    WHERE post_id = '71900000-0000-4000-8000-000000000002'::UUID
  ),
  0::BIGINT,
  'failed atomic publication leaves no mention rows'
);

SELECT * FROM finish();
ROLLBACK;
