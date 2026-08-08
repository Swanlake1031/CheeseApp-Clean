-- 058_ignore_invite_cards_in_dm_quota.sql
-- Keep stranger DM safeguard, but do not count invite cards in the quota.

BEGIN;

CREATE OR REPLACE FUNCTION public.can_send_direct_message(
  p_conversation_id UUID,
  p_sender_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public, auth
AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
  v_other UUID;
  v_sender_sent_count INTEGER;
  v_other_replied BOOLEAN;
BEGIN
  SELECT c.user1_id, c.user2_id
    INTO v_user1, v_user2
  FROM public.conversations c
  WHERE c.id = p_conversation_id;

  IF v_user1 IS NULL OR v_user2 IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_sender_id <> v_user1 AND p_sender_id <> v_user2 THEN
    RETURN FALSE;
  END IF;

  v_other := CASE WHEN p_sender_id = v_user1 THEN v_user2 ELSE v_user1 END;

  IF public.is_user_blocked(p_sender_id, v_other) THEN
    RETURN FALSE;
  END IF;

  IF public.is_mutual_follow(p_sender_id, v_other) THEN
    RETURN TRUE;
  END IF;

  -- Unlock forever once the other side has replied at least once.
  -- Invite cards are excluded from this unlock signal.
  SELECT EXISTS (
    SELECT 1
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
      AND m.sender_id = v_other
      AND COALESCE(m.is_deleted, FALSE) = FALSE
      AND NOT (
        COALESCE(m.message_type, '') = 'text'
        AND (
          COALESCE(m.metadata, '{}'::jsonb) ? 'team_join_card'
          OR COALESCE(m.metadata, '{}'::jsonb) ? 'ride_invite_card'
        )
      )
  )
    INTO v_other_replied;

  IF v_other_replied THEN
    RETURN TRUE;
  END IF;

  -- Before first reply from the other side, sender can only send one message.
  -- Invite cards are excluded from this quota.
  SELECT COUNT(*)
    INTO v_sender_sent_count
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND m.sender_id = p_sender_id
    AND COALESCE(m.is_deleted, FALSE) = FALSE
    AND NOT (
      COALESCE(m.message_type, '') = 'text'
      AND (
        COALESCE(m.metadata, '{}'::jsonb) ? 'team_join_card'
        OR COALESCE(m.metadata, '{}'::jsonb) ? 'ride_invite_card'
      )
    );

  RETURN v_sender_sent_count < 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_send_direct_message(UUID, UUID)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
