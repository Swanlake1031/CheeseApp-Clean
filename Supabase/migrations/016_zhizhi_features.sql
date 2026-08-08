-- Zhizhi v1.0 support: comment sticker/system metadata + finals wooden fish event

ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS system_role TEXT,
  ADD COLUMN IF NOT EXISTS sticker_id TEXT;

CREATE TABLE IF NOT EXISTS zhizhi_event_progress (
  event_id TEXT PRIMARY KEY,
  tap_count INTEGER NOT NULL DEFAULT 0 CHECK (tap_count >= 0),
  unlocked_skin TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO zhizhi_event_progress (event_id, tap_count, unlocked_skin)
VALUES ('finals_wooden_fish', 0, NULL)
ON CONFLICT (event_id) DO NOTHING;

CREATE OR REPLACE FUNCTION touch_zhizhi_event_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS zhizhi_event_progress_updated_at ON zhizhi_event_progress;
CREATE TRIGGER zhizhi_event_progress_updated_at
  BEFORE UPDATE ON zhizhi_event_progress
  FOR EACH ROW
  EXECUTE FUNCTION touch_zhizhi_event_updated_at();

ALTER TABLE zhizhi_event_progress ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Zhizhi event readable" ON zhizhi_event_progress;
CREATE POLICY "Zhizhi event readable"
  ON zhizhi_event_progress
  FOR SELECT
  USING (TRUE);

DROP POLICY IF EXISTS "Zhizhi event mutable by authenticated" ON zhizhi_event_progress;
CREATE POLICY "Zhizhi event mutable by authenticated"
  ON zhizhi_event_progress
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE OR REPLACE FUNCTION increment_zhizhi_event_tap(event_key TEXT DEFAULT 'finals_wooden_fish', amount INTEGER DEFAULT 1)
RETURNS zhizhi_event_progress
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  updated_row zhizhi_event_progress;
BEGIN
  INSERT INTO zhizhi_event_progress(event_id, tap_count)
  VALUES (event_key, GREATEST(amount, 1))
  ON CONFLICT (event_id)
  DO UPDATE SET tap_count = zhizhi_event_progress.tap_count + GREATEST(amount, 1);

  UPDATE zhizhi_event_progress
  SET unlocked_skin = CASE WHEN tap_count >= 10000 THEN 'lucky_koi' ELSE unlocked_skin END
  WHERE event_id = event_key
  RETURNING * INTO updated_row;

  RETURN updated_row;
END;
$$;

GRANT EXECUTE ON FUNCTION increment_zhizhi_event_tap(TEXT, INTEGER) TO authenticated;
