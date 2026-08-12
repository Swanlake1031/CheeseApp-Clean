-- 165_scope_secondhand_contact_card_to_active_cycle.sql
--
-- A relisted item keeps its post ID. For Marketplace cards, duplicate
-- detection must therefore follow the active purchase-intent cycle instead of
-- permanently matching any historical card for that post. Forum behavior is
-- unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.has_sent_post_linked_card(
  p_conversation_id UUID,
  p_post_kind TEXT,
  p_post_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_post_kind NOT IN ('forum', 'secondhand') THEN
    RAISE EXCEPTION 'unsupported post kind' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.conversations conversation
    WHERE conversation.id = p_conversation_id
      AND v_user_id IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'conversation access denied' USING ERRCODE = '42501';
  END IF;

  IF p_post_kind = 'secondhand' THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.secondhand_purchase_intents intent
      WHERE intent.conversation_id = p_conversation_id
        AND intent.listing_id = p_post_id
        AND intent.buyer_id = v_user_id
        AND intent.status = 'active'
    );
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.messages message
    WHERE message.conversation_id = p_conversation_id
      AND message.sender_id = v_user_id
      AND message.is_deleted = FALSE
      AND message.metadata -> 'post_contact_card' ->> 'post_kind' = p_post_kind
      AND message.metadata -> 'post_contact_card' ->> 'post_id' = p_post_id::TEXT
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_sent_post_linked_card(UUID, TEXT, UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
