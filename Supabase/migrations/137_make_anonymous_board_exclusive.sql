-- 137_make_anonymous_board_exclusive.sql
-- Anonymous identity is board-owned: only the canonical `anonymous` board may
-- contain anonymous posts, and every post in that board must be anonymous.

BEGIN;

-- Never reveal an existing anonymous author as part of this migration. Abort
-- if unexpected legacy data exists so it can be reviewed and moved safely.
DO $preflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.posts AS post
    JOIN public.forum_posts AS forum ON forum.id = post.id
    JOIN public.forum_boards AS board ON board.id = forum.board_id
    WHERE COALESCE(post.is_anonymous, FALSE)
      AND board.slug <> 'anonymous'
  ) THEN
    RAISE EXCEPTION
      'Anonymous posts exist outside the Anonymous board; review before migration';
  END IF;
END;
$preflight$;

UPDATE public.forum_boards AS board
SET
  allows_anonymous_posts = (board.slug = 'anonymous'),
  updated_at = NOW()
WHERE board.allows_anonymous_posts IS DISTINCT FROM (board.slug = 'anonymous');

ALTER TABLE public.forum_boards
  DROP CONSTRAINT IF EXISTS forum_boards_anonymous_policy;
ALTER TABLE public.forum_boards
  ADD CONSTRAINT forum_boards_anonymous_policy
  CHECK (allows_anonymous_posts = (slug = 'anonymous'));

CREATE OR REPLACE FUNCTION public.validate_forum_anonymity_contract()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_post_id UUID := NEW.id;
  v_post_type TEXT;
  v_is_anonymous BOOLEAN;
  v_board_status TEXT;
  v_requires_anonymous BOOLEAN;
BEGIN
  SELECT
    post.type,
    post.is_anonymous,
    board.status,
    board.slug = 'anonymous'
  INTO
    v_post_type,
    v_is_anonymous,
    v_board_status,
    v_requires_anonymous
  FROM public.posts AS post
  JOIN public.forum_posts AS forum ON forum.id = post.id
  JOIN public.forum_boards AS board ON board.id = forum.board_id
  WHERE post.id = v_post_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_post_type IS DISTINCT FROM 'forum' THEN
    RAISE EXCEPTION 'Forum details must reference a Forum base post'
      USING ERRCODE = '23514';
  END IF;

  IF v_board_status <> 'active' THEN
    RAISE EXCEPTION 'Posts can only be published to an active Forum board'
      USING ERRCODE = '23514';
  END IF;

  IF v_requires_anonymous AND NOT COALESCE(v_is_anonymous, FALSE) THEN
    RAISE EXCEPTION 'The Anonymous Forum board requires anonymous posting'
      USING ERRCODE = '23514';
  END IF;

  IF NOT v_requires_anonymous AND COALESCE(v_is_anonymous, FALSE) THEN
    RAISE EXCEPTION 'Only the Anonymous Forum board allows anonymous posting'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DO $verification$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.forum_boards AS board
    WHERE board.allows_anonymous_posts IS DISTINCT FROM (board.slug = 'anonymous')
  ) THEN
    RAISE EXCEPTION 'Forum board anonymous policy verification failed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.posts AS post
    JOIN public.forum_posts AS forum ON forum.id = post.id
    JOIN public.forum_boards AS board ON board.id = forum.board_id
    WHERE COALESCE(post.is_anonymous, FALSE) IS DISTINCT FROM
          (board.slug = 'anonymous')
  ) THEN
    RAISE EXCEPTION 'Forum post anonymous policy verification failed';
  END IF;
END;
$verification$;

COMMIT;

NOTIFY pgrst, 'reload schema';
