BEGIN;

SELECT no_plan();

-- Seed deterministic ties that force the UUID tie-breaker to carry pages.
INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private, created_at
)
SELECT
  ('10710000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  profile.id,
  profile.school_id,
  'forum',
  'Forum page fixture ' || n,
  'same timestamp and score',
  'active',
  FALSE,
  FALSE,
  '2029-01-01T12:00:00Z'::TIMESTAMPTZ
FROM generate_series(1, 31) n
CROSS JOIN public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, is_pinned, hot_score)
SELECT
  ('10710000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  FALSE,
  42
FROM generate_series(1, 31) n;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, status, is_anonymous, is_private,
  created_at
)
SELECT
  ('10720000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  profile.id,
  profile.school_id,
  'secondhand',
  'Secondhand page fixture ' || n,
  'active',
  FALSE,
  FALSE,
  '2029-02-01T12:00:00Z'::TIMESTAMPTZ
FROM generate_series(1, 31) n
CROSS JOIN public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (id, price, category, condition)
SELECT
  ('10720000-0000-4000-8000-' || LPAD(n::TEXT, 12, '0'))::UUID,
  25,
  'other',
  'good'
FROM generate_series(1, 31) n;

-- Rows that must not enter any public page.
INSERT INTO public.posts (
  id, user_id, school_id, type, title, status, is_anonymous, is_private,
  created_at
)
SELECT
  fixture.id,
  profile.id,
  profile.school_id,
  fixture.type,
  fixture.title,
  fixture.status,
  FALSE,
  fixture.is_private,
  '2031-01-01T12:00:00Z'::TIMESTAMPTZ
FROM (
  VALUES
    ('10710000-0000-4000-8000-000000000090'::UUID, 'forum', 'Private Forum', 'active', TRUE),
    ('10710000-0000-4000-8000-000000000091'::UUID, 'forum', 'Inactive Forum', 'deleted', FALSE),
    ('10720000-0000-4000-8000-000000000090'::UUID, 'secondhand', 'Private Item', 'active', TRUE)
) fixture(id, type, title, status, is_private)
CROSS JOIN public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id)
VALUES
  ('10710000-0000-4000-8000-000000000090'::UUID, 'f0000000-0000-0000-0000-000000000002'::UUID),
  ('10710000-0000-4000-8000-000000000091'::UUID, 'f0000000-0000-0000-0000-000000000002'::UUID);
INSERT INTO public.secondhand_posts (id, price, category, condition)
VALUES ('10720000-0000-4000-8000-000000000090'::UUID, 25, 'other', 'good');

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

CREATE TEMP TABLE forum_page_one AS
SELECT id, is_pinned, hot_score, created_at
FROM public.get_forum_posts_page(
  'f0000000-0000-0000-0000-000000000002'::UUID,
  'hottest',
  NULL, NULL, NULL, NULL,
  10
);

CREATE TEMP TABLE forum_page_two AS
SELECT page.id, page.is_pinned, page.hot_score, page.created_at
FROM (
  SELECT *
  FROM forum_page_one
  ORDER BY COALESCE(is_pinned, FALSE) DESC, hot_score DESC, created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.get_forum_posts_page(
  'f0000000-0000-0000-0000-000000000002'::UUID,
  'hottest',
  COALESCE(cursor.is_pinned, FALSE),
  cursor.hot_score,
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is((SELECT COUNT(*) FROM forum_page_one), 10::BIGINT, 'Forum first page is bounded');
SELECT is((SELECT COUNT(*) FROM forum_page_two), 10::BIGINT, 'Forum second page is bounded');
SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM forum_page_one
      UNION ALL
      SELECT id FROM forum_page_two
    ) pages
  ),
  20::BIGINT,
  'Forum identical score/timestamp rows are not duplicated or skipped'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM forum_page_one
    WHERE id IN (
      '10710000-0000-4000-8000-000000000090'::UUID,
      '10710000-0000-4000-8000-000000000091'::UUID
    )
  ),
  'Forum page excludes private and inactive rows'
);

CREATE TEMP TABLE secondhand_page_one AS
SELECT id, created_at
FROM public.get_secondhand_posts_page(NULL, NULL, 10);

CREATE TEMP TABLE secondhand_page_two AS
SELECT page.id, page.created_at
FROM (
  SELECT *
  FROM secondhand_page_one
  ORDER BY created_at DESC, id DESC
  LIMIT 1 OFFSET 9
) cursor
CROSS JOIN LATERAL public.get_secondhand_posts_page(
  cursor.created_at,
  cursor.id,
  10
) page;

SELECT is((SELECT COUNT(*) FROM secondhand_page_one), 10::BIGINT, 'Secondhand first page is bounded');
SELECT is(
  (
    SELECT COUNT(DISTINCT id)
    FROM (
      SELECT id FROM secondhand_page_one
      UNION ALL
      SELECT id FROM secondhand_page_two
    ) pages
  ),
  20::BIGINT,
  'Secondhand identical timestamp/price rows use the UUID tie-breaker'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM secondhand_page_one
    WHERE id = '10720000-0000-4000-8000-000000000090'::UUID
  ),
  'Secondhand page excludes private rows'
);

SELECT throws_like(
  $$SELECT * FROM public.get_forum_posts_page(
    NULL, 'latest', NULL, NULL, NOW(), NULL, 24
  )$$,
  '%cursor is incomplete%',
  'Forum rejects a partial cursor'
);

SELECT throws_like(
  $$SELECT * FROM public.get_secondhand_posts_page(NULL, NULL, 1000)$$,
  '%limit must be between%',
  'Secondhand rejects an unbounded page size'
);

SELECT * FROM finish();
ROLLBACK;
