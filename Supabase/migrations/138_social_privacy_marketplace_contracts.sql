-- 138_social_privacy_marketplace_contracts.sql
-- Follow management, owner-only post hiding, profile privacy, optional gender,
-- and the fixed one-month Marketplace contract.
--
-- Data impact: active Marketplace expiry dates are normalized to one month
-- after creation. This can shorten listings that previously selected a later
-- manual date. Back up production before applying if those dates must be kept.
-- Rollback cannot restore replaced manual expiry dates. Apply the migration
-- before releasing clients that omit p_expires_at and send p_original_price.

BEGIN;

CREATE OR REPLACE FUNCTION public.remove_my_follower(p_follower_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_removed_count INTEGER;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_follower_id IS NULL OR p_follower_id = v_me THEN
    RAISE EXCEPTION 'Invalid follower identity' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.user_follows
  WHERE follower_id = p_follower_id
    AND following_id = v_me;

  GET DIAGNOSTICS v_removed_count = ROW_COUNT;
  RETURN v_removed_count > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_my_follower(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.remove_my_follower(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_my_post_hidden(
  p_post_id UUID,
  p_hidden BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_hidden IS NULL THEN
    RAISE EXCEPTION 'Hidden state is required' USING ERRCODE = '22023';
  END IF;

  UPDATE public.posts
  SET is_private = p_hidden,
      updated_at = clock_timestamp()
  WHERE id = p_post_id
    AND user_id = v_me
    AND type IN ('forum', 'secondhand')
    AND status <> 'deleted';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Post not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  RETURN p_hidden;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_my_post_hidden(UUID, BOOLEAN)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_profile_posts(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  type TEXT,
  title TEXT,
  description TEXT,
  status TEXT,
  is_anonymous BOOLEAN,
  is_private BOOLEAN,
  created_at TIMESTAMPTZ,
  price NUMERIC,
  original_price NUMERIC,
  category TEXT,
  condition TEXT,
  is_negotiable BOOLEAN,
  board_id UUID,
  board_name TEXT,
  allow_comments BOOLEAN,
  user_name TEXT,
  user_avatar TEXT,
  images JSONB
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

  RETURN QUERY
  SELECT
    post_row.id,
    post_row.user_id,
    post_row.type,
    post_row.title,
    COALESCE(post_row.description, ''),
    post_row.status,
    post_row.is_anonymous,
    post_row.is_private,
    post_row.created_at,
    market.price,
    market.original_price,
    market.category,
    market.condition,
    market.is_negotiable,
    forum.board_id,
    board.name,
    forum.allow_comments,
    profile.full_name,
    profile.avatar_url,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', image.id,
            'url', image.url,
            'order_index', image.order_index
          )
          ORDER BY image.order_index, image.id
        )
        FROM public.post_images image
        WHERE image.post_id = post_row.id
      ),
      '[]'::JSONB
    )
  FROM public.posts post_row
  JOIN public.profiles profile ON profile.id = post_row.user_id
  LEFT JOIN public.secondhand_posts market
    ON market.id = post_row.id AND post_row.type = 'secondhand'
  LEFT JOIN public.forum_posts forum
    ON forum.id = post_row.id AND post_row.type = 'forum'
  LEFT JOIN public.forum_boards board ON board.id = forum.board_id
  WHERE post_row.user_id = p_user_id
    AND post_row.type IN ('forum', 'secondhand')
    AND profile.deactivated_at IS NULL
    AND (
      post_row.user_id = v_me
      OR public.can_view_post(post_row.id)
    )
    AND (
      post_row.user_id = v_me
      OR post_row.status = 'active'
    )
    AND post_row.status <> 'deleted'
    AND (
      post_row.type <> 'forum'
      OR post_row.is_anonymous = FALSE
      OR post_row.user_id = v_me
    )
    AND (
      post_row.type <> 'secondhand'
      OR post_row.user_id = v_me
      OR market.expires_at > clock_timestamp()
    )
  ORDER BY post_row.created_at DESC, post_row.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_profile_posts(UUID)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_profile_posts(UUID)
  TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);

