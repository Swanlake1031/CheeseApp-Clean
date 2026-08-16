BEGIN;

-- A like is written by the user who performs the interaction, while the
-- denormalized counter belongs to the author of the target comment/post.
-- Running this trigger as the caller therefore lets RLS silently suppress the
-- counter UPDATE whenever somebody likes content owned by another user.
CREATE OR REPLACE FUNCTION public.update_like_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.target_type = 'post' THEN
      UPDATE public.forum_posts
      SET like_count = COALESCE(like_count, 0) + 1
      WHERE id = NEW.target_id;
    ELSIF NEW.target_type = 'comment' THEN
      UPDATE public.comments
      SET like_count = COALESCE(like_count, 0) + 1
      WHERE id = NEW.target_id;
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.target_type = 'post' THEN
      UPDATE public.forum_posts
      SET like_count = GREATEST(COALESCE(like_count, 0) - 1, 0)
      WHERE id = OLD.target_id;
    ELSIF OLD.target_type = 'comment' THEN
      UPDATE public.comments
      SET like_count = GREATEST(COALESCE(like_count, 0) - 1, 0)
      WHERE id = OLD.target_id;
    END IF;

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS likes_count_trigger ON public.likes;
CREATE TRIGGER likes_count_trigger
AFTER INSERT OR DELETE ON public.likes
FOR EACH ROW
EXECUTE FUNCTION public.update_like_count();

-- Repair counters that drifted while the trigger was subject to caller RLS.
UPDATE public.comments AS comment_row
SET like_count = canonical.like_count
FROM (
  SELECT
    comment_source.id,
    COUNT(like_row.user_id)::INTEGER AS like_count
  FROM public.comments AS comment_source
  LEFT JOIN public.likes AS like_row
    ON like_row.target_type = 'comment'
   AND like_row.target_id = comment_source.id
  GROUP BY comment_source.id
) AS canonical
WHERE comment_row.id = canonical.id
  AND comment_row.like_count IS DISTINCT FROM canonical.like_count;

UPDATE public.forum_posts AS forum_post
SET like_count = canonical.like_count
FROM (
  SELECT
    forum_post_source.id,
    COUNT(like_row.user_id)::INTEGER AS like_count
  FROM public.forum_posts AS forum_post_source
  LEFT JOIN public.likes AS like_row
    ON like_row.target_type = 'post'
   AND like_row.target_id = forum_post_source.id
  GROUP BY forum_post_source.id
) AS canonical
WHERE forum_post.id = canonical.id
  AND forum_post.like_count IS DISTINCT FROM canonical.like_count;

COMMENT ON FUNCTION public.update_like_count() IS
  'Maintains forum post and comment like counters from canonical likes rows without caller RLS suppressing cross-user updates.';

COMMIT;
