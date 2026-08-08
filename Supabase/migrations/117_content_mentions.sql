-- 117_content_mentions.sql
-- Stable-ID mentions for Forum, Rent, Secondhand, and supported comments.
--
-- The client supplies selected profile UUIDs. The database never infers an
-- identity from display text and only the content author can synchronize the
-- mention set. Private content never emits mention notifications.

BEGIN;

CREATE TABLE public.content_mentions (
  id UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  content_kind TEXT NOT NULL CHECK (
    content_kind IN ('forum', 'rent', 'secondhand', 'comment')
  ),
  post_id UUID NOT NULL
    REFERENCES public.posts(id) ON DELETE CASCADE,
  comment_id UUID
    REFERENCES public.comments(id) ON DELETE CASCADE,
  actor_user_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  mentioned_user_id UUID NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT content_mentions_not_self CHECK (
    actor_user_id <> mentioned_user_id
  ),
  CONSTRAINT content_mentions_shape_check CHECK (
    (content_kind = 'comment' AND comment_id IS NOT NULL)
    OR (content_kind <> 'comment' AND comment_id IS NULL)
  )
);

CREATE UNIQUE INDEX content_mentions_identity_unique
  ON public.content_mentions (
    content_kind,
    post_id,
    COALESCE(
      comment_id,
      '00000000-0000-0000-0000-000000000000'::UUID
    ),
    mentioned_user_id
  );

CREATE INDEX content_mentions_recipient_idx
  ON public.content_mentions (
    mentioned_user_id,
    created_at DESC,
    id DESC
  );

ALTER TABLE public.content_mentions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.content_mentions
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.content_mentions
  TO service_role;