CREATE FUNCTION public.complete_profile(
  p_full_name TEXT DEFAULT NULL,
  p_university TEXT DEFAULT NULL,
  p_gender TEXT DEFAULT NULL,
  p_occupation TEXT DEFAULT NULL,
  p_bio TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_gender TEXT := NULLIF(btrim(p_gender), '');
  v_university TEXT := NULLIF(btrim(p_university), '');
  v_row public.profiles;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF v_university IS NULL THEN
    RAISE EXCEPTION 'University is required' USING ERRCODE = '22023';
  END IF;
  IF v_gender IS NOT NULL
     AND v_gender NOT IN ('male', 'female', 'non_binary', 'prefer_not_to_say') THEN
    RAISE EXCEPTION 'Invalid gender' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET full_name = COALESCE(NULLIF(btrim(p_full_name), ''), full_name),
      university = v_university,
      gender = v_gender,
      occupation = NULLIF(btrim(p_occupation), ''),
      bio = COALESCE(NULLIF(btrim(p_bio), ''), bio),
      avatar_url = COALESCE(NULLIF(btrim(p_avatar_url), ''), avatar_url),
      profile_completed = TRUE,
      updated_at = clock_timestamp()
  WHERE id = v_user_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_profile(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS migration_backups;
REVOKE ALL ON SCHEMA migration_backups FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS migration_backups.secondhand_expiry_138 (
  post_id UUID PRIMARY KEY,
  previous_expires_at TIMESTAMPTZ,
  backed_up_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON migration_backups.secondhand_expiry_138
  FROM PUBLIC, anon, authenticated;

INSERT INTO migration_backups.secondhand_expiry_138 (
  post_id,
  previous_expires_at
)
SELECT market.id, market.expires_at
FROM public.secondhand_posts market
JOIN public.posts post_row ON post_row.id = market.id
WHERE post_row.type = 'secondhand'
  AND post_row.status = 'active'
ON CONFLICT (post_id) DO NOTHING;

UPDATE public.secondhand_posts AS market
SET expires_at = post_row.created_at + INTERVAL '1 month'
FROM public.posts post_row
WHERE post_row.id = market.id
  AND post_row.type = 'secondhand'
  AND post_row.status = 'active'
  AND market.expires_at IS DISTINCT FROM post_row.created_at + INTERVAL '1 month';

ALTER TABLE public.secondhand_posts
  ALTER COLUMN expires_at SET DEFAULT (clock_timestamp() + INTERVAL '1 month');

REVOKE EXECUTE ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ
) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ, UUID[]
) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, BOOLEAN, UUID[]
) FROM authenticated;

CREATE OR REPLACE FUNCTION public.enforce_secondhand_fixed_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_created_at TIMESTAMPTZ;
BEGIN
  SELECT post_row.created_at INTO v_created_at
  FROM public.posts post_row
  WHERE post_row.id = NEW.id
    AND post_row.type = 'secondhand';

  IF v_created_at IS NULL THEN
    RAISE EXCEPTION 'Secondhand base post is required' USING ERRCODE = '23503';
  END IF;
  NEW.expires_at := v_created_at + INTERVAL '1 month';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_secondhand_fixed_expiry
  ON public.secondhand_posts;
CREATE TRIGGER trg_enforce_secondhand_fixed_expiry
BEFORE INSERT OR UPDATE OF expires_at ON public.secondhand_posts
FOR EACH ROW EXECUTE FUNCTION public.enforce_secondhand_fixed_expiry();

REVOKE ALL ON FUNCTION public.enforce_secondhand_fixed_expiry()
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.publish_secondhand_post(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, TEXT, TEXT,
  BOOLEAN, TIMESTAMPTZ, UUID[]
) TO authenticated;

