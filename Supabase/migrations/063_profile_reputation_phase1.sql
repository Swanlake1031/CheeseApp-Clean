-- 063_profile_reputation_phase1.sql
-- Phase 1 for profile reputation + cheese energy.

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_reputation_summary (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  cheese_exp INTEGER NOT NULL DEFAULT 0 CHECK (cheese_exp >= 0),
  energy_balance INTEGER NOT NULL DEFAULT 0 CHECK (energy_balance >= 0),
  credit_score INTEGER NOT NULL DEFAULT 100 CHECK (credit_score >= 0 AND credit_score <= 200),
  positive_reviews INTEGER NOT NULL DEFAULT 0 CHECK (positive_reviews >= 0),
  negative_reviews INTEGER NOT NULL DEFAULT 0 CHECK (negative_reviews >= 0),
  completed_transactions INTEGER NOT NULL DEFAULT 0 CHECK (completed_transactions >= 0),
  helpful_answers INTEGER NOT NULL DEFAULT 0 CHECK (helpful_answers >= 0),
  successful_posts INTEGER NOT NULL DEFAULT 0 CHECK (successful_posts >= 0),
  check_in_streak INTEGER NOT NULL DEFAULT 0 CHECK (check_in_streak >= 0),
  last_check_in_date DATE,
  last_event_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS user_reputation_summary_energy_idx
  ON public.user_reputation_summary (energy_balance DESC, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.user_reputation_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (
    event_type IN (
      'profile_completed_bonus',
      'student_verified_bonus',
      'daily_check_in',
      'successful_post',
      'helpful_answer',
      'good_review',
      'completed_transaction',
      'report_penalty',
      'manual_adjustment'
    )
  ),
  cheese_exp_delta INTEGER NOT NULL DEFAULT 0,
  energy_delta INTEGER NOT NULL DEFAULT 0,
  credit_score_delta INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  meta JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS user_reputation_ledger_user_idx
  ON public.user_reputation_ledger (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS user_reputation_ledger_event_idx
  ON public.user_reputation_ledger (event_type, created_at DESC);

ALTER TABLE public.user_reputation_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_reputation_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own reputation summary" ON public.user_reputation_summary;
CREATE POLICY "Users can view own reputation summary"
ON public.user_reputation_summary
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view own reputation ledger" ON public.user_reputation_ledger;
CREATE POLICY "Users can view own reputation ledger"
ON public.user_reputation_ledger
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

GRANT SELECT ON public.user_reputation_summary TO authenticated, service_role;
GRANT SELECT ON public.user_reputation_ledger TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reputation_level_info(p_total_exp INTEGER)
RETURNS TABLE (
  level INTEGER,
  level_exp INTEGER,
  level_exp_target INTEGER
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_remaining INTEGER := GREATEST(COALESCE(p_total_exp, 0), 0);
  v_level INTEGER := 1;
  v_target INTEGER := 100;
BEGIN
  WHILE v_remaining >= v_target LOOP
    v_remaining := v_remaining - v_target;
    v_level := v_level + 1;
    v_target := 100 + (v_level - 1) * 25;
  END LOOP;

  RETURN QUERY
  SELECT v_level, v_remaining, v_target;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_reputation_entry(
  p_user_id UUID,
  p_event_type TEXT,
  p_cheese_exp_delta INTEGER,
  p_energy_delta INTEGER,
  p_credit_score_delta INTEGER DEFAULT 0,
  p_note TEXT DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::JSONB,
  p_allow_duplicate BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_exists BOOLEAN := FALSE;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User id is required';
  END IF;

  INSERT INTO public.user_reputation_summary (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  IF NOT p_allow_duplicate THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.user_reputation_ledger l
      WHERE l.user_id = p_user_id
        AND l.event_type = p_event_type
    )
    INTO v_exists;

    IF v_exists THEN
      RETURN;
    END IF;
  END IF;

  UPDATE public.user_reputation_summary s
  SET
    cheese_exp = GREATEST(0, s.cheese_exp + COALESCE(p_cheese_exp_delta, 0)),
    energy_balance = GREATEST(0, s.energy_balance + COALESCE(p_energy_delta, 0)),
    credit_score = LEAST(200, GREATEST(0, s.credit_score + COALESCE(p_credit_score_delta, 0))),
    successful_posts = s.successful_posts + CASE WHEN p_event_type = 'successful_post' AND COALESCE(p_cheese_exp_delta, 0) >= 0 THEN 1 ELSE 0 END,
    helpful_answers = s.helpful_answers + CASE WHEN p_event_type = 'helpful_answer' AND COALESCE(p_cheese_exp_delta, 0) >= 0 THEN 1 ELSE 0 END,
    completed_transactions = s.completed_transactions + CASE WHEN p_event_type = 'completed_transaction' AND COALESCE(p_credit_score_delta, 0) >= 0 THEN 1 ELSE 0 END,
    positive_reviews = s.positive_reviews + CASE WHEN p_event_type = 'good_review' AND COALESCE(p_credit_score_delta, 0) >= 0 THEN 1 ELSE 0 END,
    negative_reviews = s.negative_reviews + CASE WHEN p_event_type = 'report_penalty' AND COALESCE(p_credit_score_delta, 0) < 0 THEN 1 ELSE 0 END,
    last_event_at = NOW(),
    updated_at = NOW()
  WHERE s.user_id = p_user_id;

  INSERT INTO public.user_reputation_ledger (
    user_id,
    event_type,
    cheese_exp_delta,
    energy_delta,
    credit_score_delta,
    note,
    meta
  )
  VALUES (
    p_user_id,
    p_event_type,
    COALESCE(p_cheese_exp_delta, 0),
    COALESCE(p_energy_delta, 0),
    COALESCE(p_credit_score_delta, 0),
    p_note,
    COALESCE(p_meta, '{}'::JSONB)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_user_reputation_summary(p_user_id UUID DEFAULT auth.uid())
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_profile RECORD;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO public.user_reputation_summary (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT
    p.profile_completed,
    p.verified
  INTO v_profile
  FROM public.profiles p
  WHERE p.id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    IF COALESCE(v_profile.profile_completed, FALSE) THEN
      PERFORM public.apply_reputation_entry(
        p_user_id,
        'profile_completed_bonus',
        10,
        20,
        0,
        '完善资料奖励',
        jsonb_build_object('source', 'profile'),
        FALSE
      );
    END IF;

    IF COALESCE(v_profile.verified, FALSE) THEN
      PERFORM public.apply_reputation_entry(
        p_user_id,
        'student_verified_bonus',
        20,
        40,
        0,
        '学生认证奖励',
        jsonb_build_object('source', 'verification'),
        FALSE
      );
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_profile_reputation_sync()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  PERFORM public.ensure_user_reputation_summary(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profile_reputation_sync ON public.profiles;
CREATE TRIGGER profile_reputation_sync
  AFTER INSERT OR UPDATE OF profile_completed, verified
  ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_profile_reputation_sync();

CREATE OR REPLACE FUNCTION public.get_my_reputation_summary()
RETURNS TABLE (
  user_id UUID,
  cheese_exp INTEGER,
  level INTEGER,
  level_exp INTEGER,
  level_exp_target INTEGER,
  energy_balance INTEGER,
  credit_score INTEGER,
  positive_reviews INTEGER,
  negative_reviews INTEGER,
  completed_transactions INTEGER,
  helpful_answers INTEGER,
  successful_posts INTEGER,
  check_in_streak INTEGER,
  last_check_in_date TEXT,
  can_check_in BOOLEAN,
  last_event_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  PERFORM public.ensure_user_reputation_summary(v_user_id);

  RETURN QUERY
  SELECT
    s.user_id,
    s.cheese_exp,
    info.level,
    info.level_exp,
    info.level_exp_target,
    s.energy_balance,
    s.credit_score,
    s.positive_reviews,
    s.negative_reviews,
    s.completed_transactions,
    s.helpful_answers,
    s.successful_posts,
    s.check_in_streak,
    s.last_check_in_date::TEXT,
    COALESCE(s.last_check_in_date <> CURRENT_DATE, TRUE),
    s.last_event_at
  FROM public.user_reputation_summary s
  CROSS JOIN LATERAL public.reputation_level_info(s.cheese_exp) AS info
  WHERE s.user_id = v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_reputation_ledger(p_limit INTEGER DEFAULT 20)
RETURNS TABLE (
  id UUID,
  event_type TEXT,
  cheese_exp_delta INTEGER,
  energy_delta INTEGER,
  credit_score_delta INTEGER,
  note TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  PERFORM public.ensure_user_reputation_summary(v_user_id);

  RETURN QUERY
  SELECT
    l.id,
    l.event_type,
    l.cheese_exp_delta,
    l.energy_delta,
    l.credit_score_delta,
    l.note,
    l.created_at
  FROM public.user_reputation_ledger l
  WHERE l.user_id = v_user_id
  ORDER BY l.created_at DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_daily_cheese_check_in()
RETURNS TABLE (
  granted BOOLEAN,
  energy_delta INTEGER,
  cheese_exp_delta INTEGER,
  streak INTEGER,
  user_id UUID,
  cheese_exp INTEGER,
  level INTEGER,
  level_exp INTEGER,
  level_exp_target INTEGER,
  energy_balance INTEGER,
  credit_score INTEGER,
  positive_reviews INTEGER,
  negative_reviews INTEGER,
  completed_transactions INTEGER,
  helpful_answers INTEGER,
  successful_posts INTEGER,
  check_in_streak INTEGER,
  last_check_in_date TEXT,
  can_check_in BOOLEAN,
  last_event_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_summary public.user_reputation_summary;
  v_energy_delta INTEGER := 0;
  v_cheese_delta INTEGER := 0;
  v_streak INTEGER := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  PERFORM public.ensure_user_reputation_summary(v_user_id);

  SELECT *
  INTO v_summary
  FROM public.user_reputation_summary s
  WHERE s.user_id = v_user_id
  FOR UPDATE;

  IF v_summary.last_check_in_date = CURRENT_DATE THEN
    RETURN QUERY
    SELECT
      FALSE,
      0,
      0,
      v_summary.check_in_streak,
      v_summary.user_id,
      v_summary.cheese_exp,
      info.level,
      info.level_exp,
      info.level_exp_target,
      v_summary.energy_balance,
      v_summary.credit_score,
      v_summary.positive_reviews,
      v_summary.negative_reviews,
      v_summary.completed_transactions,
      v_summary.helpful_answers,
      v_summary.successful_posts,
      v_summary.check_in_streak,
      v_summary.last_check_in_date::TEXT,
      FALSE,
      v_summary.last_event_at
    FROM public.reputation_level_info(v_summary.cheese_exp) AS info;
    RETURN;
  END IF;

  v_streak := CASE
    WHEN v_summary.last_check_in_date = CURRENT_DATE - 1 THEN v_summary.check_in_streak + 1
    ELSE 1
  END;

  v_energy_delta := 2;
  v_cheese_delta := 1;

  IF MOD(v_streak, 7) = 0 THEN
    v_energy_delta := v_energy_delta + 10;
    v_cheese_delta := v_cheese_delta + 4;
  END IF;

  UPDATE public.user_reputation_summary s
  SET
    energy_balance = s.energy_balance + v_energy_delta,
    cheese_exp = s.cheese_exp + v_cheese_delta,
    check_in_streak = v_streak,
    last_check_in_date = CURRENT_DATE,
    last_event_at = NOW(),
    updated_at = NOW()
  WHERE s.user_id = v_user_id
  RETURNING *
  INTO v_summary;

  INSERT INTO public.user_reputation_ledger (
    user_id,
    event_type,
    cheese_exp_delta,
    energy_delta,
    credit_score_delta,
    note,
    meta
  )
  VALUES (
    v_user_id,
    'daily_check_in',
    v_cheese_delta,
    v_energy_delta,
    0,
    CASE WHEN MOD(v_streak, 7) = 0 THEN '每日签到（连续奖励）' ELSE '每日签到' END,
    jsonb_build_object('streak', v_streak)
  );

  RETURN QUERY
  SELECT
    TRUE,
    v_energy_delta,
    v_cheese_delta,
    v_streak,
    v_summary.user_id,
    v_summary.cheese_exp,
    info.level,
    info.level_exp,
    info.level_exp_target,
    v_summary.energy_balance,
    v_summary.credit_score,
    v_summary.positive_reviews,
    v_summary.negative_reviews,
    v_summary.completed_transactions,
    v_summary.helpful_answers,
    v_summary.successful_posts,
    v_summary.check_in_streak,
    v_summary.last_check_in_date::TEXT,
    FALSE,
    v_summary.last_event_at
  FROM public.reputation_level_info(v_summary.cheese_exp) AS info;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_reputation_summary()
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_my_reputation_ledger(INTEGER)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.claim_daily_cheese_check_in()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
