-- 156_secondhand_chat_purchase_intents.sql
--
-- Persistent buyer/listing transaction state for Marketplace direct chats.
-- The existing post_contact_card message remains the only transaction trigger.
-- Normal direct messages never create purchase intents.

BEGIN;

CREATE TABLE public.secondhand_purchase_intents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL
    REFERENCES public.secondhand_posts(id) ON DELETE CASCADE,
  conversation_id UUID NOT NULL
    REFERENCES public.conversations(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (
    status IN (
      'active',
      'buyer_cancelled',
      'completed',
      'listing_sold',
      'seller_stopped'
    )
  ),
  started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  ended_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT secondhand_purchase_intents_distinct_parties
    CHECK (seller_id <> buyer_id),
  CONSTRAINT secondhand_purchase_intents_ended_state_consistent
    CHECK (
      (status = 'active' AND ended_at IS NULL)
      OR
      (status <> 'active' AND ended_at IS NOT NULL)
    ),
  CONSTRAINT secondhand_purchase_intents_listing_buyer_unique
    UNIQUE (listing_id, buyer_id)
);

CREATE INDEX secondhand_purchase_intents_conversation_idx
  ON public.secondhand_purchase_intents (conversation_id, started_at DESC, id DESC);

CREATE INDEX secondhand_purchase_intents_listing_active_idx
  ON public.secondhand_purchase_intents (listing_id, started_at, id)
  WHERE status = 'active';