CREATE OR REPLACE FUNCTION public.publish_secondhand_post_with_mentions(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_anonymous BOOLEAN,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_original_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_mentioned_user_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_post_id UUID;
  v_expires_at TIMESTAMPTZ;
BEGIN
  IF p_original_price IS NOT NULL
     AND (p_original_price < 0 OR p_original_price < p_price) THEN
    RAISE EXCEPTION 'Original price must not be below the selling price'
      USING ERRCODE = '22023';
  END IF;

  SELECT market.expires_at INTO v_expires_at
  FROM public.secondhand_posts market
  WHERE market.id = p_post_id;
  v_expires_at := COALESCE(
    v_expires_at,
    clock_timestamp() + INTERVAL '1 month'
  );

  v_post_id := public.publish_secondhand_post(
    p_post_id, p_operation_id, p_title, p_description,
    p_is_anonymous, p_is_private, p_price, p_category,
    p_condition, p_is_negotiable, v_expires_at
  );

  UPDATE public.secondhand_posts
  SET original_price = p_original_price,
      expires_at = v_expires_at
  WHERE id = v_post_id;

  PERFORM public.sync_content_mentions(
    'secondhand', v_post_id, NULL, p_mentioned_user_ids
  );
  RETURN v_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, NUMERIC, TEXT,
  TEXT, BOOLEAN, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_secondhand_post_with_mentions(
  UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN, NUMERIC, NUMERIC, TEXT,
  TEXT, BOOLEAN, UUID[]
) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_secondhand_post_with_media(
  p_post_id UUID,
  p_operation_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_is_private BOOLEAN,
  p_price NUMERIC,
  p_original_price NUMERIC,
  p_category TEXT,
  p_condition TEXT,
  p_is_negotiable BOOLEAN,
  p_keep_image_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_category NOT IN (
    'furniture', 'electronics', 'academic', 'clothing',
    'appliances', 'sports', 'beauty', 'other'
  ) THEN
    RAISE EXCEPTION 'Unsupported Secondhand category' USING ERRCODE = '22023';
  END IF;
  IF p_original_price IS NOT NULL
     AND (p_original_price < 0 OR p_original_price < p_price) THEN
    RAISE EXCEPTION 'Original price must not be below the selling price'
      USING ERRCODE = '22023';
  END IF;

  PERFORM public.update_secondhand_post_with_media(
    p_post_id, p_operation_id, p_title, p_description, p_is_private,
    p_price, p_condition, p_is_negotiable, p_keep_image_ids
  );

  UPDATE public.secondhand_posts
  SET original_price = p_original_price,
      category = p_category
  WHERE id = p_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, NUMERIC, TEXT, TEXT,
  BOOLEAN, UUID[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, NUMERIC, TEXT, TEXT,
  BOOLEAN, UUID[]
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_secondhand_post_with_media(
  UUID, UUID, TEXT, TEXT, BOOLEAN, NUMERIC, TEXT, BOOLEAN, UUID[]
) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_secondhand_availability_lifecycle(
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  reminders_created INTEGER,
  listings_inactivated INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := clock_timestamp();
  v_limit INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 50), 100));
  v_reminders INTEGER := 0;
  v_inactivated INTEGER := 0;
  v_listing RECORD;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);

  FOR v_listing IN
    SELECT market.id
    FROM public.secondhand_posts market
    JOIN public.posts post_row ON post_row.id = market.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND market.expires_at <= v_now
    ORDER BY market.expires_at, market.id
    FOR UPDATE OF market, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    UPDATE public.posts
    SET status = 'inactive', updated_at = v_now
    WHERE id = v_listing.id AND status = 'active';
    IF FOUND THEN v_inactivated := v_inactivated + 1; END IF;
  END LOOP;

  FOR v_listing IN
    SELECT market.id, post_row.user_id, post_row.title
    FROM public.secondhand_posts market
    JOIN public.posts post_row ON post_row.id = market.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND post_row.created_at <= v_now - INTERVAL '14 days'
      AND market.expires_at > v_now
      AND market.availability_reminder_sent_at IS NULL
    ORDER BY post_row.created_at, market.id
    FOR UPDATE OF market, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_listing.user_id,
      p_event_id := format('secondhand_expiry:%s', v_listing.id),
      p_kind := 'secondhand_availability',
      p_title := '你的商品将在两周后自动下架',
      p_body := format(
        '「%s」发布满一个月后会自动下架，你也可以随时编辑或删除。',
        COALESCE(NULLIF(left(btrim(v_listing.title), 60), ''), '这件商品')
      ),
      p_post_id := v_listing.id,
      p_content_kind := 'secondhand',
      p_cta_kind := 'secondhand_availability'
    );

    UPDATE public.secondhand_posts
    SET availability_reminder_sent_at = v_now
    WHERE id = v_listing.id
      AND availability_reminder_sent_at IS NULL;
    IF FOUND THEN v_reminders := v_reminders + 1; END IF;
  END LOOP;

  PERFORM set_config('cheese.secondhand_lifecycle_write', '', TRUE);
  RETURN QUERY SELECT v_reminders, v_inactivated;
