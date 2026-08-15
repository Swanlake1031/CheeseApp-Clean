-- 170_transaction_participant_secondhand_detail.sql
--
-- Marketplace collection surfaces remain public-only, but a buyer or seller
-- must still be able to reopen the original listing from an active/completed
-- transaction after the seller makes that listing private. Return exactly one
-- detail row on success and raise an explicit unavailable error otherwise, so
-- PostgREST clients never receive a zero-row `.single()` coercion failure.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_secondhand_post_detail(
  p_post_id UUID
)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  title TEXT,
  description TEXT,
  category TEXT,
  condition TEXT,
  price NUMERIC,
  original_price NUMERIC,
  is_negotiable BOOLEAN,
  quantity INTEGER,
  sold_count INTEGER,
  created_at TIMESTAMPTZ,
  user_name TEXT,
  user_avatar TEXT,
  user_mcmaster_verified BOOLEAN,
  is_anonymous BOOLEAN,
  images JSONB,
  like_count INTEGER,
  view_count INTEGER,
  save_count INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_is_service BOOLEAN := auth.role() = 'service_role';
BEGIN
  IF v_me IS NULL AND NOT v_is_service THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    listing.id,
    post_row.user_id,
    post_row.title,
    post_row.description,
    listing.category,
    listing.condition,
    listing.price,
    listing.original_price,
    listing.is_negotiable,
    listing.quantity,
    listing.sold_count,
    post_row.created_at,
    profile.full_name,
    profile.avatar_url,
    CASE
      WHEN post_row.is_anonymous THEN FALSE
      ELSE COALESCE(profile.is_mcmaster_verified, FALSE)
    END,
    post_row.is_anonymous,
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
        WHERE image.post_id = listing.id
      ),
      '[]'::JSONB
    ),
    listing.like_count,
    listing.view_count,
    listing.save_count
  FROM public.secondhand_posts listing
  JOIN public.posts post_row ON post_row.id = listing.id
  LEFT JOIN public.profile_public_view profile ON profile.id = post_row.user_id
  WHERE listing.id = p_post_id
    AND post_row.type = 'secondhand'
    AND post_row.status <> 'deleted'
    AND (
      v_is_service
      OR post_row.user_id = v_me
      OR (
        post_row.status = 'active'
        AND post_row.is_private = FALSE
        AND NOT public.is_user_blocked(v_me, post_row.user_id)
      )
      OR EXISTS (
        SELECT 1
        FROM public.secondhand_purchase_intents intent
        WHERE intent.listing_id = post_row.id
          AND v_me IN (intent.seller_id, intent.buyer_id)
          AND intent.status IN ('active', 'completed')
      )
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Secondhand listing not found or unavailable'
      USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.get_secondhand_post_detail(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_secondhand_post_detail(UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
