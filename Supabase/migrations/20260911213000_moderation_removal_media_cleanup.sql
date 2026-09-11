-- Removed or suspended UGC must stop being publicly retrievable, including
-- direct public Storage URLs. This migration reuses the durable post and account
-- media cleanup queues; it does not grant clients direct Storage access.
--
-- Destructive behavior: newly suspended accounts lose public profile media and
-- their posts are hidden. Matching public avatar and post objects are queued for
-- retryable service-worker deletion. Previously suspended accounts receive the
-- same remediation. Back up the database and Storage before production rollout;
-- objects deleted by the worker are not restored by rolling this migration back.
--
-- Production order: deploy the share worker with media cleanup enabled, apply
-- this migration, then verify all moderation cleanup queues drain successfully.

BEGIN;

CREATE OR REPLACE FUNCTION moderation_private.require_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL
     OR EXISTS (
       SELECT 1
       FROM moderation_private.suspensions AS suspension
       WHERE suspension.user_id = auth.uid()
     )
     OR NOT EXISTS (
       SELECT 1
       FROM public.content_studio_roles AS role_row
       JOIN public.profiles AS profile ON profile.id = role_row.user_id
       WHERE role_row.user_id = auth.uid()
         AND role_row.role = 'admin'
         AND profile.deactivated_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'moderation_access_denied' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION moderation_private.enqueue_post_media_cleanup(
  p_post_id uuid,
  p_owner_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  image_row record;
BEGIN
  IF p_post_id IS NULL
     OR p_owner_id IS NULL
     OR p_reason IS NULL
     OR p_reason NOT IN ('moderation_post_removed', 'moderation_user_suspended')
  THEN
    RAISE EXCEPTION 'invalid_moderation_media_cleanup';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.posts AS post_row
    WHERE post_row.id = p_post_id
      AND post_row.user_id = p_owner_id
  ) THEN
    RAISE EXCEPTION 'moderation_post_owner_mismatch';
  END IF;

  FOR image_row IN
    SELECT image.id, image.bucket, image.object_path, image.url
    FROM public.post_images AS image
    WHERE image.post_id = p_post_id
    FOR UPDATE
  LOOP
    IF image_row.bucket IS NOT NULL AND image_row.object_path IS NOT NULL THEN
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id,
        post_image_id,
        post_id,
        bucket,
        object_path,
        stored_url,
        status,
        reason
      )
      VALUES (
        p_owner_id,
        image_row.id,
        p_post_id,
        image_row.bucket,
        image_row.object_path,
        image_row.url,
        'pending',
        p_reason
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO UPDATE SET
        status = 'pending',
        reason = EXCLUDED.reason,
        bucket = EXCLUDED.bucket,
        object_path = EXCLUDED.object_path,
        stored_url = EXCLUDED.stored_url,
        candidate_count = EXCLUDED.candidate_count,
        locked_at = NULL,
        lock_token = NULL,
        resolved_at = NULL;
    ELSE
      INSERT INTO public.post_media_cleanup_backlog (
        owner_id,
        post_image_id,
        post_id,
        stored_url,
        status,
        reason,
        candidate_count
      )
      VALUES (
        p_owner_id,
        image_row.id,
        p_post_id,
        image_row.url,
        'unresolved',
        COALESCE(
          (
            SELECT reconciliation.reason
            FROM public.post_image_reconciliation_backlog AS reconciliation
            WHERE reconciliation.post_image_id = image_row.id
          ),
          'legacy_object_path_unresolved'
        ),
        COALESCE(
          (
            SELECT reconciliation.candidate_count
            FROM public.post_image_reconciliation_backlog AS reconciliation
            WHERE reconciliation.post_image_id = image_row.id
          ),
          0
        )
      )
      ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
      DO NOTHING;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION moderation_private.enqueue_suspension_avatar_cleanup(
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, storage, pg_temp
AS $$
DECLARE
  user_id_text text := lower(p_user_id::text);
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid_suspension_user';
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
  WHERE object_row.bucket_id = 'avatars'
    AND (
      object_row.owner = p_user_id
      OR lower(split_part(object_row.name, '/', 1)) = user_id_text
    )
  ON CONFLICT (bucket, object_path) DO UPDATE
  SET
    user_id = EXCLUDED.user_id,
    resolved_at = NULL,
    locked_at = NULL,
    lock_token = NULL,
    last_error_code = NULL
  WHERE moderation_private.account_media_cleanup.resolved_at IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_resolve(
  p_kind text,
  p_id uuid,
  p_action text,
  p_note text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  report_table text;
  report_row jsonb;
  target_id uuid;
  actor_id uuid;
  new_status text;
  suspended_post_id uuid;
BEGIN
  PERFORM moderation_private.require_admin();

  IF p_action IS NULL
     OR p_note IS NULL
     OR p_action NOT IN ('review', 'dismiss', 'remove', 'suspend')
     OR length(btrim(p_note)) NOT BETWEEN 5 AND 1000
  THEN
    RAISE EXCEPTION 'invalid_moderation_action' USING ERRCODE = '22023';
  END IF;

  report_table := CASE p_kind
    WHEN 'post' THEN 'post_reports'
    WHEN 'comment' THEN 'comment_reports'
    WHEN 'message' THEN 'message_reports'
    WHEN 'user' THEN 'user_reports'
  END;

  IF report_table IS NULL THEN
    RAISE EXCEPTION 'invalid_report_kind';
  END IF;

  EXECUTE format(
    'SELECT to_jsonb(report_row) FROM public.%I AS report_row WHERE id = $1 FOR UPDATE',
    report_table
  )
  INTO report_row
  USING p_id;

  IF report_row IS NULL
     OR report_row ->> 'status' NOT IN ('pending', 'reviewing')
  THEN
    RAISE EXCEPTION 'report_not_open';
  END IF;

  IF p_kind = 'post' THEN
    target_id := (report_row ->> 'post_id')::uuid;
    SELECT post_row.user_id INTO actor_id
    FROM public.posts AS post_row
    WHERE post_row.id = target_id;

    IF p_action = 'remove' THEN
      PERFORM moderation_private.enqueue_post_media_cleanup(
        target_id,
        actor_id,
        'moderation_post_removed'
      );
      UPDATE public.posts
      SET status = 'deleted'
      WHERE id = target_id;
    END IF;
  ELSIF p_kind = 'comment' THEN
    target_id := (report_row ->> 'comment_id')::uuid;
    SELECT comment_row.user_id INTO actor_id
    FROM public.comments AS comment_row
    WHERE comment_row.id = target_id;

    IF p_action = 'remove' THEN
      UPDATE public.comments
      SET is_deleted = TRUE,
          content = '[Removed by moderation]'
      WHERE id = target_id;
    END IF;
  ELSIF p_kind = 'message' THEN
    IF report_row ->> 'direct_message_id' IS NOT NULL THEN
      target_id := (report_row ->> 'direct_message_id')::uuid;
      SELECT message_row.sender_id INTO actor_id
      FROM public.messages AS message_row
      WHERE message_row.id = target_id;

      IF p_action = 'remove' THEN
        -- The established trigger receives OLD metadata and queues its exact
        -- private chat object for deletion.
        UPDATE public.messages
        SET is_deleted = TRUE,
            content = '[Removed by moderation]',
            metadata = '{}'::jsonb
        WHERE id = target_id;
      END IF;
    ELSE
      target_id := (report_row ->> 'group_message_id')::uuid;
      SELECT message_row.sender_id INTO actor_id
      FROM public.group_messages AS message_row
      WHERE message_row.id = target_id;

      IF p_action = 'remove' THEN
        UPDATE public.group_messages
        SET is_deleted = TRUE,
            content = '[Removed by moderation]',
            metadata = '{}'::jsonb
        WHERE id = target_id;
      END IF;
    END IF;
  ELSE
    actor_id := (report_row ->> 'reported_user_id')::uuid;

    IF p_action = 'remove' THEN
      RAISE EXCEPTION 'use_suspend_for_user_report';
    END IF;
  END IF;

  IF p_action = 'suspend' THEN
    IF actor_id IS NULL OR actor_id = auth.uid() THEN
      RAISE EXCEPTION 'invalid_suspension_target';
    END IF;

    INSERT INTO moderation_private.suspensions (
      user_id,
      reviewer_id,
      reason
    )
    VALUES (actor_id, auth.uid(), p_note)
    ON CONFLICT (user_id) DO UPDATE
    SET reviewer_id = EXCLUDED.reviewer_id,
        reason = EXCLUDED.reason;

    -- Public avatar URLs must be queued before profile fields are cleared.
    PERFORM moderation_private.enqueue_suspension_avatar_cleanup(actor_id);

    FOR suspended_post_id IN
      SELECT post_row.id
      FROM public.posts AS post_row
      WHERE post_row.user_id = actor_id
    LOOP
      PERFORM moderation_private.enqueue_post_media_cleanup(
        suspended_post_id,
        actor_id,
        'moderation_user_suspended'
      );
    END LOOP;

    UPDATE public.posts
    SET status = 'deleted'
    WHERE user_id = actor_id
      AND status <> 'deleted';

    UPDATE public.profiles
    SET avatar_url = NULL,
        cover_image_url = NULL,
        updated_at = NOW()
    WHERE id = actor_id;

    UPDATE auth.users
    SET banned_until = NOW() + INTERVAL '100 years'
    WHERE auth.users.id = actor_id;

    DELETE FROM auth.sessions
    WHERE user_id = actor_id;
  END IF;

  new_status := CASE p_action
    WHEN 'review' THEN 'reviewing'
    WHEN 'dismiss' THEN 'dismissed'
    ELSE 'resolved'
  END;

  EXECUTE format('UPDATE public.%I SET status = $1 WHERE id = $2', report_table)
  USING new_status, p_id;

  INSERT INTO moderation_private.audit_log (
    reviewer_id,
    report_kind,
    report_id,
    action,
    note
  )
  VALUES (auth.uid(), p_kind, p_id, p_action, btrim(p_note));

  RETURN TRUE;
END;
$$;

CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  CASE WHEN profile.show_gender THEN profile.gender ELSE NULL END AS gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::text AS country_name,
  NULL::text AS region,
  NULL::text AS city,
  profile.is_mcmaster_verified,
  profile.show_gender,
  profile.is_graduated,
  profile.public_uid,
  profile.cover_image_url
FROM public.profiles AS profile
WHERE profile.deactivated_at IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM moderation_private.suspensions AS suspension
    WHERE suspension.user_id = profile.id
  )
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks AS block_row
          WHERE block_row.blocker_id = profile.id
            AND block_row.blocked_id = auth.uid()
        )
      )
    )
  );

