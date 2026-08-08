-- 119_atomic_publish_mentions.sql
-- Keep stable-ID mentions in the same transaction as feature-owned publishing.
-- Each wrapper delegates to the existing idempotent media-aware contract, then
-- synchronizes mentions before the transaction can commit.

BEGIN;

CREATE OR REPLACE FUNCTION public.publish_forum_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_board_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN DEFAULT FALSE,
  p_allow_comments BOOLEAN DEFAULT TRUE,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
BEGIN
  v_post_id := public.publish_forum_post(
    p_post_id,
    p_operation_id,
    p_board_id,
    p_title,
    p_description,
    p_is_anonymous,
    p_is_private,
    p_allow_comments
  );

  PERFORM public.sync_content_mentions(
    'forum',
    v_post_id,
    NULL,
    p_mentioned_user_ids
  );

  RETURN v_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_secondhand_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_pickup_location TEXT,
  p_expires_at TIMESTAMPTZ,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
BEGIN
  v_post_id := public.publish_secondhand_post(
    p_post_id,
    p_operation_id,
    p_title,
    p_description,
    p_is_anonymous,
    p_is_private,
    p_price,
    p_category,
    p_condition,
    p_is_negotiable,
    p_pickup_location,
    p_expires_at
  );

  PERFORM public.sync_content_mentions(
    'secondhand',
    v_post_id,
    NULL,
    p_mentioned_user_ids
  );

  RETURN v_post_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_rent_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_location TEXT,
  p_bedrooms INTEGER,
  p_bathrooms NUMERIC,
  p_specs TEXT,
  p_size NUMERIC,
  p_property_type TEXT,
  p_available_from DATE,
  p_utilities_included BOOLEAN,
  p_pets_allowed BOOLEAN,
  p_parking_available BOOLEAN,
  p_laundry_type TEXT,
  p_amenities JSONB,
  p_latitude NUMERIC,
  p_longitude NUMERIC,
  p_distance_to_school_km NUMERIC,
  p_expires_at TIMESTAMPTZ,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
BEGIN
  v_post_id := public.publish_rent_post(
    p_post_id,
    p_operation_id,
    p_title,
    p_description,
    p_is_anonymous,
    p_is_private,
    p_price,
    p_location,
    p_bedrooms,
    p_bathrooms,
    p_specs,
    p_size,
    p_property_type,
    p_available_from,
    p_utilities_included,
    p_pets_allowed,
    p_parking_available,
    p_laundry_type,
    p_amenities,
    p_latitude,
    p_longitude,
    p_distance_to_school_km,
    p_expires_at
  );

  PERFORM public.sync_content_mentions(
    'rent',
    v_post_id,
    NULL,
    p_mentioned_user_ids
  );

  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_forum_post_with_mentions(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT, BOOLEAN,
  TEXT, TIMESTAMPTZ, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.publish_rent_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC,
  TEXT, NUMERIC, TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, TEXT, JSONB, NUMERIC,
  NUMERIC, NUMERIC, TIMESTAMPTZ, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.publish_forum_post_with_mentions(
  UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, UUID[]
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT, BOOLEAN,
  TEXT, TIMESTAMPTZ, UUID[]
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_rent_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, INTEGER, NUMERIC,
  TEXT, NUMERIC, TEXT, DATE, BOOLEAN, BOOLEAN, BOOLEAN, TEXT, JSONB, NUMERIC,
  NUMERIC, NUMERIC, TIMESTAMPTZ, UUID[]
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
