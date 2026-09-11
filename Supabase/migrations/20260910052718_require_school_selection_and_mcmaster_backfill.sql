-- User-authorized one-time school normalization + required explicit onboarding choice.
-- Scope: profiles only; never modify post school IDs, immutable forum origins,
-- auth credentials, account-deactivation markers or verification status.
-- Backup: changed rows are captured below in a non-exposed, service-only schema
-- before UPDATE in the same transaction. Take the regular project backup first
-- if applying outside the audited project. No rows are deleted.
-- Rollback: use backup only after reviewing subsequent user school changes;
-- restore the prior complete_profile from migration 147 in a NEW migration and
-- remove the added trigger. Dropping backup data loses per-user pre-change values.
-- Order: apply backend -> install new App build with required school picker.
BEGIN;
SET LOCAL lock_timeout='5s';
LOCK TABLE public.profiles IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.schools WHERE name='McMaster University' AND active) THEN
  RAISE EXCEPTION 'Active McMaster school seed required'; END IF;
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid='public.complete_profile(text,text,text,text,text,text)'::regprocedure)
   <> '546e7297e4b266a08f8008a47a4b37ab' THEN
  RAISE EXCEPTION 'Profile completion changed; re-audit before replacing'; END IF;
END $$;

CREATE SCHEMA school_selection_private;
REVOKE ALL ON SCHEMA school_selection_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA school_selection_private TO service_role;
CREATE TABLE school_selection_private.mcmaster_backfill_backup (
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 school_id uuid, university text, campus_id uuid,
 captured_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE school_selection_private.mcmaster_backfill_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON school_selection_private.mcmaster_backfill_backup FROM PUBLIC,anon,authenticated;
GRANT SELECT ON school_selection_private.mcmaster_backfill_backup TO service_role;
INSERT INTO school_selection_private.mcmaster_backfill_backup(user_id,school_id,university,campus_id)
SELECT p.id,p.school_id,p.university,p.campus_id FROM public.profiles p
JOIN public.schools s ON s.name='McMaster University'
WHERE p.school_id IS DISTINCT FROM s.id
 OR (p.deactivated_at IS NULL AND p.university IS DISTINCT FROM s.name);

-- Only change mismatches. Existing deactivated accounts retain their redacted text.
UPDATE public.profiles p SET school_id=s.id,campus_id=(SELECT c.id FROM public.school_campuses c
 WHERE c.school_id=s.id AND c.is_default ORDER BY c.id LIMIT 1)
FROM public.schools s WHERE s.name='McMaster University' AND p.school_id IS DISTINCT FROM s.id;
UPDATE public.profiles p SET university=CASE WHEN p.deactivated_at IS NULL THEN s.name ELSE b.university END
FROM public.schools s,school_selection_private.mcmaster_backfill_backup b
WHERE s.name='McMaster University' AND p.id=b.user_id
 AND p.university IS DISTINCT FROM CASE WHEN p.deactivated_at IS NULL THEN s.name ELSE b.university END;

CREATE OR REPLACE FUNCTION public.complete_profile(
 p_full_name text DEFAULT NULL,p_university text DEFAULT NULL,p_gender text DEFAULT NULL,
 p_occupation text DEFAULT NULL,p_bio text DEFAULT NULL,p_avatar_url text DEFAULT NULL
) RETURNS public.profiles LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth,pg_temp AS $$
DECLARE uid uuid:=auth.uid(); gender_value text:=nullif(btrim(p_gender),'');
 school public.schools%ROWTYPE; result public.profiles;
BEGIN
 IF uid IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 IF nullif(btrim(p_university),'') IS NULL THEN
  RAISE EXCEPTION 'School is required' USING ERRCODE='22023'; END IF;
 SELECT * INTO school FROM public.schools WHERE active AND lower(name)=lower(btrim(p_university));
 IF NOT FOUND THEN RAISE EXCEPTION 'Select a supported school' USING ERRCODE='22023'; END IF;
 IF gender_value IS NULL OR gender_value NOT IN ('male','female','non_binary','prefer_not_to_say') THEN
  RAISE EXCEPTION 'Valid gender is required' USING ERRCODE='22023'; END IF;
 UPDATE public.profiles SET full_name=coalesce(nullif(btrim(p_full_name),''),full_name),
  university=school.name,school_id=school.id,
  campus_id=(SELECT c.id FROM public.school_campuses c WHERE c.school_id=school.id AND c.is_default ORDER BY c.id LIMIT 1),
  gender=gender_value,occupation=nullif(btrim(p_occupation),''),
  bio=coalesce(nullif(btrim(p_bio),''),bio),avatar_url=coalesce(nullif(btrim(p_avatar_url),''),avatar_url),
  profile_completed=true,updated_at=clock_timestamp()
 WHERE id=uid AND deactivated_at IS NULL RETURNING * INTO result;
 IF NOT FOUND THEN RAISE EXCEPTION 'Active profile not found' USING ERRCODE='P0002'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.complete_profile(text,text,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complete_profile(text,text,text,text,text,text) TO authenticated,service_role;

-- Invoker rights intentionally distinguish direct client writes from the
-- validated SECURITY DEFINER completion RPC. Anonymous metadata is not trusted.
CREATE FUNCTION school_selection_private.enforce_completed_school()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF NEW.deactivated_at IS NOT NULL THEN RETURN NEW; END IF;
 IF NEW.profile_completed THEN
  IF current_user IN ('authenticated','anon') AND
    (TG_OP='INSERT' OR OLD.profile_completed IS DISTINCT FROM true) THEN
   RAISE EXCEPTION 'Complete profile through the validated completion form' USING ERRCODE='42501';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.schools s WHERE s.id=NEW.school_id AND s.active AND s.name=NEW.university) THEN
   RAISE EXCEPTION 'A completed profile requires a valid matching school' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION school_selection_private.enforce_completed_school() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_enforce_completed_profile_school
BEFORE INSERT OR UPDATE OF profile_completed,school_id,university ON public.profiles
FOR EACH ROW EXECUTE FUNCTION school_selection_private.enforce_completed_school();
NOTIFY pgrst,'reload schema';
COMMIT;
