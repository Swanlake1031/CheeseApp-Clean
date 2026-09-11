-- Media safety is a separate, disclosed service, independent of optional Gemini.
-- No original user data is deleted. Prior receipts retain their original model.
-- Deploy the supporting Worker/client; apply after 20260911185013 before upload.
BEGIN;
ALTER TABLE public.moderated_media ADD COLUMN consent_version text;
CREATE OR REPLACE FUNCTION public.can_upload_moderated_media(p_bucket text,p_path text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE u uuid:=auth.uid();
BEGIN
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=u AND deactivated_at IS NULL)
 OR EXISTS(SELECT 1 FROM moderation_private.suspensions WHERE user_id=u)

 THEN RETURN false; END IF;
 RETURN CASE p_bucket
 WHEN 'avatars' THEN split_part(p_path,'/',1)=u::text
 WHEN 'post-images' THEN public.can_write_staged_post_media_object(p_path)
 WHEN 'chat-images' THEN public.can_write_chat_media_object(p_path)
 ELSE false END;
END;
$$;
REVOKE ALL ON FUNCTION public.can_upload_moderated_media(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_upload_moderated_media(text,text) TO authenticated;
COMMIT;
