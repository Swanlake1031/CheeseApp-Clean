BEGIN;

SELECT plan(3);

SELECT is(
  (
    SELECT ARRAY_AGG(board.name ORDER BY board.display_order)
    FROM public.forum_boards AS board
    WHERE board.status = 'active'
  ),
  ARRAY['校园', '兴趣', '提问', '闲聊', '匿名']::TEXT[],
  'Forum exposes the five canonical categories in order'
);

SELECT is(
  (
    SELECT board.slug
    FROM public.forum_boards AS board
    WHERE board.id = 'f0000000-0000-0000-0000-000000000003'::UUID
  ),
  'questions',
  'the former Gossip board ID now represents Questions'
);

SELECT is(
  (
    SELECT COUNT(*)::INTEGER
    FROM public.forum_boards AS board
    WHERE board.status = 'active'
      AND (board.slug = 'gossip' OR board.name = '八卦')
  ),
  0,
  'Gossip is no longer an active Forum category'
);

SELECT * FROM finish();

ROLLBACK;
