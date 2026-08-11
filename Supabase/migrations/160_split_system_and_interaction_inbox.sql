-- Split the durable system_messages timeline into two inbox surfaces without
-- duplicating notification storage or changing event producers.
--
-- system: platform notices and second-hand lifecycle reminders
-- interaction: comments, replies, mentions, likes and follows

BEGIN;

CREATE OR REPLACE FUNCTION public.get_system_messages_page_by_category(
  p_category TEXT,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 30
)
RETURNS TABLE (
  id UUID,
  event_id TEXT,
  kind TEXT,
  title TEXT,
  body TEXT,
  actor_user_id UUID,
  actor_name TEXT,
  actor_avatar_url TEXT,
  post_id UUID,
  comment_id UUID,
  content_kind TEXT,
  cta_kind TEXT,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
  SELECT
    message.id,
    message.event_id,
    message.kind,
    message.title,
    message.body,
    message.actor_user_id,
    CASE
      WHEN message.actor_user_id IS NULL THEN NULL
      ELSE COALESCE(NULLIF(btrim(actor.full_name), ''), '用户')
    END,
    actor.avatar_url,
    message.post_id,
    message.comment_id,
    message.content_kind,
    message.cta_kind,
    message.read_at,
    message.created_at
  FROM public.system_messages message
  LEFT JOIN public.profiles actor
    ON actor.id = message.actor_user_id
   AND NOT public.is_user_blocked(auth.uid(), actor.id)
  WHERE auth.uid() IS NOT NULL
    AND message.recipient_user_id = auth.uid()
    AND (
      (p_category = 'system'
        AND message.kind IN ('automatic', 'secondhand_availability'))
      OR
      (p_category = 'interaction'
        AND message.kind IN (
          'mention',
          'post_like',
          'comment_like',
          'post_comment',
          'comment_reply',
          'follow'
        ))
    )
    AND (
      p_before_created_at IS NULL
      OR (
        p_before_id IS NOT NULL
        AND (message.created_at, message.id)
          < (p_before_created_at, p_before_id)
      )
    )
  ORDER BY message.created_at DESC, message.id DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
$$;

CREATE OR REPLACE FUNCTION public.get_system_message_inbox_summaries()
RETURNS TABLE (
  category TEXT,
  latest_title TEXT,
  latest_body TEXT,
  latest_created_at TIMESTAMPTZ,
  unread_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  WITH categories(category, sort_order) AS (
    VALUES
      ('system'::TEXT, 1),
      ('interaction'::TEXT, 2)
  )
  SELECT
    category_row.category,
    latest_message.title,
    latest_message.body,
    latest_message.created_at,
    COALESCE(unread.total, 0)::INTEGER
  FROM categories category_row
  LEFT JOIN LATERAL (
    SELECT message.title, message.body, message.created_at
    FROM public.system_messages message
    WHERE message.recipient_user_id = auth.uid()
      AND (
        (category_row.category = 'system'
          AND message.kind IN ('automatic', 'secondhand_availability'))
        OR
        (category_row.category = 'interaction'
          AND message.kind IN (
            'mention',
            'post_like',
            'comment_like',
            'post_comment',
            'comment_reply',
            'follow'
          ))
      )
    ORDER BY message.created_at DESC, message.id DESC
    LIMIT 1
  ) latest_message ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::INTEGER AS total
    FROM public.system_messages message
    WHERE message.recipient_user_id = auth.uid()
      AND message.read_at IS NULL
      AND (
        (category_row.category = 'system'
          AND message.kind IN ('automatic', 'secondhand_availability'))
        OR
        (category_row.category = 'interaction'
          AND message.kind IN (
            'mention',
            'post_like',
            'comment_like',
            'post_comment',
            'comment_reply',
            'follow'
          ))
      )
  ) unread ON TRUE
  WHERE auth.uid() IS NOT NULL
  ORDER BY category_row.sort_order;
$$;

CREATE OR REPLACE FUNCTION public.mark_all_system_messages_read_by_category(
  p_category TEXT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF p_category NOT IN ('system', 'interaction') THEN
    RAISE EXCEPTION 'Unsupported system message category: %', p_category
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.system_messages message
  SET read_at = clock_timestamp()
  WHERE message.recipient_user_id = auth.uid()
    AND message.read_at IS NULL
    AND (
      (p_category = 'system'
        AND message.kind IN ('automatic', 'secondhand_availability'))
      OR
      (p_category = 'interaction'
        AND message.kind IN (
          'mention',
          'post_like',
          'comment_like',
          'post_comment',
          'comment_reply',
          'follow'
        ))
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.get_system_messages_page_by_category(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_system_message_inbox_summaries()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_all_system_messages_read_by_category(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_system_messages_page_by_category(
  TEXT, TIMESTAMPTZ, UUID, INTEGER
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_system_message_inbox_summaries()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_system_messages_read_by_category(TEXT)
  TO authenticated;

COMMIT;
