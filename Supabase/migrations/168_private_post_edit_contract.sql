-- Owner-only edit contract for both public and private posts.
-- Public profile/feed functions must continue excluding private content.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_post_edit_contract(p_post_id UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  type TEXT,
  title TEXT,
  description TEXT,
  status TEXT,
  is_anonymous BOOLEAN,
  is_private BOOLEAN,
  created_at TIMESTAMPTZ,
  price NUMERIC,
  original_price NUMERIC,
  category TEXT,
  condition TEXT,
  is_negotiable BOOLEAN,
  board_id UUID,
  board_name TEXT,
  allow_comments BOOLEAN,
  user_name TEXT,
  user_avatar TEXT,
  images JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    post_row.id,
    post_row.user_id,
    post_row.type,
    post_row.title,
    COALESCE(post_row.description, ''),
    post_row.status,
    post_row.is_anonymous,
    post_row.is_private,
    post_row.created_at,
    market.price,
    market.original_price,
    market.category,
    market.condition,
    market.is_negotiable,
    forum.board_id,
    board.name,
    forum.allow_comments,
    profile.full_name,
    profile.avatar_url,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', image.id,
            'url', image.url,
            'order_index', image.order_index
          )
          ORDER BY image.order_index, image.id
        )
        FROM public.post_images image
        WHERE image.post_id = post_row.id
      ),
      '[]'::JSONB
    )
  FROM public.posts post_row
  JOIN public.profiles profile ON profile.id = post_row.user_id
  LEFT JOIN public.secondhand_posts market
    ON market.id = post_row.id AND post_row.type = 'secondhand'
  LEFT JOIN public.forum_posts forum
    ON forum.id = post_row.id AND post_row.type = 'forum'
  LEFT JOIN public.forum_boards board ON board.id = forum.board_id
  WHERE post_row.id = p_post_id
    AND post_row.user_id = v_me
    AND post_row.type IN ('forum', 'secondhand')
    AND post_row.status = 'active';
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_post_edit_contract(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_post_edit_contract(UUID)
  TO authenticated;

COMMENT ON FUNCTION public.get_my_post_edit_contract(UUID) IS
  'Returns one editable forum/secondhand post owned by auth.uid(), including private posts and ordered media.';

NOTIFY pgrst, 'reload schema';

COMMIT;
