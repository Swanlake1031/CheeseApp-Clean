BEGIN;

SELECT plan(1);

DO $test$
DECLARE
  v_names TEXT[];
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.posts post
    JOIN public.profiles profile ON profile.id = post.user_id
    WHERE profile.is_official IS DISTINCT FROM TRUE
       OR profile.deactivated_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Expected only active official profiles to own posts';
  END IF;

  SELECT ARRAY_AGG(board.name ORDER BY board.display_order)
  INTO v_names
  FROM public.forum_boards board
  WHERE board.status = 'active';

  IF v_names IS DISTINCT FROM ARRAY['校园', '兴趣', '提问', '闲聊', '匿名']::TEXT[] THEN
    RAISE EXCEPTION 'Unexpected active Forum boards: %', v_names;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.forum_boards board
    WHERE board.slug = 'anonymous'
      AND board.allows_anonymous_posts = TRUE
      AND board.display_order = 4
  ) THEN
    RAISE EXCEPTION 'Anonymous board configuration is missing';
  END IF;
END;
$test$;

SELECT pass('post reset keeps only active official posts and canonical boards');

SELECT * FROM finish();

ROLLBACK;