ALTER VIEW public.profile_public_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.profile_public_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.profile_public_view TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.can_view_post(p_post_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.posts AS post_row
      WHERE post_row.id = p_post_id
        AND post_row.status = 'active'
        AND NOT EXISTS (
          SELECT 1
          FROM moderation_private.suspensions AS suspension
          WHERE suspension.user_id = post_row.user_id
        )
        AND (
          post_row.user_id = auth.uid()
          OR (
            post_row.is_private = FALSE
            AND (
              auth.role() = 'service_role'
              OR NOT public.is_user_blocked(auth.uid(), post_row.user_id)
            )
          )
        )
        AND (
          post_row.type <> 'forum'
          OR EXISTS (
            SELECT 1
            FROM public.forum_posts AS forum_detail
            JOIN public.forum_boards AS board ON board.id = forum_detail.board_id
            WHERE forum_detail.id = post_row.id
              AND board.status <> 'archived'
          )
        )
    );
$$;

DROP POLICY IF EXISTS "Active non-blocked posts are readable" ON public.posts;
CREATE POLICY "Active non-blocked posts are readable"
ON public.posts
FOR SELECT
TO authenticated
USING (
  status = 'active'
  AND NOT EXISTS (
    SELECT 1
    FROM moderation_private.suspensions AS suspension
    WHERE suspension.user_id = posts.user_id
  )
  AND (
    user_id = auth.uid()
    OR (
      type = 'forum'
      AND EXISTS (
        SELECT 1
        FROM public.forum_posts AS forum_detail
        WHERE forum_detail.id = posts.id
          AND public.can_manage_forum_board(forum_detail.board_id, auth.uid())
      )
    )
    OR (
      is_private = FALSE
      AND NOT public.is_user_blocked(auth.uid(), user_id)
      AND (type <> 'forum' OR is_anonymous = FALSE)
    )
  )
);

DO $$
DECLARE
  suspended_account record;
  suspended_post_id uuid;
BEGIN
  FOR suspended_account IN
    SELECT suspension.user_id
    FROM moderation_private.suspensions AS suspension
  LOOP
    PERFORM moderation_private.enqueue_suspension_avatar_cleanup(
      suspended_account.user_id
    );

    FOR suspended_post_id IN
      SELECT post_row.id
      FROM public.posts AS post_row
      WHERE post_row.user_id = suspended_account.user_id
    LOOP
      PERFORM moderation_private.enqueue_post_media_cleanup(
        suspended_post_id,
        suspended_account.user_id,
        'moderation_user_suspended'
      );
    END LOOP;

    UPDATE public.posts
    SET status = 'deleted'
    WHERE user_id = suspended_account.user_id
      AND status <> 'deleted';

    UPDATE public.profiles
    SET avatar_url = NULL,
        cover_image_url = NULL,
        updated_at = NOW()
    WHERE id = suspended_account.user_id;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION moderation_private.enqueue_post_media_cleanup(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION moderation_private.enqueue_suspension_avatar_cleanup(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION moderation_private.require_admin()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_resolve(text, uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.moderation_resolve(text, uuid, text, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.can_view_post(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_post(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
