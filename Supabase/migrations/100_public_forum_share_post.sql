-- 100_public_forum_share_post.sql
-- Expose one active Forum post to the public share Worker without granting
-- anonymous clients direct access to Forum views or their underlying tables.

CREATE OR REPLACE FUNCTION public.get_public_forum_share_post(
  p_post_id UUID
)
RETURNS SETOF public.forum_posts_view
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT *
  FROM public.forum_posts_view
  WHERE id = p_post_id
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_public_forum_share_post(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_forum_share_post(UUID)
  TO anon, authenticated, service_role;
