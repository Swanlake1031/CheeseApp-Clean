-- 186_decouple_forum_anonymity_from_hashtags.sql
--
-- Forum boards are presented by the product as Hashtags. A Hashtag controls
-- discovery; anonymity belongs to the post itself. Preserve the existing
-- board_id foreign key and RPC contracts, but allow either identity mode under
-- every Hashtag.

BEGIN;

ALTER TABLE public.forum_boards
  DROP CONSTRAINT IF EXISTS forum_boards_anonymous_policy;

ALTER TABLE public.forum_boards
  ALTER COLUMN allows_anonymous_posts SET DEFAULT TRUE;

UPDATE public.forum_boards
SET
  allows_anonymous_posts = TRUE,
  updated_at = NOW()
WHERE allows_anonymous_posts IS DISTINCT FROM TRUE;

-- Keep the compatibility field truthful for older app versions and existing
-- views while removing the historical slug-specific policy.
ALTER TABLE public.forum_boards
  ADD CONSTRAINT forum_boards_anonymous_policy
  CHECK (allows_anonymous_posts);

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
    RAISE EXCEPTION 'Posts can only be published to an active Forum Hashtag'
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

-- Trigger functions are internal database hooks, not public RPC endpoints.
-- CREATE OR REPLACE preserves legacy grants, so revoke them explicitly.
REVOKE EXECUTE ON FUNCTION public.enforce_forum_board_rules()
  FROM PUBLIC, anon, authenticated;

-- This update-only trigger existed solely to reject anonymous posts outside
-- the canonical Anonymous board. The post-level choice is now independent.
DROP TRIGGER IF EXISTS posts_enforce_forum_anonymous_update
  ON public.posts;
DROP FUNCTION IF EXISTS public.enforce_forum_anonymous_update();

-- Keep the deferred cross-table validator for transactional publishing and
-- board moves, but limit it to the remaining type/status invariants.
CREATE OR REPLACE FUNCTION public.validate_forum_anonymity_contract()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_post_id UUID := NEW.id;
  v_post_type TEXT;
  v_board_status TEXT;
BEGIN
  SELECT
    post.type,
    board.status
  INTO
    v_post_type,
    v_board_status
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
    RAISE EXCEPTION 'Posts can only be published to an active Forum Hashtag'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.validate_forum_anonymity_contract()
  FROM PUBLIC, anon, authenticated;

DO $verification$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.forum_boards AS board
    WHERE board.allows_anonymous_posts IS DISTINCT FROM TRUE
  ) THEN
    RAISE EXCEPTION 'All Forum Hashtags must allow either post identity mode';
  END IF;
END;
$verification$;

COMMIT;

NOTIFY pgrst, 'reload schema';
