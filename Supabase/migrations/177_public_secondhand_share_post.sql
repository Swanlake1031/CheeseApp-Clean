-- 177_public_secondhand_share_post.sql
--
-- Expose exactly one active, public Marketplace listing to the share Worker.
-- Anonymous clients keep no direct access to posts, profiles, images, or the
-- protected secondhand collection view.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_secondhand_share_post(
  p_post_id UUID
)
RETURNS TABLE (
  id UUID,
  title TEXT,
  description TEXT,
  price NUMERIC,
  condition TEXT,
  images JSON,
  category TEXT,
  is_negotiable BOOLEAN,
  created_at TIMESTAMPTZ,
  user_name TEXT,
  user_avatar TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT
    post_row.id,
    post_row.title,
    post_row.description,
    listing.price,
    listing.condition,
    COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'id', image.id,
            'url', image.url,
            'order_index', image.order_index
          )
          ORDER BY image.order_index, image.id
        )
        FROM public.post_images image
        WHERE image.post_id = post_row.id
      ),
      '[]'::JSON
    ),
    listing.category,
    listing.is_negotiable,
    post_row.created_at,
    profile.full_name,
    profile.avatar_url
  FROM public.posts post_row
  JOIN public.secondhand_posts listing ON listing.id = post_row.id
  JOIN public.profiles profile ON profile.id = post_row.user_id
  WHERE post_row.id = p_post_id
    AND post_row.type = 'secondhand'
    AND post_row.status = 'active'
    AND post_row.is_private = FALSE
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_public_secondhand_share_post(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_secondhand_share_post(UUID)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_public_secondhand_share_post(UUID) IS
  'Returns one active, non-private Marketplace listing for public share pages.';

NOTIFY pgrst, 'reload schema';

COMMIT;
