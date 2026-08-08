-- 136_defer_forum_anonymity_contract.sql
-- Forum editing updates posts and forum_posts in a deliberate order. Validate
-- the final cross-table anonymity contract at transaction end so legitimate
-- board moves work without allowing an invalid state to commit.

BEGIN;

-- Keep immediate checks that depend only on the target board and post type.
-- Cross-table identity checks are handled by the deferred triggers below.
CREATE OR REPLACE FUNCTION public.enforce_forum_board_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_status TEXT;
  v_post_type TEXT;
BEGIN
  SELECT board.status
  INTO v_status
  FROM public.forum_boards AS board
  WHERE board.id = NEW.board_id;

  IF v_status IS NULL OR v_status <> 'active' THEN
    RAISE EXCEPTION 'Posts can only be published to an active Forum board'
      USING ERRCODE = '23514';
  END IF;

  SELECT post.type
  INTO v_post_type
  FROM public.posts AS post
  WHERE post.id = NEW.id;

  IF v_post_type IS DISTINCT FROM 'forum' THEN
    RAISE EXCEPTION 'Forum details must reference a Forum base post'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_enforce_forum_anonymous_update
  ON public.posts;
DROP FUNCTION IF EXISTS public.enforce_forum_anonymous_update();

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
  v_allows_anonymous BOOLEAN;
  v_requires_anonymous BOOLEAN;
BEGIN
  SELECT
    post.type,
    post.is_anonymous,
    board.status,
    board.allows_anonymous_posts,
    board.slug = 'anonymous'
  INTO
    v_post_type,
    v_is_anonymous,
    v_board_status,
    v_allows_anonymous,
    v_requires_anonymous
  FROM public.posts AS post
  JOIN public.forum_posts AS forum ON forum.id = post.id
  JOIN public.forum_boards AS board ON board.id = forum.board_id
  WHERE post.id = v_post_id;

  -- Other foreign-key and Forum-detail checks own incomplete/deleted rows.
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

  IF COALESCE(v_is_anonymous, FALSE) AND NOT v_allows_anonymous THEN
    RAISE EXCEPTION 'This Forum board does not allow anonymous posts'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS forum_posts_validate_anonymity_contract
  ON public.forum_posts;
CREATE CONSTRAINT TRIGGER forum_posts_validate_anonymity_contract
AFTER INSERT OR UPDATE ON public.forum_posts
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.validate_forum_anonymity_contract();

DROP TRIGGER IF EXISTS posts_validate_forum_anonymity_contract
  ON public.posts;
CREATE CONSTRAINT TRIGGER posts_validate_forum_anonymity_contract
AFTER INSERT OR UPDATE ON public.posts
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (NEW.type = 'forum')
EXECUTE FUNCTION public.validate_forum_anonymity_contract();

DO $verification$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.posts AS post
    JOIN public.forum_posts AS forum ON forum.id = post.id
    JOIN public.forum_boards AS board ON board.id = forum.board_id
    WHERE post.type <> 'forum'
       OR (board.slug = 'anonymous' AND NOT COALESCE(post.is_anonymous, FALSE))
       OR (COALESCE(post.is_anonymous, FALSE) AND NOT board.allows_anonymous_posts)
  ) THEN
    RAISE EXCEPTION 'Forum anonymity contract verification failed';
  END IF;
END;
$verification$;

COMMIT;

NOTIFY pgrst, 'reload schema';
