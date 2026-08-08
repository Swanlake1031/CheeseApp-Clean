BEGIN;

SELECT plan(4);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT fixture.id, fixture.user_id, profile.school_id, fixture.type,
       fixture.title, 'Marketplace like contract', 'active', FALSE, FALSE
FROM (
  VALUES
    (
      '74000000-0000-4000-8000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'secondhand'::TEXT,
      'Marketplace listing'::TEXT
    ),
    (
      '74000000-0000-4000-8000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'forum'::TEXT,
      'Forum post'::TEXT
    )
) AS fixture(id, user_id, type, title)
JOIN public.profiles profile ON profile.id = fixture.user_id;

INSERT INTO public.secondhand_posts (
  id, price, original_price, category, condition, quantity
)
VALUES (
  '74000000-0000-4000-8000-000000000001',
  30, 60, 'other', 'good', 1
);

INSERT INTO public.forum_posts (id, board_id, allow_comments)
SELECT
  '74000000-0000-4000-8000-000000000002'::UUID,
  board.id,
  TRUE
FROM public.forum_boards board
WHERE board.status <> 'archived'
ORDER BY board.id
LIMIT 1;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger trigger_row
    JOIN pg_catalog.pg_class table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_catalog.pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
    WHERE schema_row.nspname = 'public'
      AND table_row.relname = 'likes'
      AND trigger_row.tgname = 'trg_reject_secondhand_post_likes'
      AND NOT trigger_row.tgisinternal
  ),
  'likes table rejects Marketplace post likes at the database boundary'
);

SELECT throws_ok(
  $$
    INSERT INTO public.likes (user_id, target_type, target_id)
    VALUES (
      '00000000-0000-0000-0000-000000000002',
      'post',
      '74000000-0000-4000-8000-000000000001'
    )
  $$,
  '23514',
  'Marketplace posts do not support likes',
  'a Marketplace post cannot receive a like'
);

SELECT lives_ok(
  $$
    INSERT INTO public.likes (user_id, target_type, target_id)
    VALUES (
      '00000000-0000-0000-0000-000000000002',
      'post',
      '74000000-0000-4000-8000-000000000002'
    )
  $$,
  'Forum post likes continue to work'
);

SELECT is(
  (
    SELECT like_count
    FROM public.secondhand_posts
    WHERE id = '74000000-0000-4000-8000-000000000001'
  ),
  0,
  'Marketplace cached like count remains zero'
);

SELECT * FROM finish();
ROLLBACK;
