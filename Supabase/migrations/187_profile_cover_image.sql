-- Lightweight profile cover image MVP.
-- Cover objects reuse the existing public avatars bucket and its owner-folder
-- policies. Only the durable public URL is stored on the profile row.

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS cover_image_url TEXT;

COMMENT ON COLUMN public.profiles.cover_image_url IS
  'Optional public Storage URL for the user profile cover image.';

CREATE OR REPLACE VIEW public.profile_public_view
WITH (security_barrier = true) AS
SELECT
  profile.id,
  COALESCE(NULLIF(BTRIM(profile.full_name), ''), '用户') AS full_name,
  profile.avatar_url,
  profile.university,
  profile.major,
  profile.bio,
  CASE WHEN profile.show_gender THEN profile.gender ELSE NULL END AS gender,
  profile.occupation,
  profile.verified,
  profile.school_id,
  profile.campus_id,
  profile.is_official,
  NULL::TEXT AS country_name,
  NULL::TEXT AS region,
  NULL::TEXT AS city,
  profile.is_mcmaster_verified,
  profile.show_gender,
  profile.is_graduated,
  profile.public_uid,
  profile.cover_image_url
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

NOTIFY pgrst, 'reload schema';
