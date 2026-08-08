-- ============================================
-- Spring blessings wall (multi-user sync)
-- ============================================

CREATE TABLE IF NOT EXISTS public.spring_blessings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message TEXT NOT NULL CHECK (char_length(trim(message)) BETWEEN 1 AND 48),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS spring_blessings_created_at_idx
  ON public.spring_blessings (created_at DESC);

CREATE TABLE IF NOT EXISTS public.spring_blessings_meta (
  key TEXT PRIMARY KEY,
  lamp_count INTEGER NOT NULL DEFAULT 88 CHECK (lamp_count >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.spring_blessings_meta (key, lamp_count)
VALUES ('global', 88)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.touch_spring_blessings_meta_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS spring_blessings_meta_updated_at ON public.spring_blessings_meta;
CREATE TRIGGER spring_blessings_meta_updated_at
  BEFORE UPDATE ON public.spring_blessings_meta
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_spring_blessings_meta_updated_at();

CREATE OR REPLACE FUNCTION public.on_spring_blessing_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.spring_blessings_meta
  SET lamp_count = lamp_count + 1
  WHERE key = 'global';

  IF NOT FOUND THEN
    INSERT INTO public.spring_blessings_meta (key, lamp_count)
    VALUES ('global', 89)
    ON CONFLICT (key) DO UPDATE
      SET lamp_count = public.spring_blessings_meta.lamp_count + 1;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS spring_blessings_after_insert ON public.spring_blessings;
CREATE TRIGGER spring_blessings_after_insert
  AFTER INSERT ON public.spring_blessings
  FOR EACH ROW
  EXECUTE FUNCTION public.on_spring_blessing_insert();

CREATE OR REPLACE FUNCTION public.increment_spring_lamp(p_amount INTEGER DEFAULT 1)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  normalized_amount INTEGER;
  next_count INTEGER;
BEGIN
  normalized_amount = GREATEST(COALESCE(p_amount, 1), 1);

  INSERT INTO public.spring_blessings_meta (key, lamp_count)
  VALUES ('global', 88 + normalized_amount)
  ON CONFLICT (key) DO UPDATE
    SET lamp_count = public.spring_blessings_meta.lamp_count + normalized_amount
  RETURNING lamp_count INTO next_count;

  RETURN next_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_spring_lamp(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_spring_lamp(INTEGER) TO anon;

ALTER TABLE public.spring_blessings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spring_blessings_meta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Spring blessings readable" ON public.spring_blessings;
CREATE POLICY "Spring blessings readable"
  ON public.spring_blessings
  FOR SELECT
  USING (TRUE);

DROP POLICY IF EXISTS "Spring blessings insertable by app users" ON public.spring_blessings;
CREATE POLICY "Spring blessings insertable by app users"
  ON public.spring_blessings
  FOR INSERT
  WITH CHECK (auth.role() IN ('authenticated', 'anon'));

DROP POLICY IF EXISTS "Spring blessings meta readable" ON public.spring_blessings_meta;
CREATE POLICY "Spring blessings meta readable"
  ON public.spring_blessings_meta
  FOR SELECT
  USING (TRUE);

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.spring_blessings;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.spring_blessings_meta;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END
$$;