ALTER TABLE public.secondhand_purchase_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.secondhand_purchase_intents
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.secondhand_purchase_intents TO service_role;

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
  ON CONFLICT (listing_id, buyer_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_start_secondhand_purchase_intent
  ON public.messages;
CREATE TRIGGER trg_start_secondhand_purchase_intent
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.start_secondhand_purchase_intent_from_contact_card();

REVOKE ALL ON FUNCTION public.start_secondhand_purchase_intent_from_contact_card()
  FROM PUBLIC, anon, authenticated, service_role;

-- Preserve the meaning of contact cards sent before this migration. Completed
-- listings cannot identify a historical winning buyer, so those relationships
-- are conservatively represented as sold-to-another instead of fabricating a
-- completed buyer.
WITH contact_rows AS (
  SELECT DISTINCT ON (post_row.id, message.sender_id)
    post_row.id AS listing_id,
    message.conversation_id,
    post_row.user_id AS seller_id,
    message.sender_id AS buyer_id,
    message.created_at AS started_at,
    post_row.status AS listing_status
  FROM public.messages message
  JOIN public.posts post_row
    ON post_row.id = CASE
      WHEN message.metadata -> 'post_contact_card' ->> 'post_id'
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN (message.metadata -> 'post_contact_card' ->> 'post_id')::UUID
      ELSE NULL
    END
  JOIN public.secondhand_posts listing ON listing.id = post_row.id
  JOIN public.conversations conversation
    ON conversation.id = message.conversation_id
  WHERE message.is_deleted = FALSE
    AND message.sender_id IS NOT NULL
    AND message.metadata -> 'post_contact_card' ->> 'post_kind' = 'secondhand'
    AND message.sender_id <> post_row.user_id
    AND message.sender_id IN (conversation.user1_id, conversation.user2_id)
    AND post_row.user_id IN (conversation.user1_id, conversation.user2_id)
  ORDER BY post_row.id, message.sender_id, message.created_at, message.id
)
INSERT INTO public.secondhand_purchase_intents (
  listing_id,
  conversation_id,
  seller_id,
  buyer_id,
  status,
  started_at,
  ended_at,
  created_at,
  updated_at
)
SELECT
  contact.listing_id,
  contact.conversation_id,
  contact.seller_id,
  contact.buyer_id,
  CASE contact.listing_status
    WHEN 'active' THEN 'active'
    WHEN 'completed' THEN 'listing_sold'
    ELSE 'seller_stopped'
  END,
  contact.started_at,
  CASE WHEN contact.listing_status = 'active' THEN NULL ELSE clock_timestamp() END,
  contact.started_at,
  clock_timestamp()
FROM contact_rows contact
ON CONFLICT (listing_id, buyer_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.append_secondhand_transaction_chat_event(
  p_conversation_id UUID,
  p_actor_id UUID,
  p_listing_id UUID,
  p_intent_id UUID,
  p_event_kind TEXT,
  p_content TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_message_id UUID;
BEGIN
  INSERT INTO public.messages (
    conversation_id,
    sender_id,
    content,
    message_type,
    metadata,
    is_read
  ) VALUES (
    p_conversation_id,
    p_actor_id,
    p_content,
    'text',
    jsonb_build_object(
      'secondhand_transaction_event',
      jsonb_build_object(
        'kind', p_event_kind,
        'listing_id', p_listing_id,
        'intent_id', p_intent_id
      )
    ),
    FALSE
  )
  RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.append_secondhand_transaction_chat_event(
  UUID, UUID, UUID, UUID, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_secondhand_chat_purchase_intent(
  p_conversation_id UUID
)
RETURNS TABLE (
  id UUID,
  listing_id UUID,
  conversation_id UUID,
  seller_id UUID,
  buyer_id UUID,
  status TEXT,
  started_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  listing_title TEXT,
  listing_status TEXT,
  listing_is_private BOOLEAN,
  viewer_role TEXT
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.conversations conversation
    WHERE conversation.id = p_conversation_id
      AND v_me IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'Conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    intent.id,
    intent.listing_id,
    intent.conversation_id,
    intent.seller_id,
    intent.buyer_id,
    intent.status,
    intent.started_at,
    intent.updated_at,
    post_row.title,
    post_row.status,
    post_row.is_private,
    CASE WHEN intent.seller_id = v_me THEN 'seller' ELSE 'buyer' END
  FROM public.secondhand_purchase_intents intent
  JOIN public.posts post_row ON post_row.id = intent.listing_id
  JOIN public.conversations conversation
    ON conversation.id = intent.conversation_id
  WHERE intent.conversation_id = p_conversation_id
    AND v_me IN (intent.seller_id, intent.buyer_id)
  ORDER BY
    (intent.listing_id = conversation.related_post_id) DESC,
    (intent.status = 'active') DESC,
    intent.started_at DESC,
    intent.id DESC
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_secondhand_active_buyers(
  p_listing_id UUID
)
RETURNS TABLE (
  buyer_id UUID,
  buyer_name TEXT,
  buyer_avatar TEXT,
  conversation_id UUID,
  started_at TIMESTAMPTZ
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

  IF NOT EXISTS (
    SELECT 1 FROM public.posts post_row
    WHERE post_row.id = p_listing_id
      AND post_row.type = 'secondhand'
      AND post_row.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    intent.buyer_id,
    COALESCE(NULLIF(btrim(profile.full_name), ''), '已注销'),
    profile.avatar_url,
    intent.conversation_id,
    intent.started_at
  FROM public.secondhand_purchase_intents intent
  LEFT JOIN public.profiles profile ON profile.id = intent.buyer_id
  WHERE intent.listing_id = p_listing_id
    AND intent.seller_id = v_me
    AND intent.status = 'active'
  ORDER BY intent.started_at, intent.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_my_secondhand_purchase_intent(
  p_intent_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_intent public.secondhand_purchase_intents%ROWTYPE;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_intent
  FROM public.secondhand_purchase_intents intent
  WHERE intent.id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND OR v_intent.buyer_id IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Purchase intent not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;
  IF v_intent.status <> 'active' THEN
    RAISE EXCEPTION 'Purchase intent is no longer active'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.secondhand_purchase_intents
  SET status = 'buyer_cancelled',
      ended_at = v_now,
      updated_at = v_now
  WHERE id = v_intent.id;

  PERFORM public.append_secondhand_transaction_chat_event(
    v_intent.conversation_id,
    v_me,
    v_intent.listing_id,
    v_intent.id,
    'buyer_cancelled',
    '买家已取消购买意向'
  );

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_secondhand_sale(
  p_listing_id UUID,
  p_buyer_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_listing_status TEXT;
  v_selected public.secondhand_purchase_intents%ROWTYPE;
  v_other public.secondhand_purchase_intents%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
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
  IF v_listing_status <> 'active' THEN
    RAISE EXCEPTION 'Listing is no longer available for completion'
      USING ERRCODE = '55000';
  END IF;

  SELECT * INTO v_selected
  FROM public.secondhand_purchase_intents intent
  WHERE intent.listing_id = p_listing_id
    AND intent.seller_id = v_me
    AND intent.buyer_id = p_buyer_id
    AND intent.status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selected buyer has no active purchase intent'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.secondhand_purchase_intents
  SET status = 'completed',
      ended_at = v_now,
      updated_at = v_now
  WHERE id = v_selected.id;

  PERFORM public.append_secondhand_transaction_chat_event(
    v_selected.conversation_id,
    v_me,
    p_listing_id,
    v_selected.id,
    'completed',
    '卖家已确认交易完成'
  );

  FOR v_other IN
    SELECT *
    FROM public.secondhand_purchase_intents intent
    WHERE intent.listing_id = p_listing_id
      AND intent.status = 'active'
      AND intent.id <> v_selected.id
    FOR UPDATE
  LOOP
    UPDATE public.secondhand_purchase_intents
    SET status = 'listing_sold',
        ended_at = v_now,
        updated_at = v_now
    WHERE id = v_other.id;

    PERFORM public.append_secondhand_transaction_chat_event(
      v_other.conversation_id,
      v_me,
      p_listing_id,
      v_other.id,
      'listing_sold',
      '该商品已售出'
    );
  END LOOP;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    'allowed',
    TRUE
  );

  UPDATE public.secondhand_posts listing
  SET sold_at = v_now,
      sold_count = GREATEST(
        listing.sold_count,
        COALESCE(listing.quantity, 1)
      )
  WHERE listing.id = p_listing_id;

  UPDATE public.posts
  SET status = 'completed',
      updated_at = v_now
  WHERE id = p_listing_id;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    '',
    TRUE
  );

  RETURN TRUE;
END;
$$;

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
  v_listing_status TEXT;
  v_intent public.secondhand_purchase_intents%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
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
  IF v_listing_status <> 'active' THEN
    RAISE EXCEPTION 'Listing is no longer active'
      USING ERRCODE = '55000';
  END IF;

  FOR v_intent IN
    SELECT *
    FROM public.secondhand_purchase_intents intent
    WHERE intent.listing_id = p_listing_id
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
      p_listing_id,
      v_intent.id,
      'seller_stopped',
      '卖家已停止出售该商品'
    );
  END LOOP;

  UPDATE public.posts
  SET status = 'inactive',
      is_private = TRUE,
      hidden_at = v_now,
      hidden_reason = 'user',
      updated_at = v_now
  WHERE id = p_listing_id;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.get_secondhand_chat_purchase_intent(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_secondhand_active_buyers(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_my_secondhand_purchase_intent(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.complete_secondhand_sale(UUID, UUID)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_secondhand_chat_purchase_intent(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_secondhand_active_buyers(UUID)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_my_secondhand_purchase_intent(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_secondhand_sale(UUID, UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.stop_selling_secondhand_listing(UUID)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
