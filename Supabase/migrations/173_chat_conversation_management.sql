-- 173_chat_conversation_management.sql
-- Persistent conversation pinning, per-user group history clearing,
-- owner-managed group membership/name, group nicknames, and conversation-scoped
-- completed Marketplace transaction history.

BEGIN;

ALTER TABLE public.user_conversation_settings
  ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.user_chat_group_settings
  ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS clear_before_at TIMESTAMPTZ;

ALTER TABLE public.chat_group_members
  ADD COLUMN IF NOT EXISTS nickname TEXT;

ALTER TABLE public.chat_group_members
  DROP CONSTRAINT IF EXISTS chat_group_members_nickname_length;
ALTER TABLE public.chat_group_members
  ADD CONSTRAINT chat_group_members_nickname_length
  CHECK (nickname IS NULL OR char_length(btrim(nickname)) BETWEEN 1 AND 30);

CREATE OR REPLACE FUNCTION public.rename_chat_group(
  p_group_id UUID,
  p_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_name TEXT := btrim(COALESCE(p_name, ''));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_name) NOT BETWEEN 1 AND 40 THEN
    RAISE EXCEPTION 'Group name must contain 1 to 40 characters' USING ERRCODE = '22023';
  END IF;

  UPDATE public.chat_groups group_row
  SET name = v_name
  WHERE group_row.id = p_group_id
    AND group_row.owner_id = v_me;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only the group owner can rename this group' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_chat_group_members(
  p_group_id UUID,
  p_member_ids UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_member_id UUID;
  v_added INTEGER := 0;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_groups group_row
    WHERE group_row.id = p_group_id AND group_row.owner_id = v_me
  ) THEN
    RAISE EXCEPTION 'Only the group owner can add members' USING ERRCODE = '42501';
  END IF;

  FOREACH v_member_id IN ARRAY COALESCE(p_member_ids, ARRAY[]::UUID[])
  LOOP
    CONTINUE WHEN v_member_id IS NULL OR v_member_id = v_me;
    IF NOT public.is_mutual_follow(v_me, v_member_id) THEN
      RAISE EXCEPTION 'Only mutual followers can be invited to group chat'
        USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.chat_group_members (group_id, user_id, role)
    VALUES (p_group_id, v_member_id, 'member')
    ON CONFLICT (group_id, user_id) DO NOTHING;
    IF FOUND THEN
      v_added := v_added + 1;
    END IF;
  END LOOP;

  RETURN v_added;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_my_chat_group_nickname(
  p_group_id UUID,
  p_nickname TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_nickname TEXT := NULLIF(btrim(COALESCE(p_nickname, '')), '');
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_nickname IS NOT NULL AND char_length(v_nickname) > 30 THEN
    RAISE EXCEPTION 'Group nickname cannot exceed 30 characters' USING ERRCODE = '22023';
  END IF;

  UPDATE public.chat_group_members membership
  SET nickname = v_nickname
  WHERE membership.group_id = p_group_id
    AND membership.user_id = v_me;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You are not a member of this group' USING ERRCODE = '42501';
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.get_chat_group_members(UUID);
CREATE FUNCTION public.get_chat_group_members(p_group_id UUID)
RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  avatar_url TEXT,
  role TEXT,
  joined_at TIMESTAMPTZ,
  nickname TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.chat_group_members own_membership
    WHERE own_membership.group_id = p_group_id
      AND own_membership.user_id = v_me
  ) THEN
    RAISE EXCEPTION 'Only group members can view group member list' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    membership.user_id,
    COALESCE(NULLIF(btrim(profile.full_name), ''), '用户'),
    profile.avatar_url,
    membership.role,
    membership.created_at,
    membership.nickname
  FROM public.chat_group_members membership
  LEFT JOIN public.profile_public_view profile ON profile.id = membership.user_id
  WHERE membership.group_id = p_group_id
  ORDER BY CASE WHEN membership.role = 'owner' THEN 0 ELSE 1 END, membership.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_conversation_completed_secondhand_transactions(
  p_conversation_id UUID
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
BEGIN
  IF v_me IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.conversations conversation
    WHERE conversation.id = p_conversation_id
      AND v_me IN (conversation.user1_id, conversation.user2_id)
  ) THEN
    RAISE EXCEPTION 'Conversation access denied' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    intent.id,
    intent.listing_id,
    CASE WHEN intent.buyer_id = v_me THEN 'buyer' ELSE 'seller' END,
    post_row.title,
    listing.price,
    (
      SELECT image.url FROM public.post_images image
      WHERE image.post_id = intent.listing_id
      ORDER BY image.order_index, image.id LIMIT 1
    ),
    CASE WHEN intent.buyer_id = v_me THEN intent.seller_id ELSE intent.buyer_id END,
    COALESCE(NULLIF(btrim(counterparty.full_name), ''), '已注销'),
    counterparty.avatar_url,
    COALESCE(intent.ended_at, intent.updated_at),
    post_row.status,
    FALSE
  FROM public.secondhand_purchase_intents intent
  JOIN public.posts post_row ON post_row.id = intent.listing_id
  JOIN public.secondhand_posts listing ON listing.id = intent.listing_id
  LEFT JOIN public.profiles counterparty ON counterparty.id = CASE
    WHEN intent.buyer_id = v_me THEN intent.seller_id ELSE intent.buyer_id
  END
  WHERE intent.conversation_id = p_conversation_id
    AND intent.status = 'completed'
  ORDER BY COALESCE(intent.ended_at, intent.updated_at) DESC, intent.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_chat_group(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_chat_group_members(UUID, UUID[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_my_chat_group_nickname(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_chat_group_members(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_conversation_completed_secondhand_transactions(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rename_chat_group(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.add_chat_group_members(UUID, UUID[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_my_chat_group_nickname(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_chat_group_members(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_conversation_completed_secondhand_transactions(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
