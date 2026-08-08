-- 116_secondhand_availability_lifecycle.sql
-- Database-clock lifecycle for marketplace availability confirmations.
--
-- Active listings receive a reminder 14 days after their last confirmation.
-- A seller confirmation starts a fresh cycle. Listings with no confirmation
-- for 30 days become inactive, never sold. Only an explicit seller action can
-- mark a listing completed.

BEGIN;

ALTER TABLE public.secondhand_posts
  ADD COLUMN availability_confirmed_at TIMESTAMPTZ
    NOT NULL DEFAULT clock_timestamp(),
  ADD COLUMN availability_reminder_sent_at TIMESTAMPTZ,
  ADD COLUMN availability_cycle INTEGER NOT NULL DEFAULT 1
    CHECK (availability_cycle > 0),
  ADD COLUMN sold_at TIMESTAMPTZ;

CREATE INDEX secondhand_availability_due_idx
  ON public.secondhand_posts (
    availability_confirmed_at,
    id
  )
  WHERE availability_reminder_sent_at IS NULL;

CREATE OR REPLACE FUNCTION public.guard_secondhand_lifecycle_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF (
    NEW.availability_confirmed_at
      IS DISTINCT FROM OLD.availability_confirmed_at
    OR NEW.availability_reminder_sent_at
      IS DISTINCT FROM OLD.availability_reminder_sent_at
    OR NEW.availability_cycle
      IS DISTINCT FROM OLD.availability_cycle
    OR NEW.sold_at
      IS DISTINCT FROM OLD.sold_at
  )
  AND COALESCE(
    current_setting('cheese.secondhand_lifecycle_write', TRUE),
    ''
  ) <> 'allowed'
  THEN
    RAISE EXCEPTION 'Secondhand lifecycle fields require the protected RPC'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_secondhand_lifecycle_fields
BEFORE UPDATE OF
  availability_confirmed_at,
  availability_reminder_sent_at,
  availability_cycle,
  sold_at
ON public.secondhand_posts
FOR EACH ROW
EXECUTE FUNCTION public.guard_secondhand_lifecycle_fields();

REVOKE ALL ON FUNCTION public.guard_secondhand_lifecycle_fields()
  FROM PUBLIC, anon, authenticated, service_role;

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
  v_limit INTEGER := GREATEST(
    1,
    LEAST(COALESCE(p_limit, 50), 100)
  );
  v_reminders INTEGER := 0;
  v_inactivated INTEGER := 0;
  v_listing RECORD;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required'
      USING ERRCODE = '42501';
  END IF;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    'allowed',
    TRUE
  );

  FOR v_listing IN
    SELECT
      detail.id,
      post_row.user_id,
      post_row.title,
      detail.availability_cycle
    FROM public.secondhand_posts detail
    JOIN public.posts post_row ON post_row.id = detail.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND detail.availability_confirmed_at
        <= v_now - INTERVAL '30 days'
    ORDER BY detail.availability_confirmed_at, detail.id
    FOR UPDATE OF detail, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    UPDATE public.posts
    SET status = 'inactive',
        updated_at = v_now
    WHERE id = v_listing.id
      AND status = 'active';

    IF FOUND THEN
      v_inactivated := v_inactivated + 1;
    END IF;
  END LOOP;

  FOR v_listing IN
    SELECT
      detail.id,
      post_row.user_id,
      post_row.title,
      detail.availability_cycle
    FROM public.secondhand_posts detail
    JOIN public.posts post_row ON post_row.id = detail.id
    WHERE post_row.type = 'secondhand'
      AND post_row.status = 'active'
      AND detail.availability_confirmed_at
        <= v_now - INTERVAL '14 days'
      AND detail.availability_confirmed_at
        > v_now - INTERVAL '30 days'
      AND detail.availability_reminder_sent_at IS NULL
    ORDER BY detail.availability_confirmed_at, detail.id
    FOR UPDATE OF detail, post_row SKIP LOCKED
    LIMIT v_limit
  LOOP
    PERFORM public.enqueue_system_message(
      p_recipient_user_id := v_listing.user_id,
      p_event_id := format(
        'secondhand_availability:%s:%s',
        v_listing.id,
        v_listing.availability_cycle
      ),
      p_kind := 'secondhand_availability',
      p_title := '你的商品还在售吗？',
      p_body := format(
        '请确认「%s」是否仍然可售，或将它标记为已售出。',
        COALESCE(
          NULLIF(left(btrim(v_listing.title), 60), ''),
          '这件商品'
        )
      ),
      p_post_id := v_listing.id,
      p_content_kind := 'secondhand',
      p_cta_kind := 'secondhand_availability'
    );

    UPDATE public.secondhand_posts
    SET availability_reminder_sent_at = v_now
    WHERE id = v_listing.id
      AND availability_cycle = v_listing.availability_cycle
      AND availability_reminder_sent_at IS NULL;

    IF FOUND THEN
      v_reminders := v_reminders + 1;
    END IF;
  END LOOP;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    '',
    TRUE
  );

  RETURN QUERY SELECT v_reminders, v_inactivated;
END;
$$;

REVOKE ALL ON FUNCTION public.process_secondhand_availability_lifecycle(
  INTEGER
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_secondhand_availability_lifecycle(
  INTEGER
) TO service_role;

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
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  SELECT post_row.user_id, post_row.status
  INTO v_owner, v_status
  FROM public.posts post_row
  JOIN public.secondhand_posts detail ON detail.id = post_row.id
  WHERE post_row.id = p_post_id
    AND post_row.type = 'secondhand'
  FOR UPDATE OF post_row;

  IF NOT FOUND OR v_owner IS DISTINCT FROM v_me THEN
    RAISE EXCEPTION 'Listing not found or not owned by caller'
      USING ERRCODE = '42501';
  END IF;

  IF v_action NOT IN ('still_available', 'sold') THEN
    RAISE EXCEPTION 'Unsupported availability action'
      USING ERRCODE = '22023';
  END IF;

  IF v_status NOT IN ('active', 'inactive') THEN
    RAISE EXCEPTION 'Listing is no longer actionable'
      USING ERRCODE = '55000';
  END IF;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    'allowed',
    TRUE
  );

  IF v_action = 'still_available' THEN
    UPDATE public.secondhand_posts AS detail
    SET availability_confirmed_at = v_now,
        availability_reminder_sent_at = NULL,
        availability_cycle = detail.availability_cycle + 1,
        sold_at = NULL
    WHERE detail.id = p_post_id;

    UPDATE public.posts
    SET status = 'active',
        updated_at = v_now
    WHERE id = p_post_id;
  ELSE
    UPDATE public.secondhand_posts AS detail
    SET sold_at = v_now,
        sold_count = GREATEST(
          detail.sold_count,
          COALESCE(detail.quantity, 1)
        )
    WHERE detail.id = p_post_id;

    UPDATE public.posts
    SET status = 'completed',
        updated_at = v_now
    WHERE id = p_post_id;
  END IF;

  PERFORM set_config(
    'cheese.secondhand_lifecycle_write',
    '',
    TRUE
  );

  RETURN QUERY
  SELECT
    post_row.id,
    post_row.status,
    detail.availability_confirmed_at,
    detail.availability_cycle,
    detail.sold_at
  FROM public.posts post_row
  JOIN public.secondhand_posts detail ON detail.id = post_row.id
  WHERE post_row.id = p_post_id;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_secondhand_availability(
  UUID, TEXT
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.respond_secondhand_availability(
  UUID, TEXT
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
