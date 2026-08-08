-- 079_security_advisor_hardening.sql
-- Address current Supabase Security Advisor findings without regressing app reads.

BEGIN;

-- ---------------------------------------------------------------------------
-- Safe helper for public profile geo fields
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.public_user_geo_summary_rows()
RETURNS TABLE (
  user_id UUID,
  ip_masked TEXT,
  country_name TEXT,
  region TEXT,
  city TEXT,
  last_seen_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.user_id,
    g.ip_masked,
    g.country_name,
    g.region,
    g.city,
    g.last_seen_at
  FROM public.user_geo_profiles g
$$;

REVOKE ALL ON FUNCTION public.public_user_geo_summary_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_user_geo_summary_rows() TO authenticated, service_role;

CREATE OR REPLACE VIEW public.profile_public_view AS
SELECT
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.university,
  p.major,
  p.bio,
  p.birthday,
  p.gender,
  p.occupation,
  p.verified,
  p.profile_completed,
  g.ip_masked,
  g.country_name,
  g.region,
  g.city,
  g.last_seen_at,
  p.created_at,
  p.updated_at,
  p.school_id,
  p.campus_id
FROM public.profiles p
LEFT JOIN public.public_user_geo_summary_rows() g
  ON g.user_id = p.id
WHERE p.deactivated_at IS NULL;

ALTER VIEW IF EXISTS public.profile_public_view SET (security_invoker = true);
REVOKE ALL ON public.profile_public_view FROM anon;
GRANT SELECT ON public.profile_public_view TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Safe helper for public ride credit summary
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.public_user_credit_summary_rows()
RETURNS TABLE (
  user_id UUID,
  credit_score INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_reputation_summary'
      AND column_name = 'credit_score'
  ) THEN
    RETURN QUERY
    SELECT
      s.user_id,
      s.credit_score::INTEGER AS credit_score
    FROM public.user_reputation_summary s;
  ELSE
    RETURN QUERY
    SELECT
      p.id AS user_id,
      100::INTEGER AS credit_score
    FROM public.profiles p;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.public_user_credit_summary_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_user_credit_summary_rows() TO authenticated, service_role;

CREATE OR REPLACE VIEW public.public_user_credit_summary_view AS
SELECT
  summary.user_id,
  summary.credit_score
FROM public.public_user_credit_summary_rows() summary;

ALTER VIEW IF EXISTS public.public_user_credit_summary_view SET (security_invoker = true);
GRANT SELECT ON public.public_user_credit_summary_view TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Other advisor-flagged public views can safely use invoker rights
-- ---------------------------------------------------------------------------
ALTER VIEW IF EXISTS public.group_messages_view SET (security_invoker = true);
ALTER VIEW IF EXISTS public.ride_estimate_recalc_queue SET (security_invoker = true);

-- ---------------------------------------------------------------------------
-- Reference data should be read-only for signed-in users, not public
-- ---------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.schools ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.school_campuses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can read active schools" ON public.schools;
CREATE POLICY "Authenticated can read active schools"
ON public.schools
FOR SELECT
TO authenticated
USING (active = TRUE);

DROP POLICY IF EXISTS "Authenticated can read active school campuses" ON public.school_campuses;
CREATE POLICY "Authenticated can read active school campuses"
ON public.school_campuses
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.schools s
    WHERE s.id = school_campuses.school_id
      AND s.active = TRUE
  )
);

REVOKE ALL ON public.schools FROM anon, authenticated;
REVOKE ALL ON public.school_campuses FROM anon, authenticated;
GRANT SELECT ON public.schools TO authenticated, service_role;
GRANT SELECT ON public.school_campuses TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
