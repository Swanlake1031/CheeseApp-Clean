BEGIN;

-- Deployment note:
-- This migration permanently deletes Marketplace post likes and resets their
-- cached counters. Back up public.likes first if historical reaction analytics
-- must be retained. The deleted rows cannot be restored automatically. Apply
-- this migration before releasing clients that remove Marketplace like actions.

DELETE FROM public.likes liked
USING public.posts post
WHERE liked.target_type = 'post'
  AND liked.target_id = post.id
  AND post.type = 'secondhand';

UPDATE public.secondhand_posts
SET like_count = 0
WHERE like_count <> 0;

CREATE OR REPLACE FUNCTION public.reject_secondhand_post_likes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
  IF NEW.target_type = 'post'
    AND EXISTS (
      SELECT 1
      FROM public.posts post
      WHERE post.id = NEW.target_id
        AND post.type = 'secondhand'
    )
  THEN
    RAISE EXCEPTION 'Marketplace posts do not support likes'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_secondhand_post_likes() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_reject_secondhand_post_likes ON public.likes;
CREATE TRIGGER trg_reject_secondhand_post_likes
BEFORE INSERT OR UPDATE OF target_type, target_id ON public.likes
FOR EACH ROW
EXECUTE FUNCTION public.reject_secondhand_post_likes();

NOTIFY pgrst, 'reload schema';

COMMIT;
