-- 181_content_studio_access_and_drafts.sql
--
-- Isolated authorization and durable drafts for the internal Content Studio.
-- This migration intentionally does not alter production post, image, forum,
-- secondhand, visibility, or publishing contracts. Final publication continues
-- to use the existing authenticated RPC pipeline.

BEGIN;

CREATE TABLE public.content_studio_roles (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('admin', 'content_editor')),
  granted_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.content_studio_drafts (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content_type TEXT NOT NULL CHECK (content_type IN ('forum', 'secondhand')),
  title TEXT NOT NULL DEFAULT '',
  payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (jsonb_typeof(payload) = 'object')
);

CREATE INDEX content_studio_drafts_owner_updated_idx
  ON public.content_studio_drafts(user_id, updated_at DESC);

CREATE TRIGGER content_studio_roles_updated_at
BEFORE UPDATE ON public.content_studio_roles
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER content_studio_drafts_updated_at
BEFORE UPDATE ON public.content_studio_drafts
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.content_studio_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_studio_drafts ENABLE ROW LEVEL SECURITY;

-- Content Studio requests are mediated by its dedicated Worker. Do not expose
-- the role list or drafts to arbitrary authenticated application sessions.
REVOKE ALL ON TABLE public.content_studio_roles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.content_studio_drafts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.content_studio_roles TO service_role;
GRANT ALL ON TABLE public.content_studio_drafts TO service_role;

-- Draft media is private and can only be read or written by the Worker using
-- its server-side service credential. It is never used as final post media.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'content-studio-drafts',
  'content-studio-drafts',
  FALSE,
  10485760,
  ARRAY['image/jpeg']::TEXT[]
)
ON CONFLICT (id) DO UPDATE
SET public = FALSE,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

NOTIFY pgrst, 'reload schema';

COMMIT;
