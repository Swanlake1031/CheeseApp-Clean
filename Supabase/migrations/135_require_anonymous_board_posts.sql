-- 135_require_anonymous_board_posts.sql
-- The canonical Anonymous Forum board is anonymous-only. The iOS client locks
-- the identity control, while these trigger checks prevent older clients or
-- direct API requests from publishing a public identity into that board.

BEGIN;

-- Normalize any rows created before this rule was introduced. This changes
-- only their public presentation; ownership remains attached to posts.user_id
-- for moderation, editing, deletion, and legal/safety obligations.
UPDATE public.posts AS post
SET
  is_anonymous = TRUE,
  updated_at = NOW()
FROM public.forum_posts AS forum,
     public.forum_boards AS board
WHERE forum.id = post.id
  AND board.id = forum.board_id
  AND board.slug = 'anonymous'
  AND post.type = 'forum'
  AND COALESCE(post.is_anonymous, FALSE) = FALSE;

CREATE OR REPLACE FUNCTION public.enforce_forum_board_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_status TEXT;
  v_allows_anonymous BOOLEAN;
  v_requires_anonymous BOOLEAN;
  v_is_anonymous BOOLEAN;
  v_post_type TEXT;
BEGIN
  SELECT
    board.status,
    board.allows_anonymous_posts,
    board.slug = 'anonymous'
  INTO v_status, v_allows_anonymous, v_requires_anonymous
  FROM public.forum_boards AS board
  WHERE board.id = NEW.board_id;

  IF v_status IS NULL OR v_status <> 'active' THEN
    RAISE EXCEPTION 'Posts can only be published to an active Forum board'
      USING ERRCODE = '23514';
  END IF;

  SELECT post.type, post.is_anonymous
  INTO v_post_type, v_is_anonymous
  FROM public.posts AS post
  WHERE post.id = NEW.id;

  IF v_post_type IS DISTINCT FROM 'forum' THEN
    RAISE EXCEPTION 'Forum details must reference a Forum base post'
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

CREATE OR REPLACE FUNCTION public.enforce_forum_anonymous_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_status TEXT;
  v_allows_anonymous BOOLEAN;
  v_requires_anonymous BOOLEAN;
BEGIN
  IF NEW.type IS DISTINCT FROM 'forum' THEN
    RETURN NEW;
  END IF;

  SELECT
    board.status,
    board.allows_anonymous_posts,
    board.slug = 'anonymous'
  INTO v_status, v_allows_anonymous, v_requires_anonymous
  FROM public.forum_posts AS forum
  JOIN public.forum_boards AS board ON board.id = forum.board_id
  WHERE forum.id = NEW.id;

  IF NOT FOUND THEN
    IF COALESCE(NEW.is_anonymous, FALSE) THEN
      RAISE EXCEPTION 'This Forum board does not allow anonymous posts'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF v_requires_anonymous AND NOT COALESCE(NEW.is_anonymous, FALSE) THEN
    RAISE EXCEPTION 'The Anonymous Forum board requires anonymous posting'
      USING ERRCODE = '23514';
  END IF;

  IF COALESCE(NEW.is_anonymous, FALSE)
     AND (v_status <> 'active' OR NOT v_allows_anonymous) THEN
    RAISE EXCEPTION 'This Forum board does not allow anonymous posts'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DO $verification$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.forum_boards AS board
    WHERE board.slug = 'anonymous'
      AND board.status = 'active'
      AND board.allows_anonymous_posts = TRUE
  ) THEN
    RAISE EXCEPTION 'Anonymous Forum board configuration is missing or invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.posts AS post
    JOIN public.forum_posts AS forum ON forum.id = post.id
    JOIN public.forum_boards AS board ON board.id = forum.board_id
    WHERE board.slug = 'anonymous'
      AND COALESCE(post.is_anonymous, FALSE) = FALSE
  ) THEN
    RAISE EXCEPTION 'Anonymous Forum board still contains a public post';
  END IF;
END;
$verification$;

COMMIT;

NOTIFY pgrst, 'reload schema';
