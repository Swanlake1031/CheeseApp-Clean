-- Database-managed launch announcements shown before authentication.
-- Clients remember announcement_key locally, so publishing a new key shows
-- the new notice without requiring an App Store release.

BEGIN;

CREATE TABLE public.app_announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_key TEXT NOT NULL UNIQUE,
  title_en TEXT NOT NULL,
  title_zh TEXT NOT NULL,
  items_en JSONB NOT NULL DEFAULT '[]'::JSONB,
  items_zh JSONB NOT NULL DEFAULT '[]'::JSONB,
  is_active BOOLEAN NOT NULL DEFAULT FALSE,
  starts_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  ends_at TIMESTAMPTZ,
  published_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT app_announcements_key_not_blank
    CHECK (btrim(announcement_key) <> ''),
  CONSTRAINT app_announcements_titles_not_blank
    CHECK (btrim(title_en) <> '' AND btrim(title_zh) <> ''),
  CONSTRAINT app_announcements_items_are_arrays
    CHECK (
      jsonb_typeof(items_en) = 'array'
      AND jsonb_typeof(items_zh) = 'array'
    ),
  CONSTRAINT app_announcements_valid_window
    CHECK (ends_at IS NULL OR ends_at > starts_at)
);

ALTER TABLE public.app_announcements ENABLE ROW LEVEL SECURITY;

CREATE POLICY app_announcements_read_current
ON public.app_announcements
FOR SELECT
TO anon, authenticated
USING (
  is_active
  AND starts_at <= clock_timestamp()
  AND (ends_at IS NULL OR ends_at > clock_timestamp())
);

REVOKE ALL ON TABLE public.app_announcements
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.app_announcements TO anon, authenticated;
GRANT ALL ON TABLE public.app_announcements TO service_role;

COMMENT ON TABLE public.app_announcements IS
  'Versioned, database-managed notices shown once per device before login.';
COMMENT ON COLUMN public.app_announcements.announcement_key IS
  'Immutable client acknowledgement key; change it to publish a new notice.';

INSERT INTO public.app_announcements (
  announcement_key,
  title_en,
  title_zh,
  items_en,
  items_zh,
  is_active,
  starts_at,
  published_at
)
VALUES (
  'developer-log-2026-08-13-1',
  'Development Log',
  '開發日誌',
  jsonb_build_array(
    'The English interface is not fully localized yet.',
    'Sign in with Apple is currently experiencing issues.',
    'Course data has not been fully uploaded yet.'
  ),
  jsonb_build_array(
    '英文界面仍未完全本地化。',
    'Apple 登入目前存在問題。',
    '課程尚未上傳完畢。'
  ),
  TRUE,
  clock_timestamp(),
  clock_timestamp()
);

COMMIT;