END;
$$;

REVOKE ALL ON FUNCTION public.process_secondhand_availability_lifecycle(INTEGER)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_secondhand_availability_lifecycle(INTEGER)
  TO service_role;

CREATE OR REPLACE FUNCTION public.respond_secondhand_availability(
  p_post_id UUID,
  p_action TEXT
)
RETURNS TABLE (
  post_id UUID,
  status TEXT,
  availability_confirmed_at TIMESTAMPTZ,
  availability_cycle INTEGER,
  sold_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_action TEXT := lower(btrim(COALESCE(p_action, '')));
  v_owner UUID;
  v_status TEXT;
  v_expires_at TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT post_row.user_id, post_row.status, detail.expires_at
  INTO v_owner, v_status, v_expires_at
  FROM public.posts post_row
  JOIN public.secondhand_posts detail ON detail.id = post_row.id
  WHERE post_row.id = p_post_id
    AND post_row.type = 'secondhand'
  FOR UPDATE OF post_row, detail;

  IF NOT FOUND OR v_owner IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;
  IF v_action NOT IN ('still_available', 'sold') THEN
    RAISE EXCEPTION 'Unsupported availability action' USING ERRCODE = '22023';
  END IF;
  IF v_status NOT IN ('active', 'inactive') THEN
    RAISE EXCEPTION 'Listing is no longer actionable' USING ERRCODE = '55000';
  END IF;

  PERFORM set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);

  IF v_action = 'still_available' THEN
    IF v_expires_at <= v_now THEN
      RAISE EXCEPTION 'Listing has reached its fixed one-month expiry'
        USING ERRCODE = '55000';
    END IF;
    UPDATE public.secondhand_posts
    SET availability_confirmed_at = v_now
    WHERE id = p_post_id;
  ELSE
    UPDATE public.secondhand_posts AS detail
    SET sold_at = v_now,
        sold_count = GREATEST(detail.sold_count, COALESCE(detail.quantity, 1))
    WHERE detail.id = p_post_id;
    UPDATE public.posts
    SET status = 'completed', updated_at = v_now
    WHERE id = p_post_id;
  END IF;

  PERFORM set_config('cheese.secondhand_lifecycle_write', '', TRUE);
  RETURN QUERY
  SELECT post_row.id, post_row.status, detail.availability_confirmed_at,
         detail.availability_cycle, detail.sold_at
  FROM public.posts post_row
  JOIN public.secondhand_posts detail ON detail.id = post_row.id
  WHERE post_row.id = p_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_secondhand_availability(UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.respond_secondhand_availability(UUID, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_forum_title_length()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.type = 'forum' AND char_length(NEW.title) > 80 THEN
    RAISE EXCEPTION 'Forum title exceeds 80 characters'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_forum_title_length ON public.posts;
CREATE TRIGGER trg_enforce_forum_title_length
BEFORE INSERT OR UPDATE OF title, type ON public.posts
FOR EACH ROW EXECUTE FUNCTION public.enforce_forum_title_length();

REVOKE ALL ON FUNCTION public.enforce_forum_title_length()
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.validate_forum_anonymity_contract()
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
