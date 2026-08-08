-- 134_mcmaster_email_verification.sql
--
-- Adds a server-owned McMaster email verification boundary. The verified
-- address and verification challenges remain private; public profile and post
-- views expose only a boolean badge flag.

BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_mcmaster_verified BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS public.mcmaster_student_verifications (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT mcmaster_student_verifications_email_format_check
    CHECK (
      email = LOWER(BTRIM(email))
      AND email ~ '^[a-z0-9._%+-]+@mcmaster[.]ca$'
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS mcmaster_student_verifications_email_key
  ON public.mcmaster_student_verifications (LOWER(email));

CREATE TABLE IF NOT EXISTS public.mcmaster_email_challenges (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  send_window_started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  send_count INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT mcmaster_email_challenges_email_format_check
    CHECK (
      email = LOWER(BTRIM(email))
      AND email ~ '^[a-z0-9._%+-]+@mcmaster[.]ca$'
    ),
  CONSTRAINT mcmaster_email_challenges_attempt_count_check
    CHECK (attempt_count BETWEEN 0 AND 5),
  CONSTRAINT mcmaster_email_challenges_send_count_check
    CHECK (send_count BETWEEN 1 AND 5),
  CONSTRAINT mcmaster_email_challenges_code_hash_check
    CHECK (code_hash ~ '^[0-9a-f]{64}$')
);

ALTER TABLE public.mcmaster_student_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mcmaster_email_challenges ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.mcmaster_student_verifications
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.mcmaster_email_challenges
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.mcmaster_student_verifications TO service_role;
GRANT ALL ON TABLE public.mcmaster_email_challenges TO service_role;

CREATE OR REPLACE FUNCTION public.protect_mcmaster_verification_flag()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.role() IS DISTINCT FROM 'service_role'
     AND NEW.is_mcmaster_verified IS DISTINCT FROM OLD.is_mcmaster_verified THEN
    RAISE EXCEPTION 'McMaster verification is server managed'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_mcmaster_verification_flag ON public.profiles;
CREATE TRIGGER protect_mcmaster_verification_flag
BEFORE UPDATE OF is_mcmaster_verified ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.protect_mcmaster_verification_flag();

CREATE OR REPLACE FUNCTION public.issue_mcmaster_email_challenge(
  p_user_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE (status TEXT, retry_after_seconds INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_email TEXT := LOWER(BTRIM(COALESCE(p_email, '')));
  v_existing public.mcmaster_email_challenges%ROWTYPE;
  v_wait INTEGER;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR v_email !~ '^[a-z0-9._%+-]+@mcmaster[.]ca$' THEN
    RAISE EXCEPTION 'A valid @mcmaster.ca email is required'
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_code_hash, '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid verification hash' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));

  IF EXISTS (
    SELECT 1 FROM public.mcmaster_student_verifications verification
    WHERE verification.user_id = p_user_id
  ) THEN
    RETURN QUERY SELECT 'already_verified'::TEXT, 0;
    RETURN;
  END IF;

  SELECT challenge.* INTO v_existing
  FROM public.mcmaster_email_challenges challenge
  WHERE challenge.user_id = p_user_id
  FOR UPDATE;

  IF FOUND AND v_existing.last_sent_at > v_now - INTERVAL '60 seconds' THEN
    v_wait := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (
        v_existing.last_sent_at + INTERVAL '60 seconds' - v_now
      )))::INTEGER
    );
    RETURN QUERY SELECT 'cooldown'::TEXT, v_wait;
    RETURN;
  END IF;

  IF FOUND
     AND v_existing.send_window_started_at > v_now - INTERVAL '24 hours'
     AND v_existing.send_count >= 5 THEN
    v_wait := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (
        v_existing.send_window_started_at + INTERVAL '24 hours' - v_now
      )))::INTEGER
    );
    RETURN QUERY SELECT 'rate_limited'::TEXT, v_wait;
    RETURN;
  END IF;

  INSERT INTO public.mcmaster_email_challenges (
    user_id,
    email,
    code_hash,
    expires_at,
    attempt_count,
    last_sent_at,
    send_window_started_at,
    send_count,
    updated_at
  ) VALUES (
    p_user_id,
    v_email,
    p_code_hash,
    v_now + INTERVAL '10 minutes',
    0,
    v_now,
    v_now,
    1,
    v_now
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email,
    code_hash = EXCLUDED.code_hash,
    expires_at = EXCLUDED.expires_at,
    attempt_count = 0,
    last_sent_at = EXCLUDED.last_sent_at,
    send_window_started_at = CASE
      WHEN public.mcmaster_email_challenges.send_window_started_at
        <= v_now - INTERVAL '24 hours'
      THEN v_now
      ELSE public.mcmaster_email_challenges.send_window_started_at
    END,
    send_count = CASE
      WHEN public.mcmaster_email_challenges.send_window_started_at
        <= v_now - INTERVAL '24 hours'
      THEN 1
      ELSE public.mcmaster_email_challenges.send_count + 1
    END,
    updated_at = v_now;

  RETURN QUERY SELECT 'issued'::TEXT, 60;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_mcmaster_email_challenge(
  p_user_id UUID,
  p_email TEXT,
  p_code_hash TEXT
)
RETURNS TABLE (status TEXT, remaining_attempts INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_email TEXT := LOWER(BTRIM(COALESCE(p_email, '')));
  v_challenge public.mcmaster_email_challenges%ROWTYPE;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR v_email !~ '^[a-z0-9._%+-]+@mcmaster[.]ca$' THEN
    RAISE EXCEPTION 'A valid @mcmaster.ca email is required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));
  SELECT challenge.* INTO v_challenge
  FROM public.mcmaster_email_challenges challenge
  WHERE challenge.user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'missing'::TEXT, 0;
    RETURN;
  END IF;
  IF v_challenge.expires_at <= v_now THEN
    DELETE FROM public.mcmaster_email_challenges WHERE user_id = p_user_id;
    RETURN QUERY SELECT 'expired'::TEXT, 0;
    RETURN;
  END IF;
  IF v_challenge.attempt_count >= 5 THEN
    RETURN QUERY SELECT 'locked'::TEXT, 0;
    RETURN;
  END IF;

  IF v_challenge.email IS DISTINCT FROM v_email
     OR v_challenge.code_hash IS DISTINCT FROM p_code_hash THEN
    UPDATE public.mcmaster_email_challenges
    SET attempt_count = LEAST(attempt_count + 1, 5), updated_at = v_now
    WHERE user_id = p_user_id
    RETURNING * INTO v_challenge;
    RETURN QUERY SELECT
      CASE WHEN v_challenge.attempt_count >= 5 THEN 'locked' ELSE 'invalid' END,
      GREATEST(0, 5 - v_challenge.attempt_count);
    RETURN;
  END IF;

  BEGIN
    INSERT INTO public.mcmaster_student_verifications (
      user_id, email, verified_at, created_at, updated_at
    ) VALUES (
      p_user_id, v_email, v_now, v_now, v_now
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email = EXCLUDED.email,
      verified_at = EXCLUDED.verified_at,
      updated_at = EXCLUDED.updated_at;
  EXCEPTION WHEN unique_violation THEN
    RETURN QUERY SELECT 'email_in_use'::TEXT, 0;
    RETURN;
  END;

  UPDATE public.profiles
  SET is_mcmaster_verified = TRUE, updated_at = v_now
  WHERE id = p_user_id;

  DELETE FROM public.mcmaster_email_challenges WHERE user_id = p_user_id;
  RETURN QUERY SELECT 'verified'::TEXT, 5;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_mcmaster_verification_flag() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.issue_mcmaster_email_challenge(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.confirm_mcmaster_email_challenge(UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_mcmaster_email_challenge(UUID, TEXT, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_mcmaster_email_challenge(UUID, TEXT, TEXT)
  TO service_role;

CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  profile.gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::TEXT AS country_name,
  NULL::TEXT AS region,
  NULL::TEXT AS city,
  profile.is_mcmaster_verified
FROM public.profiles profile
WHERE profile.deactivated_at IS NULL
  AND (
    auth.role() = 'service_role'
    OR (
      auth.uid() IS NOT NULL
      AND (
        profile.id = auth.uid()
        OR NOT EXISTS (
          SELECT 1
          FROM public.user_blocks block_row
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

CREATE OR REPLACE VIEW public.secondhand_posts_view AS
SELECT
  s.id, s.price, s.original_price, s.is_negotiable, s.is_free,
  s.category, s.condition, s.can_ship, s.shipping_fee,
  s.quantity, s.sold_count,
  tier.effective_highlight_type AS highlight_type,
  s.pinned_until, s.view_count, s.like_count, s.comment_count, s.save_count,
  public.calculate_hot_score(
    s.view_count, s.like_count, s.comment_count, s.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  p.user_id, p.title, p.description, p.status, p.is_anonymous,
  p.created_at, p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = s.id
    ),
    '[]'::JSON
  ) AS images,
  CASE
    WHEN s.original_price IS NOT NULL AND s.original_price > 0
    THEN ROUND((1 - s.price / s.original_price) * 100)
    ELSE NULL
  END AS discount_percent,
  s.expires_at,
  (s.expires_at IS NOT NULL AND s.expires_at <= NOW()) AS is_expired,
  CASE WHEN p.is_anonymous THEN FALSE ELSE pr.is_mcmaster_verified END
    AS user_mcmaster_verified
FROM public.secondhand_posts s
JOIN public.posts p ON p.id = s.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN s.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND s.pinned_until IS NOT NULL
      AND s.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE s.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND p.is_private = FALSE
  AND (s.expires_at IS NULL OR s.expires_at > NOW());

ALTER VIEW public.secondhand_posts_view SET (security_invoker = true);
REVOKE ALL ON TABLE public.secondhand_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.secondhand_posts_view TO authenticated, service_role;

CREATE OR REPLACE VIEW public.forum_posts_view AS
SELECT
  f.id, f.board_id, board.slug AS board_slug, board.name AS board_name,
  board.icon AS board_icon,
  board.allows_anonymous_posts AS board_allows_anonymous,
  f.allow_comments, f.is_pinned, f.is_locked, f.like_count, f.comment_count,
  tier.effective_highlight_type AS highlight_type, f.pinned_until,
  f.view_count, f.save_count,
  public.calculate_hot_score(
    f.view_count, f.like_count, f.comment_count, f.save_count, p.created_at
  ) AS hot_score,
  CASE
    WHEN tier.effective_highlight_type = 'pinned'::public.post_highlight_type THEN 0
    WHEN tier.effective_highlight_type IN (
      'urgent'::public.post_highlight_type,
      'breaking'::public.post_highlight_type
    ) THEN 1
    ELSE 2
  END AS highlight_rank,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE p.user_id
  END AS user_id,
  p.title, p.description, p.status, p.is_anonymous, p.created_at, p.updated_at,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.full_name
  END AS user_name,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.avatar_url
  END AS user_avatar,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.university
  END AS user_university,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN NULL
    ELSE pr.verified
  END AS user_verified,
  COALESCE(
    (
      SELECT json_agg(
        json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
        ORDER BY pi.order_index
      )
      FROM public.post_images pi
      WHERE pi.post_id = f.id
    ),
    '[]'::JSON
  ) AS images,
  CASE
    WHEN p.is_anonymous AND p.user_id IS DISTINCT FROM auth.uid() THEN FALSE
    ELSE COALESCE(pr.is_official, FALSE)
  END AS user_official,
  (p.user_id = auth.uid()) AS viewer_owns_post,
  CASE
    WHEN p.is_anonymous THEN FALSE
    ELSE pr.is_mcmaster_verified
  END AS user_mcmaster_verified
FROM public.forum_posts f
JOIN public.posts p ON p.id = f.id
JOIN public.profile_public_view pr ON pr.id = p.user_id
JOIN public.forum_boards board ON board.id = f.board_id
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.highlight_type IN (
      'pinned'::public.post_highlight_type,
      'urgent'::public.post_highlight_type
    )
      AND f.pinned_until IS NOT NULL
      AND f.pinned_until < NOW()
    THEN 'normal'::public.post_highlight_type
    ELSE f.highlight_type
  END AS effective_highlight_type
) tier
WHERE p.status = 'active'
  AND p.is_private = FALSE
  AND board.status <> 'archived';

ALTER VIEW public.forum_posts_view SET (security_invoker = false);
REVOKE ALL ON TABLE public.forum_posts_view
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.forum_posts_view TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
