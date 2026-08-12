-- 164_relist_completed_secondhand_listing.sql
--
-- Allows a seller to put a completed Marketplace listing back on sale without
-- cloning the post. Completed purchase intents remain immutable history; a new
-- contact card starts a new intent for the new availability cycle.

BEGIN;

ALTER TABLE public.secondhand_purchase_intents
  DROP CONSTRAINT secondhand_purchase_intents_listing_buyer_unique;

CREATE UNIQUE INDEX secondhand_purchase_intents_listing_buyer_active_key
  ON public.secondhand_purchase_intents (listing_id, buyer_id)
  WHERE status = 'active';

CREATE OR REPLACE FUNCTION public.start_secondhand_purchase_intent_from_contact_card()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_listing_id UUID;
  v_seller_id UUID;
  v_listing_status TEXT;
  v_is_private BOOLEAN;
  v_user1_id UUID;
  v_user2_id UUID;
BEGIN
  IF NEW.is_deleted = TRUE
     OR NEW.sender_id IS NULL
     OR NEW.metadata -> 'post_contact_card' ->> 'post_kind'
       IS DISTINCT FROM 'secondhand' THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_listing_id := (
      NEW.metadata -> 'post_contact_card' ->> 'post_id'
    )::UUID;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Invalid secondhand contact-card listing id'
      USING ERRCODE = '22023';
  END;

  IF v_listing_id IS NULL THEN
    RAISE EXCEPTION 'Secondhand contact card requires a listing id'
      USING ERRCODE = '22023';
  END IF;

  SELECT post_row.user_id, post_row.status, post_row.is_private
  INTO v_seller_id, v_listing_status, v_is_private
  FROM public.posts post_row
  JOIN public.secondhand_posts listing ON listing.id = post_row.id
  WHERE post_row.id = v_listing_id
    AND post_row.type = 'secondhand'
  FOR UPDATE OF post_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Secondhand listing not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NEW.sender_id = v_seller_id THEN
    RAISE EXCEPTION 'The seller cannot create a purchase intent'
      USING ERRCODE = '22023';
  END IF;

  IF v_listing_status <> 'active' OR v_is_private THEN
    RAISE EXCEPTION 'This listing is not currently available'
      USING ERRCODE = '55000';
  END IF;

  SELECT conversation.user1_id, conversation.user2_id
  INTO v_user1_id, v_user2_id
  FROM public.conversations conversation
  WHERE conversation.id = NEW.conversation_id;

  IF NOT FOUND
     OR NEW.sender_id NOT IN (v_user1_id, v_user2_id)
     OR v_seller_id NOT IN (v_user1_id, v_user2_id) THEN
    RAISE EXCEPTION 'Contact-card conversation does not match listing parties'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.secondhand_purchase_intents (
    listing_id,
    conversation_id,
    seller_id,
    buyer_id,
    status,
    started_at
  ) VALUES (
    v_listing_id,
    NEW.conversation_id,
    v_seller_id,
    NEW.sender_id,
    'active',
    NEW.created_at
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.start_secondhand_purchase_intent_from_contact_card()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.relist_completed_secondhand_listing(
  p_transaction_id UUID,
  p_listing_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_transaction public.secondhand_purchase_intents%ROWTYPE;
  v_listing_status TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_transaction
  FROM public.secondhand_purchase_intents intent
  WHERE intent.id = p_transaction_id
    AND intent.listing_id = p_listing_id
    AND intent.seller_id = v_me
    AND intent.status = 'completed'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Completed transaction not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  SELECT post_row.status INTO v_listing_status
  FROM public.posts post_row
  JOIN public.secondhand_posts listing ON listing.id = post_row.id
  WHERE post_row.id = p_listing_id
    AND post_row.type = 'secondhand'
    AND post_row.user_id = v_me
  FOR UPDATE OF post_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;
  IF v_listing_status <> 'completed' THEN
    RAISE EXCEPTION 'Only a completed listing can be relisted'
      USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.secondhand_purchase_intents intent
    WHERE intent.listing_id = p_listing_id
      AND intent.status = 'completed'
      AND (
        COALESCE(intent.ended_at, intent.updated_at),
        intent.id
      ) > (
        COALESCE(v_transaction.ended_at, v_transaction.updated_at),
        v_transaction.id
      )
  ) THEN
    RAISE EXCEPTION 'Only the latest completed transaction can relist this item'
      USING ERRCODE = '55000';
  END IF;

  PERFORM set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);

  UPDATE public.secondhand_posts listing
  SET sold_count = 0,
      sold_at = NULL,
      availability_confirmed_at = v_now,
      availability_reminder_sent_at = NULL,
      availability_cycle = listing.availability_cycle + 1,
      expires_at = v_now + INTERVAL '30 days'
  WHERE listing.id = p_listing_id;

  UPDATE public.posts
  SET status = 'active',
      is_private = FALSE,
      hidden_at = NULL,
      hidden_reason = NULL,
      updated_at = v_now
  WHERE id = p_listing_id;

  PERFORM set_config('cheese.secondhand_lifecycle_write', '', TRUE);

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.relist_completed_secondhand_listing(UUID, UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.relist_completed_secondhand_listing(UUID, UUID)
  TO authenticated;

DROP FUNCTION public.get_my_completed_secondhand_transactions(TEXT);

CREATE FUNCTION public.get_my_completed_secondhand_transactions(
  p_role TEXT
)
RETURNS TABLE (
  transaction_id UUID,
  listing_id UUID,
  role TEXT,
  listing_title TEXT,
  price NUMERIC,
  cover_image TEXT,
  counterparty_id UUID,
  counterparty_name TEXT,
  counterparty_avatar TEXT,
  completed_at TIMESTAMPTZ,
  listing_status TEXT,
  can_relist BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_role TEXT := lower(btrim(COALESCE(p_role, '')));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_role NOT IN ('buyer', 'seller') THEN
    RAISE EXCEPTION 'Unsupported completed transaction role'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    intent.id,
    intent.listing_id,
    v_role,
    post_row.title,
    listing.price,
    (
      SELECT image.url
      FROM public.post_images image
      WHERE image.post_id = intent.listing_id
      ORDER BY image.order_index, image.id
      LIMIT 1
    ),
    CASE WHEN v_role = 'buyer' THEN intent.seller_id ELSE intent.buyer_id END,
    COALESCE(NULLIF(btrim(counterparty.full_name), ''), '已注销'),
    counterparty.avatar_url,
    COALESCE(intent.ended_at, intent.updated_at),
    post_row.status,
    (
      v_role = 'seller'
      AND post_row.status = 'completed'
      AND intent.id = (
        SELECT latest_intent.id
        FROM public.secondhand_purchase_intents latest_intent
        WHERE latest_intent.listing_id = intent.listing_id
          AND latest_intent.status = 'completed'
        ORDER BY
          COALESCE(latest_intent.ended_at, latest_intent.updated_at) DESC,
          latest_intent.id DESC
        LIMIT 1
      )
    )
  FROM public.secondhand_purchase_intents intent
  JOIN public.posts post_row ON post_row.id = intent.listing_id
  JOIN public.secondhand_posts listing ON listing.id = intent.listing_id
  LEFT JOIN public.profiles counterparty ON counterparty.id = CASE
    WHEN v_role = 'buyer' THEN intent.seller_id
    ELSE intent.buyer_id
  END
  WHERE intent.status = 'completed'
    AND (
      (v_role = 'buyer' AND intent.buyer_id = v_me)
      OR (v_role = 'seller' AND intent.seller_id = v_me)
    )
  ORDER BY COALESCE(intent.ended_at, intent.updated_at) DESC, intent.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
