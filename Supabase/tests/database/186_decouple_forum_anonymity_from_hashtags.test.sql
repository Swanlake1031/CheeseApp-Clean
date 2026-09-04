BEGIN;

SELECT plan(6);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.forum_boards AS board
    WHERE board.allows_anonymous_posts IS DISTINCT FROM TRUE
  ),
  'every Forum Hashtag allows the post-level anonymous choice'
);

SELECT is(
  (
    SELECT column_default
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_boards'
      AND column_name = 'allows_anonymous_posts'
  ),
  'true',
  'new Forum Hashtags allow anonymous posts by default'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  fixture.id,
  profile.id,
  profile.school_id,
  'forum',
  fixture.title,
  'Hashtag and identity are independent',
  'active',
  fixture.is_anonymous,
  FALSE
FROM (
  VALUES
    (
      '18600000-0000-4000-8000-000000000001'::UUID,
      'Public identity in shared Hashtag'::TEXT,
      FALSE
    ),
    (
      '18600000-0000-4000-8000-000000000002'::UUID,
      'Anonymous identity in shared Hashtag'::TEXT,
      TRUE
    )
) AS fixture(id, title, is_anonymous)
JOIN public.profiles AS profile
  ON profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments)
SELECT fixture.id, hashtag.id, TRUE
FROM (
  VALUES
    ('18600000-0000-4000-8000-000000000001'::UUID),
    ('18600000-0000-4000-8000-000000000002'::UUID)
) AS fixture(id)
CROSS JOIN LATERAL (
  SELECT board.id
  FROM public.forum_boards AS board
  WHERE board.status = 'active'
    AND board.slug <> 'anonymous'
  ORDER BY board.id
  LIMIT 1
) AS hashtag;

SET CONSTRAINTS ALL IMMEDIATE;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.posts AS post
    JOIN public.forum_posts AS forum ON forum.id = post.id
    WHERE post.id IN (
      '18600000-0000-4000-8000-000000000001'::UUID,
      '18600000-0000-4000-8000-000000000002'::UUID
    )
      AND forum.board_id = (
        SELECT board.id
        FROM public.forum_boards AS board
        WHERE board.status = 'active'
          AND board.slug <> 'anonymous'
        ORDER BY board.id
        LIMIT 1
      )
  ),
  2::BIGINT,
  'one Hashtag accepts both public and anonymous post identities'
);

SET CONSTRAINTS ALL DEFERRED;

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger
    JOIN pg_class AS relation ON relation.oid = trigger.tgrelid
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'posts'
      AND trigger.tgname = 'posts_enforce_forum_anonymous_update'
      AND NOT trigger.tgisinternal
  ),
  'the post anonymous toggle is no longer constrained by Hashtag'
);

SELECT ok(
  pg_get_functiondef(
    'public.validate_forum_anonymity_contract()'::REGPROCEDURE
  ) NOT ILIKE '%is_anonymous%'
  AND pg_get_functiondef(
    'public.validate_forum_anonymity_contract()'::REGPROCEDURE
  ) NOT ILIKE '%allows_anonymous_posts%'
  AND pg_get_functiondef(
    'public.validate_forum_anonymity_contract()'::REGPROCEDURE
  ) NOT ILIKE '%slug%',
  'the deferred Forum validator does not couple anonymity to Hashtag metadata'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.enforce_forum_board_rules()',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.enforce_forum_board_rules()',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.validate_forum_anonymity_contract()',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.validate_forum_anonymity_contract()',
    'EXECUTE'
  ),
  'internal Forum trigger functions are not exposed as Data API RPCs'
);

SELECT * FROM finish();

ROLLBACK;
