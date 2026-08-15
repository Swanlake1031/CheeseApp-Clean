-- 169_cancel_seller_transaction_without_hiding_listing.sql
--
-- Cancelling a seller/buyer transaction ends only the selected purchase
-- intent. The marketplace listing remains active and public. The legacy
-- listing-wide RPC is retained for older clients, but must never change post
-- visibility or lifecycle state.

BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_seller_secondhand_purchase_intent(
  p_intent_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_intent public.secondhand_purchase_intents%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_intent
  FROM public.secondhand_purchase_intents intent
  WHERE intent.id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND OR v_intent.seller_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Purchase intent not found or not owned by seller'
      USING ERRCODE = '42501';
  END IF;
  IF v_intent.status <> 'active' THEN
    RAISE EXCEPTION 'Purchase intent is no longer active'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.secondhand_purchase_intents
  SET status = 'seller_stopped',
      ended_at = v_now,
      updated_at = v_now
  WHERE id = v_intent.id;

  PERFORM public.append_secondhand_transaction_chat_event(
    v_intent.conversation_id,
    v_me,
    v_intent.listing_id,
    v_intent.id,
    'seller_stopped',
    '卖家已取消交易'
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_seller_secondhand_purchase_intent(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_seller_secondhand_purchase_intent(UUID)
  TO authenticated;

-- Compatibility for installed clients that still call the listing-wide
-- action. It may end active purchase intents, but it no longer hides,
-- inactivates, completes, or otherwise mutates the listing.
CREATE OR REPLACE FUNCTION public.stop_selling_secondhand_listing(
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
  v_intent public.secondhand_purchase_intents%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.posts post_row
    JOIN public.secondhand_posts listing ON listing.id = post_row.id
    WHERE post_row.id = p_listing_id
      AND post_row.type = 'secondhand'
      AND post_row.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  FOR v_intent IN
    SELECT *
    FROM public.secondhand_purchase_intents intent
    WHERE intent.listing_id = p_listing_id
      AND intent.seller_id = v_me
      AND intent.status = 'active'
    FOR UPDATE
  LOOP
    UPDATE public.secondhand_purchase_intents
    SET status = 'seller_stopped',
        ended_at = v_now,
        updated_at = v_now
    WHERE id = v_intent.id;

    PERFORM public.append_secondhand_transaction_chat_event(
      v_intent.conversation_id,
      v_me,
      v_intent.listing_id,
      v_intent.id,
      'seller_stopped',
      '卖家已取消交易'
    );
  END LOOP;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