CREATE OR REPLACE FUNCTION public.sync_content_mentions(
  p_content_kind TEXT,
  p_post_id UUID,
  p_comment_id UUID DEFAULT NULL,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_kind TEXT := lower(btrim(COALESCE(p_content_kind, '')));
  v_post public.posts%ROWTYPE;
  v_comment public.comments%ROWTYPE;
  v_is_anonymous BOOLEAN := FALSE;
  v_inserted INTEGER := 0;
  v_target UUID;
  v_actor_name TEXT;
  v_event_id TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF v_kind NOT IN ('forum', 'rent', 'secondhand', 'comment') THEN
    RAISE EXCEPTION 'Unsupported mention content kind'
      USING ERRCODE = '22023';
  END IF;

  IF COALESCE(cardinality(p_mentioned_user_ids), 0) > 10 THEN
    RAISE EXCEPTION 'At most 10 users can be mentioned'
      USING ERRCODE = '22023';
  END IF;

  SELECT post_row.*
  INTO v_post
  FROM public.posts post_row
  WHERE post_row.id = p_post_id
    AND post_row.type IN ('forum', 'rent', 'secondhand')
    AND post_row.status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mentioned content is unavailable'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_kind = 'comment' THEN
    IF p_comment_id IS NULL THEN
      RAISE EXCEPTION 'Comment ID is required'
        USING ERRCODE = '22023';
    END IF;

    SELECT comment_row.*
    INTO v_comment
    FROM public.comments comment_row
    WHERE comment_row.id = p_comment_id
      AND comment_row.post_id = p_post_id
      AND comment_row.is_deleted = FALSE;

    IF NOT FOUND OR v_comment.user_id IS DISTINCT FROM v_me THEN
      RAISE EXCEPTION 'Only the comment author can set mentions'
        USING ERRCODE = '42501';
    END IF;

    v_is_anonymous := COALESCE(v_comment.is_anonymous, FALSE);
  ELSE
    IF p_comment_id IS NOT NULL
       OR v_post.type IS DISTINCT FROM v_kind
       OR v_post.user_id IS DISTINCT FROM v_me
    THEN
      RAISE EXCEPTION 'Only the content author can set mentions'
        USING ERRCODE = '42501';
    END IF;

    v_is_anonymous := COALESCE(v_post.is_anonymous, FALSE);
  END IF;

  DELETE FROM public.content_mentions mention
  WHERE mention.content_kind = v_kind
    AND mention.post_id = p_post_id
    AND mention.comment_id IS NOT DISTINCT FROM p_comment_id
    AND mention.actor_user_id = v_me
    AND NOT (
      mention.mentioned_user_id = ANY(
        COALESCE(p_mentioned_user_ids, ARRAY[]::UUID[])
      )
    );

  IF v_post.is_private THEN
    DELETE FROM public.content_mentions mention
    WHERE mention.content_kind = v_kind
      AND mention.post_id = p_post_id
      AND mention.comment_id IS NOT DISTINCT FROM p_comment_id
      AND mention.actor_user_id = v_me;
    RETURN 0;
  END IF;

  SELECT COALESCE(NULLIF(btrim(profile.full_name), ''), '有人')
  INTO v_actor_name
  FROM public.profiles profile
  WHERE profile.id = v_me;

  FOR v_target IN
    SELECT DISTINCT target_id
    FROM unnest(
      COALESCE(p_mentioned_user_ids, ARRAY[]::UUID[])
    ) AS target(target_id)
    WHERE target_id IS NOT NULL
      AND target_id <> v_me
    ORDER BY target_id
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM public.profiles profile
      WHERE profile.id = v_target
    )
    OR EXISTS (
      SELECT 1
      FROM public.user_blocks block_row
      WHERE (
        block_row.blocker_id = v_me
        AND block_row.blocked_id = v_target
      )
      OR (
        block_row.blocker_id = v_target
        AND block_row.blocked_id = v_me
      )
    )
    THEN
      CONTINUE;
    END IF;

    INSERT INTO public.content_mentions (
      content_kind,
      post_id,
      comment_id,
      actor_user_id,
      mentioned_user_id
    )
    VALUES (
      v_kind,
      p_post_id,
      p_comment_id,
      v_me,
      v_target
    )
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_inserted := v_inserted + 1;
    v_event_id := format(
      'mention:%s:%s:%s',
      v_kind,
      COALESCE(p_comment_id, p_post_id),
      v_target
    );

    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_target,
      p_event_id := v_event_id,
      p_kind := 'mention',
      p_title := '有人提到了你',
      p_body := CASE
        WHEN v_is_anonymous
          THEN format(
            '匿名用户在「%s」中提到了你',
            COALESCE(
              NULLIF(left(btrim(v_post.title), 60), ''),
              '一则内容'
            )
          )
        ELSE format(
          '%s 在「%s」中提到了你',
          COALESCE(v_actor_name, '有人'),
          COALESCE(
            NULLIF(left(btrim(v_post.title), 60), ''),
            '一则内容'
          )
        )
      END,
      p_actor_user_id := v_me,
      p_post_id := p_post_id,
      p_comment_id := p_comment_id,
      p_content_kind := CASE
        WHEN v_kind = 'comment' THEN 'comment'
        ELSE v_kind
      END,
      p_cta_kind := 'view_post',
      p_hide_actor := v_is_anonymous
    );
  END LOOP;

  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_content_mentions(
  TEXT, UUID, UUID, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sync_content_mentions(
  TEXT, UUID, UUID, UUID[]
) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_content_mentions(
  p_post_id UUID,
  p_comment_id UUID DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  avatar_url TEXT,
  university TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT DISTINCT
    profile.id,
    COALESCE(NULLIF(btrim(profile.full_name), ''), '用户'),
    profile.avatar_url,
    profile.university
  FROM public.content_mentions mention
  JOIN public.profiles profile
    ON profile.id = mention.mentioned_user_id
  WHERE auth.uid() IS NOT NULL
    AND mention.post_id = p_post_id
    AND mention.comment_id IS NOT DISTINCT FROM p_comment_id
    AND public.can_view_post(p_post_id)
    AND NOT public.is_user_blocked(auth.uid(), profile.id)
  ORDER BY 2, 1;
$$;

REVOKE ALL ON FUNCTION public.get_content_mentions(UUID, UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_content_mentions(UUID, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.create_forum_comment_with_mentions(
  p_comment_id UUID,
  p_post_id UUID,
  p_content TEXT,
  p_is_anonymous BOOLEAN DEFAULT FALSE,
  p_parent_id UUID DEFAULT NULL,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_content TEXT := btrim(COALESCE(p_content, ''));
  v_forum public.forum_posts%ROWTYPE;
  v_existing public.comments%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF p_comment_id IS NULL
     OR length(v_content) < 1
     OR length(v_content) > 2000
  THEN
    RAISE EXCEPTION 'Comment content must contain 1 to 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  IF COALESCE(cardinality(p_mentioned_user_ids), 0) > 10 THEN
    RAISE EXCEPTION 'At most 10 users can be mentioned'
      USING ERRCODE = '22023';
  END IF;

  SELECT detail.*
  INTO v_forum
  FROM public.forum_posts detail
  JOIN public.posts post_row
    ON post_row.id = detail.id
  WHERE detail.id = p_post_id
    AND post_row.type = 'forum'
    AND post_row.status = 'active'
    AND detail.allow_comments = TRUE
    AND detail.is_locked = FALSE
    AND public.can_view_post(post_row.id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This post is unavailable for comments'
      USING ERRCODE = '42501';
  END IF;

  IF p_parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.comments parent
    WHERE parent.id = p_parent_id
      AND parent.post_id = p_post_id
      AND parent.is_deleted = FALSE
  ) THEN
    RAISE EXCEPTION 'Reply target is unavailable'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.comments (
    id,
    post_id,
    user_id,
    parent_id,
    content,
    is_anonymous
  )
  VALUES (
    p_comment_id,
    p_post_id,
    v_me,
    p_parent_id,
    v_content,
    COALESCE(p_is_anonymous, FALSE)
  )
  ON CONFLICT (id) DO NOTHING;

  SELECT comment_row.*
  INTO v_existing
  FROM public.comments comment_row
  WHERE comment_row.id = p_comment_id;

  IF NOT FOUND
     OR v_existing.post_id IS DISTINCT FROM p_post_id
     OR v_existing.user_id IS DISTINCT FROM v_me
     OR v_existing.parent_id IS DISTINCT FROM p_parent_id
     OR v_existing.content IS DISTINCT FROM v_content
     OR v_existing.is_anonymous IS DISTINCT FROM
        COALESCE(p_is_anonymous, FALSE)
     OR v_existing.is_deleted = TRUE
  THEN
    RAISE EXCEPTION 'Comment request ID conflicts with existing content'
      USING ERRCODE = '23505';
  END IF;

  PERFORM public.sync_content_mentions(
    'comment',
    p_post_id,
    p_comment_id,
    p_mentioned_user_ids
  );

  RETURN p_comment_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_forum_comment_with_mentions(
  UUID, UUID, TEXT, BOOLEAN, UUID, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_forum_comment_with_mentions(
  UUID, UUID, TEXT, BOOLEAN, UUID, UUID[]
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
