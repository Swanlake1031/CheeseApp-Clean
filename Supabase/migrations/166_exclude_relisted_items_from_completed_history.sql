-- 166_exclude_relisted_items_from_completed_history.sql
--
-- `relist_completed_secondhand_listing` intentionally keeps the completed
-- purchase intent as immutable audit history. The product-facing "已交易"
-- surface, however, represents listings that are still completed. Once a
-- listing is restored to `active`, it must disappear for both parties instead
-- of being returned as an "已恢复上架" completed card.

BEGIN;

ALTER TABLE public.secondhand_purchase_intents
  ADD COLUMN relisted_at TIMESTAMPTZ;

ALTER TABLE public.secondhand_purchase_intents
  ADD CONSTRAINT secondhand_purchase_intents_relisted_completed
  CHECK (relisted_at IS NULL OR status = 'completed');

COMMENT ON COLUMN public.secondhand_purchase_intents.relisted_at IS
  'When set, this completed transaction remains audit history but is no longer shown in the completed-items product surface.';

-- Backfill listings already restored by migration 164 before this marker
-- existed. `updated_at` is the closest durable timestamp to that relist.
UPDATE public.secondhand_purchase_intents intent
SET relisted_at = COALESCE(post_row.updated_at, clock_timestamp())
FROM public.posts post_row
WHERE post_row.id = intent.listing_id
  AND post_row.status = 'active'
  AND intent.status = 'completed'
  AND intent.relisted_at IS NULL;

CREATE INDEX secondhand_completed_transactions_visible_seller_idx
  ON public.secondhand_purchase_intents (
    seller_id,
    ended_at DESC,
    id DESC
  )
  WHERE status = 'completed' AND relisted_at IS NULL;

CREATE INDEX secondhand_completed_transactions_visible_buyer_idx
  ON public.secondhand_purchase_intents (
    buyer_id,
    ended_at DESC,
    id DESC
  )
  WHERE status = 'completed' AND relisted_at IS NULL;

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
    AND intent.relisted_at IS NULL
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
      AND intent.relisted_at IS NULL
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

  -- Hide every completed intent for the previous listing lifecycle from the
  -- user-facing archive, while preserving its completed status and timestamps.
  UPDATE public.secondhand_purchase_intents intent
  SET relisted_at = v_now
  WHERE intent.listing_id = p_listing_id
    AND intent.status = 'completed'
    AND intent.relisted_at IS NULL;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.relist_completed_secondhand_listing(UUID, UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.relist_completed_secondhand_listing(UUID, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_completed_secondhand_transactions(
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
      AND intent.id = (
        SELECT latest_intent.id
        FROM public.secondhand_purchase_intents latest_intent
        WHERE latest_intent.listing_id = intent.listing_id
          AND latest_intent.status = 'completed'
          AND latest_intent.relisted_at IS NULL
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
    AND intent.relisted_at IS NULL
    AND post_row.status = 'completed'
    AND (
      (v_role = 'buyer' AND intent.buyer_id = v_me)
      OR (v_role = 'seller' AND intent.seller_id = v_me)
    )
  ORDER BY COALESCE(intent.ended_at, intent.updated_at) DESC, intent.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_completed_secondhand_transactions(TEXT)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
