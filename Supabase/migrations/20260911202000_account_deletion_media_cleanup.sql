-- Account deletion must remove all Storage objects whose ownership is known,
-- not only profile avatars.  New post objects use
--   <owner>/posts/<post>/<operation>/<index>.jpg
-- and new chat objects use
--   <scope>/<conversation-or-group>/<owner>/<uuid>.jpg.
-- Content Studio drafts use
--   <owner>/drafts/<draft>/<uuid>.jpg.
--
-- Destructive behavior: account deletion removes the account's posts,
-- comments, direct/group message bodies, media references, notification
-- copies, personalization state, and media-review receipts.  A de-identified
-- chat tombstone keeps only delivery structure; it never retains the original
-- text, card metadata, or image reference.  The existing retrying Storage
-- worker deletes avatars, post objects, chat objects, and draft objects after their exact
-- obligations are committed.  Object bytes cannot be restored after deletion;
-- retain the normal protected database and Storage backups before production
-- rollout.
--
-- Rollout order: deploy the compatible share-worker first, apply this
-- migration, then verify the account cleanup backlog is draining.  Legacy
-- URL-only images without an owner or a feature-owned object path are not
-- guessed at; they require the existing reconciliation process.

BEGIN;

ALTER TABLE moderation_private.account_media_cleanup
  DROP CONSTRAINT IF EXISTS account_media_cleanup_bucket_check;
ALTER TABLE moderation_private.account_media_cleanup
  ADD CONSTRAINT account_media_cleanup_bucket_check
  CHECK (bucket IN ('avatars', 'post-images', 'chat-images', 'content-studio-drafts'));

CREATE INDEX IF NOT EXISTS account_media_cleanup_pending_idx
  ON moderation_private.account_media_cleanup (created_at, id)
  WHERE resolved_at IS NULL;

