BEGIN;

SELECT no_plan();

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  ('10910000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  profile.id,
  profile.school_id,
  'forum',
  'Architecture Audit',
  'bounded cursor fixture',
  'active',
  FALSE,
  FALSE,
  '2029-05-01T12:00:00Z'::TIMESTAMPTZ
FROM generate_series(1, 25) n
CROSS JOIN public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, like_count, view_count)
SELECT
  ('10910000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  4,
  10
FROM generate_series(1, 25) n;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  fixture.id,
  profile.id,
  profile.school_id,
  fixture.type,
  fixture.title,
  fixture.description,
  fixture.status,
  FALSE,
  fixture.is_private,
  fixture.created_at
FROM (
  VALUES
    (
      '10930000-0000-4000-8000-000000000001'::UUID,
      'secondhand',
      '奶酪 二手书',
      '中文搜索测试',
      'active',
      FALSE,
      '2029-05-03T12:00:00Z'::TIMESTAMPTZ
    ),
    (
      '10910000-0000-4000-8000-000000000090'::UUID,
      'forum',
      'Architecture Audit Private',
      'must stay hidden',
      'active',
      TRUE,
      '2030-05-01T12:00:00Z'::TIMESTAMPTZ
    ),
    (
      '10910000-0000-4000-8000-000000000091'::UUID,
      'forum',
      'Architecture Audit Deleted',
      'must stay hidden',
      'deleted',
      FALSE,
      '2030-05-01T12:01:00Z'::TIMESTAMPTZ
    )
) fixture(id, type, title, description, status, is_private, created_at)
CROSS JOIN public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (id, price, category, condition)
VALUES (
  '10930000-0000-4000-8000-000000000001'::UUID,
  20,
  'books_academic',
  'good'
);

INSERT INTO public.forum_posts (id, board_id)
VALUES
  (
    '10910000-0000-4000-8000-000000000090'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID
  ),
  (
    '10910000-0000-4000-8000-000000000091'::UUID,
    'f0000000-0000-0000-0000-000000000002'::UUID
  );

-- A public row from a blocked author must remain invisible to the viewer.
INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  '10910000-0000-4000-8000-000000000092'::UUID,
  profile.id,
  profile.school_id,
  'forum',
  'Architecture Audit Blocked',
  'blocked author fixture',
  'active',
  FALSE,
  FALSE,
  '2030-05-01T12:02:00Z'::TIMESTAMPTZ
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000004'::UUID;

INSERT INTO public.forum_posts (id, board_id)
VALUES (
  '10910000-0000-4000-8000-000000000092'::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000004'::UUID
)
ON CONFLICT DO NOTHING;

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

CREATE TEMP TABLE search_page_one AS
SELECT id, rank_score, created_at
FROM public.search_posts_page(
  'Architecture Audit',
  'forum',
  NULL, NULL, NULL,
  10
);

CREATE TEMP TABLE search_page_two AS
SELECT page.id, page.rank_score, page.created_at
FROM (
  SELECT *
  FROM search_page_one
  ORDER BY rank_score DESC, created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.search_posts_page(
  'Architecture Audit',
  'forum',
  cursor.rank_score,
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is((SELECT COUNT(*) FROM search_page_one), 10::BIGINT, 'Search first page is bounded');
SELECT is((SELECT COUNT(*) FROM search_page_two), 10::BIGINT, 'Search second page is bounded');
SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM search_page_one
      UNION ALL
      SELECT id FROM search_page_two
    ) pages
  ),
  20::BIGINT,
  'Equal rank/timestamp rows use UUID without duplicate or skip'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM search_page_one
    WHERE id IN (
      '10910000-0000-4000-8000-000000000090'::UUID,
      '10910000-0000-4000-8000-000000000091'::UUID,
      '10910000-0000-4000-8000-000000000092'::UUID
    )
  ),
  'Search excludes private, inactive, and blocked-author rows'
);

CREATE TEMP TABLE forum_search_page_one AS
SELECT id, rank_score, created_at
FROM public.search_forum_post_ids_page(
  'Architecture Audit',
  'f0000000-0000-0000-0000-000000000002'::UUID,
  NULL, NULL, NULL,
  10
);

CREATE TEMP TABLE forum_search_page_two AS
SELECT page.id, page.rank_score, page.created_at
FROM (
  SELECT *
  FROM forum_search_page_one
  ORDER BY rank_score DESC, created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.search_forum_post_ids_page(
  'Architecture Audit',
  'f0000000-0000-0000-0000-000000000002'::UUID,
  cursor.rank_score,
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM forum_search_page_one
      UNION ALL
      SELECT id FROM forum_search_page_two
    ) pages
  ),
  20::BIGINT,
  'Dedicated Forum search paginates rank ties without duplicate or skip'
);
SELECT is(
  (
    SELECT COUNT(*)
    FROM public.search_forum_post_ids_page(
      'Architecture Audit',
      'f0000000-0000-0000-0000-000000000001'::UUID,
      NULL, NULL, NULL,
      10
    )
  ),
  0::BIGINT,
  'Dedicated Forum search applies the board filter before pagination'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.search_posts_page('奶酪', 'market', NULL, NULL, NULL, 10)
    WHERE id = '10930000-0000-4000-8000-000000000001'::UUID
  ),
  'Trigram substring behavior supports Chinese content'
);
SELECT is(
  (
    SELECT total_count
    FROM public.get_search_post_counts()
    WHERE category = 'forum'
  ),
  (
    SELECT COUNT(*)::BIGINT
    FROM public.posts p
    JOIN public.forum_posts f ON f.id = p.id
    JOIN public.profile_public_view profile ON profile.id = p.user_id
    WHERE p.type = 'forum'
      AND p.status = 'active'
      AND p.is_private = FALSE
  ),
  'Forum landing count is the real visible total, not a loaded-page sample'
);
SELECT throws_like(
  $$SELECT * FROM public.search_posts_page(
    'retired', 'rent', NULL, NULL, NULL, 10
  )$$,
  '%unsupported search category%',
  'Retired Rent is rejected as a search category'
);

SELECT throws_like(
  $$SELECT * FROM public.search_posts_page(
    'audit', 'forum', 1, NULL, NULL, 10
  )$$,
  '%cursor must be complete%',
  'Search rejects a partial cursor'
);
SELECT throws_like(
  $$SELECT * FROM public.search_posts_page(
    'audit', 'forum', NULL, NULL, NULL, 51
  )$$,
  '%p_limit must be between 1 and 50%',
  'Search rejects an oversized page'
);

RESET ROLE;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'posts_search_document_fts_idx'
  ),
  'Shared post FTS index exists'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'posts_search_document_trgm_idx'
  ),
  'Shared post trigram index exists'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.search_posts_page(text,text,double precision,timestamptz,uuid,integer)',
    'EXECUTE'
  ),
  'Anonymous role cannot execute indexed search'
);

SELECT * FROM finish();
ROLLBACK;
