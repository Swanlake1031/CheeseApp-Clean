BEGIN;

CREATE TABLE IF NOT EXISTS public.carpool_route_favorites (
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  route_template_id UUID NOT NULL REFERENCES public.carpool_route_templates(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, route_template_id)
);

CREATE INDEX IF NOT EXISTS carpool_route_favorites_route_idx
  ON public.carpool_route_favorites (route_template_id);

CREATE TABLE IF NOT EXISTS public.carpool_route_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_template_id UUID NOT NULL REFERENCES public.carpool_route_templates(id) ON DELETE CASCADE,
  reporter_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (reason IN ('spam', 'harassment', 'fraud', 'inappropriate', 'misleading', 'other')),
  details TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewing', 'resolved', 'dismissed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reporter_id, route_template_id)
);

CREATE INDEX IF NOT EXISTS carpool_route_reports_route_idx
  ON public.carpool_route_reports (route_template_id);

CREATE INDEX IF NOT EXISTS carpool_route_reports_reporter_idx
  ON public.carpool_route_reports (reporter_id, created_at DESC);

ALTER TABLE public.carpool_route_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carpool_route_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "carpool_route_favorites_select_own" ON public.carpool_route_favorites;
CREATE POLICY "carpool_route_favorites_select_own" ON public.carpool_route_favorites
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "carpool_route_favorites_insert_own" ON public.carpool_route_favorites;
CREATE POLICY "carpool_route_favorites_insert_own" ON public.carpool_route_favorites
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "carpool_route_favorites_delete_own" ON public.carpool_route_favorites;
CREATE POLICY "carpool_route_favorites_delete_own" ON public.carpool_route_favorites
  FOR DELETE
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "carpool_route_reports_insert_own" ON public.carpool_route_reports;
CREATE POLICY "carpool_route_reports_insert_own" ON public.carpool_route_reports
  FOR INSERT
  WITH CHECK (auth.uid() = reporter_id);

DROP POLICY IF EXISTS "carpool_route_reports_select_own" ON public.carpool_route_reports;
CREATE POLICY "carpool_route_reports_select_own" ON public.carpool_route_reports
  FOR SELECT
  USING (auth.uid() = reporter_id);

GRANT SELECT, INSERT, DELETE ON public.carpool_route_favorites TO authenticated, service_role;
GRANT SELECT, INSERT ON public.carpool_route_reports TO authenticated, service_role;

COMMIT;