CREATE OR REPLACE FUNCTION moderation_private.enqueue_account_media_cleanup(
  p_user_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, storage, pg_temp
AS $$
DECLARE
  v_enqueued INTEGER := 0;
  v_user_text TEXT := lower(p_user_id::TEXT);
BEGIN
  IF p_user_id IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO moderation_private.account_media_cleanup (
    user_id,
    bucket,
    object_path
  )
  SELECT
    p_user_id,
    object_row.bucket_id,
    object_row.name
  FROM storage.objects AS object_row
  WHERE object_row.bucket_id IN (
    'avatars',
    'post-images',
    'chat-images',
    'content-studio-drafts'
  )
    AND (
      object_row.owner = p_user_id
      OR (
        object_row.bucket_id = 'avatars'
        AND lower(split_part(object_row.name, '/', 1)) = v_user_text
      )
      OR (
        object_row.bucket_id = 'post-images'
        AND array_length(string_to_array(object_row.name, '/'), 1) = 5
        AND lower(split_part(object_row.name, '/', 1)) = v_user_text
        AND split_part(object_row.name, '/', 2) = 'posts'
      )
      OR (
        object_row.bucket_id = 'chat-images'
        AND array_length(string_to_array(object_row.name, '/'), 1) = 4
        AND split_part(object_row.name, '/', 1) IN ('direct', 'group')
        AND lower(split_part(object_row.name, '/', 3)) = v_user_text
      )
      OR (
        object_row.bucket_id = 'content-studio-drafts'
        AND array_length(string_to_array(object_row.name, '/'), 1) = 4
        AND lower(split_part(object_row.name, '/', 1)) = v_user_text
        AND split_part(object_row.name, '/', 2) = 'drafts'
      )
    )
  ON CONFLICT (bucket, object_path) DO UPDATE
  SET
    user_id = EXCLUDED.user_id,
    resolved_at = NULL,
    locked_at = NULL,
    lock_token = NULL,
    last_error_code = NULL
  WHERE moderation_private.account_media_cleanup.resolved_at IS NOT NULL;

  GET DIAGNOSTICS v_enqueued = ROW_COUNT;
  RETURN v_enqueued;
END;
$$;

-- Erase original direct/group content before the account profile is
-- de-identified.  Updating an image message deliberately uses OLD metadata so
-- the established triggers enqueue its exact chat-media object.  Linked cards
-- and quotes in other users' messages are also tombstoned when they expose a
-- deleted post or one of the deleted account's messages.
CREATE OR REPLACE FUNCTION moderation_private.erase_account_chat_content(
  p_user_id UUID,
  p_post_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_direct_message_ids UUID[] := ARRAY[]::UUID[];
  v_group_message_ids UUID[] := ARRAY[]::UUID[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Include every message written by the account plus any message that
  -- contains a card or lifecycle event for a post owned by it.  Card messages
  -- have copies of post text/image metadata, so hiding only the source post is
  -- insufficient.
  SELECT COALESCE(array_agg(DISTINCT message.id), ARRAY[]::UUID[])
  INTO v_direct_message_ids
  FROM public.messages AS message
  WHERE message.sender_id = p_user_id
     OR EXISTS (
       SELECT 1
       FROM unnest(COALESCE(p_post_ids, ARRAY[]::UUID[])) AS deleted_post(id)
       WHERE deleted_post.id::TEXT IN (
         message.metadata -> 'shared_post_card' ->> 'post_id',
         message.metadata -> 'post_contact_card' ->> 'post_id',
         message.metadata -> 'secondhand_transaction_event' ->> 'listing_id'
       )
     );

  SELECT COALESCE(array_agg(DISTINCT message.id), ARRAY[]::UUID[])
  INTO v_group_message_ids
  FROM public.group_messages AS message
  WHERE message.sender_id = p_user_id
     OR EXISTS (
       SELECT 1
       FROM unnest(COALESCE(p_post_ids, ARRAY[]::UUID[])) AS deleted_post(id)
       WHERE deleted_post.id::TEXT IN (
         message.metadata -> 'shared_post_card' ->> 'post_id',
         message.metadata -> 'post_contact_card' ->> 'post_id',
         message.metadata -> 'secondhand_transaction_event' ->> 'listing_id'
       )
     );

  -- Moderation reports and outstanding notifications can themselves contain
  -- user-entered text or previews.  Remove account-owned/affected copies
  -- before the source rows become tombstones.
  DELETE FROM public.message_reports AS report
  WHERE report.reporter_id = p_user_id
     OR report.direct_message_id = ANY(v_direct_message_ids)
     OR report.group_message_id = ANY(v_group_message_ids);

  DELETE FROM public.hidden_chat_messages AS hidden
  WHERE hidden.user_id = p_user_id
     OR hidden.direct_message_id = ANY(v_direct_message_ids)
     OR hidden.group_message_id = ANY(v_group_message_ids);

  DELETE FROM public.push_notification_jobs AS job
  WHERE job.recipient_user_id = p_user_id
     OR job.payload ->> 'sender_id' = p_user_id::TEXT
     OR job.payload ->> 'actor_user_id' = p_user_id::TEXT
     OR job.payload ->> 'message_id' IN (
       SELECT message_id::TEXT
       FROM unnest(v_direct_message_ids || v_group_message_ids)
         AS deleted_message(message_id)
     );

  -- Quotations retain a bounded source preview in JSON.  Preserve the quoting
  -- user's surrounding message but remove that copied preview.
  UPDATE public.messages AS message
  SET metadata = COALESCE(message.metadata, '{}'::JSONB) - 'quoted_message'
  WHERE message.metadata -> 'quoted_message' ->> 'message_id' IN (
    SELECT message_id::TEXT
    FROM unnest(v_direct_message_ids || v_group_message_ids)
      AS deleted_message(message_id)
  );

  UPDATE public.group_messages AS message
  SET metadata = COALESCE(message.metadata, '{}'::JSONB) - 'quoted_message'
  WHERE message.metadata -> 'quoted_message' ->> 'message_id' IN (
    SELECT message_id::TEXT
    FROM unnest(v_direct_message_ids || v_group_message_ids)
      AS deleted_message(message_id)
  );

  -- Retain only a structure-preserving tombstone.  This also removes copied
  -- card metadata from messages sent by another participant about this
  -- account's post.  For image rows, the chat cleanup trigger reads OLD data
  -- and queues the actual object path.
  UPDATE public.messages AS message
  SET
    content = '[Deleted account content]',
    message_type = 'text',
    metadata = '{}'::JSONB,
    is_deleted = TRUE
  WHERE message.id = ANY(v_direct_message_ids);

  UPDATE public.group_messages AS message
  SET
    content = '[Deleted account content]',
    message_type = 'text',
    metadata = '{}'::JSONB,
    is_deleted = TRUE
  WHERE message.id = ANY(v_group_message_ids);

  -- Conversation list previews are a separate durable text copy.  Rebuild
  -- them from visible messages so an erased final message cannot remain in an
  -- inbox preview, and recompute unread counts after removing the account's
  -- deliveries.
  WITH affected AS (
    SELECT DISTINCT message.conversation_id
    FROM public.messages AS message
    WHERE message.id = ANY(v_direct_message_ids)
  ), state AS (
    SELECT
      conversation.id,
      (
        SELECT message.content
        FROM public.messages AS message
        WHERE message.conversation_id = conversation.id
          AND COALESCE(message.is_deleted, FALSE) = FALSE
        ORDER BY message.created_at DESC, message.id DESC
        LIMIT 1
      ) AS last_message_preview,
      COALESCE(
        (
          SELECT message.created_at
          FROM public.messages AS message
          WHERE message.conversation_id = conversation.id
            AND COALESCE(message.is_deleted, FALSE) = FALSE
          ORDER BY message.created_at DESC, message.id DESC
          LIMIT 1
        ),
        conversation.created_at
      ) AS last_message_at,
      (
        SELECT COUNT(*)::INTEGER
        FROM public.messages AS message
        WHERE message.conversation_id = conversation.id
          AND message.sender_id = conversation.user2_id
          AND COALESCE(message.is_read, FALSE) = FALSE
          AND COALESCE(message.is_deleted, FALSE) = FALSE
      ) AS user1_unread_count,
      (
        SELECT COUNT(*)::INTEGER
        FROM public.messages AS message
        WHERE message.conversation_id = conversation.id
          AND message.sender_id = conversation.user1_id
          AND COALESCE(message.is_read, FALSE) = FALSE
          AND COALESCE(message.is_deleted, FALSE) = FALSE
      ) AS user2_unread_count
    FROM public.conversations AS conversation
    JOIN affected ON affected.conversation_id = conversation.id
  )
  UPDATE public.conversations AS conversation
  SET
    last_message_preview = state.last_message_preview,
    last_message_at = state.last_message_at,
    user1_unread_count = state.user1_unread_count,
    user2_unread_count = state.user2_unread_count,
    updated_at = NOW()
  FROM state
  WHERE conversation.id = state.id;
END;
$$;

-- Delete account-linked public content, derivative records, activity, and
-- delivery copies.  The profile itself remains as a de-identified tombstone so
-- foreign keys can preserve conversation structure without preserving UGC.
CREATE OR REPLACE FUNCTION moderation_private.erase_account_ugc(
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_post_ids UUID[] := ARRAY[]::UUID[];
  v_comment_ids UUID[] := ARRAY[]::UUID[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  -- A suspended user may still delete their account.  Remove the suspension
  -- before writing content-free tombstones because the UGC safety trigger
  -- correctly rejects ordinary writes from suspended accounts.
  DELETE FROM moderation_private.suspensions
  WHERE user_id = p_user_id;

  SELECT COALESCE(array_agg(post_row.id), ARRAY[]::UUID[])
  INTO v_post_ids
  FROM public.posts AS post_row
  WHERE post_row.user_id = p_user_id;

  SELECT COALESCE(array_agg(comment_row.id), ARRAY[]::UUID[])
  INTO v_comment_ids
  FROM public.comments AS comment_row
  WHERE comment_row.user_id = p_user_id;

  PERFORM moderation_private.erase_account_chat_content(p_user_id, v_post_ids);

  DELETE FROM public.comment_reports AS report
  WHERE report.reporter_id = p_user_id
     OR report.comment_id = ANY(v_comment_ids);

  DELETE FROM public.post_reports AS report
  WHERE report.reporter_id = p_user_id
     OR report.post_id = ANY(v_post_ids);

  DELETE FROM public.system_messages AS message
  WHERE message.recipient_user_id = p_user_id
     OR message.actor_user_id = p_user_id
     OR message.post_id = ANY(v_post_ids)
     OR message.comment_id = ANY(v_comment_ids);

  DELETE FROM public.push_notification_jobs AS job
  WHERE job.recipient_user_id = p_user_id
     OR job.payload ->> 'actor_user_id' = p_user_id::TEXT
     OR job.payload ->> 'sender_id' = p_user_id::TEXT
     OR job.payload ->> 'post_id' IN (
       SELECT post_id::TEXT FROM unnest(v_post_ids) AS deleted_post(post_id)
     )
     OR job.payload ->> 'related_post_id' IN (
       SELECT post_id::TEXT FROM unnest(v_post_ids) AS deleted_post(post_id)
     )
     OR job.payload ->> 'source_post_id' IN (
       SELECT post_id::TEXT FROM unnest(v_post_ids) AS deleted_post(post_id)
     )
     OR job.payload ->> 'comment_id' IN (
       SELECT comment_id::TEXT
       FROM unnest(v_comment_ids) AS deleted_comment(comment_id)
     );

  DELETE FROM public.content_mentions AS mention
  WHERE mention.actor_user_id = p_user_id
     OR mention.mentioned_user_id = p_user_id
     OR mention.post_id = ANY(v_post_ids)
     OR mention.comment_id = ANY(v_comment_ids);

  DELETE FROM public.cheese_ai_interactions AS interaction
  WHERE interaction.source_author_id = p_user_id
     OR interaction.ai_user_id = p_user_id
     OR interaction.post_id = ANY(v_post_ids)
     OR interaction.source_comment_id = ANY(v_comment_ids)
     OR interaction.output_comment_id = ANY(v_comment_ids);

  DELETE FROM public.secondhand_purchase_intents AS intent
  WHERE intent.seller_id = p_user_id
     OR intent.buyer_id = p_user_id
     OR intent.listing_id = ANY(v_post_ids);

  DELETE FROM public.likes AS like_row
  WHERE like_row.user_id = p_user_id
     OR (like_row.target_type = 'post' AND like_row.target_id = ANY(v_post_ids))
     OR (like_row.target_type = 'comment' AND like_row.target_id = ANY(v_comment_ids));

  DELETE FROM public.favorites AS favorite
  WHERE favorite.user_id = p_user_id
     OR favorite.post_id = ANY(v_post_ids);

  DELETE FROM public.view_history AS history
  WHERE history.user_id = p_user_id
     OR history.post_id = ANY(v_post_ids);

  DELETE FROM public.user_hidden_forum_posts AS hidden
  WHERE hidden.user_id = p_user_id
     OR hidden.post_id = ANY(v_post_ids);

  DELETE FROM public.user_post_signal_state AS signal
  WHERE signal.user_id = p_user_id
     OR signal.post_id = ANY(v_post_ids);

  DELETE FROM public.recommendation_events AS event
  WHERE event.user_id = p_user_id
     OR event.post_id = ANY(v_post_ids);

  DELETE FROM public.feed_sessions
  WHERE user_id = p_user_id;

  DELETE FROM public.user_interest_profiles
  WHERE user_id = p_user_id;

  DELETE FROM public.user_feedback
  WHERE user_id = p_user_id;

  DELETE FROM public.user_chat_group_settings
  WHERE user_id = p_user_id;

  DELETE FROM public.user_conversation_settings
  WHERE user_id = p_user_id;

  DELETE FROM public.user_blocks
  WHERE blocker_id = p_user_id
     OR blocked_id = p_user_id;

  DELETE FROM public.user_reports
  WHERE reporter_id = p_user_id
     OR reported_user_id = p_user_id;

  DELETE FROM public.user_follows
  WHERE follower_id = p_user_id
     OR following_id = p_user_id;

  DELETE FROM public.user_push_tokens
  WHERE user_id = p_user_id;

  DELETE FROM public.user_notification_preferences
  WHERE user_id = p_user_id;

  DELETE FROM public.ai_processing_consents
  WHERE user_id = p_user_id;

  DELETE FROM public.mcmaster_email_challenges
  WHERE user_id = p_user_id;

  DELETE FROM public.mcmaster_student_verifications
  WHERE user_id = p_user_id;

  DELETE FROM public.post_media_staging
  WHERE owner_id = p_user_id;

  DELETE FROM public.moderated_media
  WHERE user_id = p_user_id;

  DELETE FROM public.content_studio_drafts
  WHERE user_id = p_user_id;

  UPDATE public.content_studio_roles
  SET granted_by = NULL
  WHERE granted_by = p_user_id;
  DELETE FROM public.content_studio_roles
  WHERE user_id = p_user_id;

  DELETE FROM public.forum_board_memberships
  WHERE user_id = p_user_id;
  DELETE FROM public.forum_admins
  WHERE user_id = p_user_id;
  UPDATE public.forum_boards
  SET created_by = NULL
  WHERE created_by = p_user_id;

  DELETE FROM school_selection_private.mcmaster_backfill_backup
  WHERE user_id = p_user_id;

  -- Do not hard-delete comments: parent_id uses ON DELETE CASCADE, which would
  -- erase other users' replies.  The row is kept only as a content-free,
  -- de-identified thread tombstone.
  UPDATE public.comments AS comment_row
  SET
    content = '[Deleted account content]',
    is_deleted = TRUE,
    is_anonymous = TRUE,
    author_is_deactivated = TRUE,
    updated_at = NOW()
  WHERE comment_row.user_id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION moderation_private.enqueue_account_media_cleanup(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION moderation_private.erase_account_chat_content(UUID, UUID[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION moderation_private.erase_account_ugc(UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_group_id UUID;
  v_now TIMESTAMPTZ := NOW();
  v_tombstone_email TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Store exact, retryable deletion obligations before rows or memberships can
  -- disappear.  This includes unreferenced upload/staging objects as well as
  -- media attached to posts and messages.
  PERFORM moderation_private.enqueue_account_media_cleanup(v_user_id);
  PERFORM moderation_private.erase_account_ugc(v_user_id);

  v_tombstone_email := format(
    'deactivated+%s@deleted.cheeseapp.local',
    replace(v_user_id::text, '-', '')
  );

  FOR v_group_id IN
    SELECT gm.group_id
    FROM public.chat_group_members gm
    WHERE gm.user_id = v_user_id
  LOOP
    BEGIN
      PERFORM public.leave_chat_group(v_group_id);
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.chat_group_members
      WHERE group_id = v_group_id
        AND user_id = v_user_id;
    END;
  END LOOP;

  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  UPDATE public.profiles
  SET
    email = v_tombstone_email,
    full_name = '已注销',
    avatar_url = NULL,
    cover_image_url = NULL, phone = NULL, student_id = NULL, major = NULL,
    wechat_id = NULL, gender = NULL, occupation = NULL, grad_year = NULL,
    school_id = NULL, campus_id = NULL, is_mcmaster_verified = FALSE,
    university = '已注销',
    bio = '此账号已注销',
    verified = FALSE,
    is_anonymous = FALSE,
    deactivated_at = v_now,
    updated_at = v_now
  WHERE id = v_user_id;

  UPDATE auth.users
  SET
    email = v_tombstone_email,
    phone = NULL,
    banned_until = v_now + INTERVAL '100 years',
    updated_at = v_now,
    email_change='',phone_change='',confirmation_token='',recovery_token='',
    email_change_token_new='',email_change_token_current='',phone_change_token='',reauthentication_token='',
    encrypted_password = '',
    raw_app_meta_data = '{}'::jsonb,
    raw_user_meta_data = jsonb_build_object('deactivated_at', v_now)
  WHERE id = v_user_id;

  DELETE FROM auth.sessions
  WHERE user_id = v_user_id;

  DELETE FROM auth.identities
  WHERE user_id = v_user_id;

  DELETE FROM auth.mfa_factors WHERE user_id = v_user_id;
  DELETE FROM auth.one_time_tokens WHERE user_id = v_user_id;
  RETURN TRUE;
END;
$$;

-- Backfill UGC and account-state erasure for previously deactivated accounts,
-- then retain retry obligations for every known Storage object.  Legacy
-- URL-only objects without an owner or feature-owned path are still not
-- guessed at; they remain an operational reconciliation case.
SELECT moderation_private.erase_account_ugc(profile.id)
FROM public.profiles AS profile
WHERE profile.deactivated_at IS NOT NULL;

SELECT moderation_private.enqueue_account_media_cleanup(profile.id)
FROM public.profiles AS profile
WHERE profile.deactivated_at IS NOT NULL;

-- Match current deletion semantics for historic account tombstones: an owner
-- disbands a group and a member is removed.  Group-message delete triggers
-- retain their own exact Storage cleanup obligations for images owned by other
-- members.
DELETE FROM public.chat_groups AS group_row
USING public.profiles AS profile
WHERE group_row.owner_id = profile.id
  AND profile.deactivated_at IS NOT NULL;

DELETE FROM public.chat_group_members AS member
USING public.profiles AS profile
WHERE member.user_id = profile.id
  AND profile.deactivated_at IS NOT NULL;

DELETE FROM auth.sessions
WHERE user_id IN (
  SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL
);

DELETE FROM auth.identities
WHERE user_id IN (
  SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL
);

DELETE FROM auth.mfa_factors
WHERE user_id IN (
  SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL
);

DELETE FROM auth.one_time_tokens
WHERE user_id IN (
  SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL
);

NOTIFY pgrst, 'reload schema';

COMMIT;
