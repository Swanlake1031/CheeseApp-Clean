-- Mandatory pre-upload image review and explicit per-account AI permission.
-- Rollout: deploy supporting Worker and client, then apply this boundary before
-- distributing the client. Old clients can browse but cannot upload raw images.
-- No existing object is deleted or marked approved. Existing references remain
-- readable and require an operational legacy-content review before release.
-- Back up DB/Storage before production. Roll back with a new migration; do not
-- weaken Storage permissions while continuing to claim prepublication filtering.
BEGIN;
CREATE TABLE public.moderated_media (
 bucket text NOT NULL CHECK(bucket IN ('avatars','post-images','chat-images')),
 object_path text NOT NULL, user_id uuid NOT NULL REFERENCES public.profiles(id),
 sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'), model text NOT NULL,
 reviewed_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(bucket,object_path)
);
ALTER TABLE public.moderated_media ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderated_media FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.moderated_media TO service_role;
CREATE TABLE public.ai_processing_consents (
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id),
 version text NOT NULL CHECK(version='2026-09-11'),
 accepted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ai_processing_consents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ai_processing_consents FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ai_processing_consents TO authenticated;
GRANT ALL ON public.ai_processing_consents TO service_role;
CREATE POLICY own_consent ON public.ai_processing_consents FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid()));
CREATE FUNCTION public.set_my_ai_consent(p_allowed boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE u uuid:=auth.uid(); post_id uuid;
BEGIN
 IF u IS NULL OR p_allowed IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=u AND deactivated_at IS NULL)
 THEN RAISE EXCEPTION 'authentication_required' USING ERRCODE='42501'; END IF;
 IF p_allowed THEN
  INSERT INTO public.ai_processing_consents(user_id,version) VALUES(u,'2026-09-11')
   ON CONFLICT(user_id) DO UPDATE SET version=excluded.version,accepted_at=now();
  FOR post_id IN SELECT id FROM public.posts WHERE user_id=u AND type='forum' LOOP
   PERFORM public.enqueue_forum_post_embedding(post_id);
  END LOOP;
 ELSE
  DELETE FROM public.ai_processing_consents WHERE user_id=u;
  DELETE FROM public.post_embeddings WHERE post_embeddings.post_id IN(SELECT id FROM public.posts WHERE user_id=u);
 END IF;
 RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.set_my_ai_consent(boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_my_ai_consent(boolean) TO authenticated;
CREATE FUNCTION public.can_upload_moderated_media(p_bucket text,p_path text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE u uuid:=auth.uid();
BEGIN
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=u AND deactivated_at IS NULL)
 OR EXISTS(SELECT 1 FROM moderation_private.suspensions WHERE user_id=u)
 OR NOT EXISTS(SELECT 1 FROM public.ai_processing_consents WHERE user_id=u AND version='2026-09-11')
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
-- Restrictive policies combine with every existing permissive upload policy.
CREATE POLICY moderation_requires_server_upload ON storage.objects AS RESTRICTIVE
 FOR INSERT TO authenticated WITH CHECK(bucket_id NOT IN ('avatars','post-images','chat-images'));
CREATE POLICY moderation_requires_immutable_objects ON storage.objects AS RESTRICTIVE
 FOR UPDATE TO authenticated USING(bucket_id NOT IN ('avatars','post-images','chat-images'))
 WITH CHECK(bucket_id NOT IN ('avatars','post-images','chat-images'));
CREATE FUNCTION public.owns_moderated_media(p_bucket text,p_path text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.moderated_media WHERE bucket=p_bucket AND object_path=p_path AND user_id=auth.uid());
$$;
REVOKE ALL ON FUNCTION public.owns_moderated_media(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.owns_moderated_media(text,text) TO authenticated;
CREATE POLICY owner_can_delete_moderated_media ON storage.objects FOR DELETE TO authenticated
 USING(public.owns_moderated_media(bucket_id,name));
CREATE FUNCTION moderation_private.require_media(p_bucket text,p_path text,p_owner uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF p_bucket IS NULL OR p_path IS NULL OR NOT EXISTS(
 SELECT 1 FROM public.moderated_media m WHERE m.bucket=p_bucket AND m.object_path=p_path AND m.user_id=p_owner)
 THEN RAISE EXCEPTION 'media_review_required' USING ERRCODE='22023'; END IF;
END;
$$;
CREATE FUNCTION moderation_private.filter_media_reference() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE n jsonb:=to_jsonb(NEW); o jsonb:='{}'::jsonb; owner_id uuid; field text; media_url text; media_path text;
BEGIN
 IF TG_OP='UPDATE' THEN o:=to_jsonb(OLD); END IF;
 IF TG_TABLE_NAME='post_images' THEN
  IF n->'url' IS DISTINCT FROM o->'url' OR n->'object_path' IS DISTINCT FROM o->'object_path' OR n->'bucket' IS DISTINCT FROM o->'bucket' THEN
   SELECT user_id INTO owner_id FROM public.posts WHERE id=NEW.post_id;
   PERFORM moderation_private.require_media(NEW.bucket,NEW.object_path,owner_id);
   IF NEW.url IS DISTINCT FROM 'https://zeuivahkowbxmfzsnagt.supabase.co/storage/v1/object/public/'||NEW.bucket||'/'||NEW.object_path
   THEN RAISE EXCEPTION 'invalid_media_url'; END IF;
  END IF;
 ELSIF TG_TABLE_NAME IN ('messages','group_messages') THEN
  IF n->'metadata' IS DISTINCT FROM o->'metadata' AND n->>'message_type'='image' AND NOT coalesce((n->>'is_deleted')::boolean,false) THEN
   PERFORM moderation_private.require_media(n->'metadata'->>'image_bucket',n->'metadata'->>'image_object_path',(n->>'sender_id')::uuid);
   IF nullif(n->'metadata'->>'image_url','') IS NOT NULL THEN RAISE EXCEPTION 'legacy_image_url_not_allowed'; END IF;
  END IF;
 ELSE
  owner_id:=CASE WHEN TG_TABLE_NAME='profiles' THEN (n->>'id')::uuid ELSE (n->>'owner_id')::uuid END;
  FOREACH field IN ARRAY TG_ARGV LOOP
   media_url:=nullif(n->>field,'');
   IF media_url IS NOT NULL AND n->field IS DISTINCT FROM o->field THEN
    -- Signup metadata can be user-controlled even when Auth runs the INSERT.
    -- Start with a placeholder; never import an unreviewed external image.
    IF TG_TABLE_NAME='profiles' AND TG_OP='INSERT' AND auth.uid() IS NULL THEN
      IF field='avatar_url' THEN NEW.avatar_url:=NULL; ELSE NEW.cover_image_url:=NULL; END IF;
      CONTINUE;
    END IF;
    media_path:=replace(media_url,'https://zeuivahkowbxmfzsnagt.supabase.co/storage/v1/object/public/avatars/','');
    IF media_path=media_url THEN RAISE EXCEPTION 'media_review_required'; END IF;
    PERFORM moderation_private.require_media('avatars',media_path,owner_id);
   END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER reviewed_media BEFORE INSERT OR UPDATE ON public.post_images FOR EACH ROW EXECUTE FUNCTION moderation_private.filter_media_reference();
CREATE TRIGGER reviewed_media BEFORE INSERT OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION moderation_private.filter_media_reference();
CREATE TRIGGER reviewed_media BEFORE INSERT OR UPDATE ON public.group_messages FOR EACH ROW EXECUTE FUNCTION moderation_private.filter_media_reference();
CREATE TRIGGER reviewed_media BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION moderation_private.filter_media_reference('avatar_url','cover_image_url');
CREATE TRIGGER reviewed_media BEFORE INSERT OR UPDATE ON public.chat_groups FOR EACH ROW EXECUTE FUNCTION moderation_private.filter_media_reference('avatar_url');
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA moderation_private FROM PUBLIC,anon,authenticated;
-- Deactivation removes permission immediately, including automatic AI processing.
CREATE FUNCTION moderation_private.erase_ai_consent_on_deactivation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF NEW.deactivated_at IS NOT NULL THEN DELETE FROM public.ai_processing_consents WHERE user_id=NEW.id; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER erase_ai_consent AFTER UPDATE OF deactivated_at ON public.profiles FOR EACH ROW EXECUTE FUNCTION moderation_private.erase_ai_consent_on_deactivation();
REVOKE ALL ON FUNCTION moderation_private.erase_ai_consent_on_deactivation() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.claim_post_embedding_jobs(
  p_limit INTEGER DEFAULT 8
)
RETURNS TABLE (
  job_id UUID,
  post_id UUID,
  input_hash TEXT,
  embedding_version TEXT,
  model TEXT,
  input_format_version INTEGER,
  embedding_input TEXT,
  attempt INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH claimable AS (
    SELECT job.id
    FROM public.post_embedding_jobs job
    WHERE job.attempts < 12
      AND EXISTS(SELECT 1 FROM public.posts p JOIN public.ai_processing_consents c ON c.user_id=p.user_id
                 WHERE p.id=job.post_id AND c.version='2026-09-11')
      AND (
        (job.status IN ('pending', 'failed') AND job.next_retry_at <= clock_timestamp())
        OR (job.status = 'processing' AND job.locked_at < clock_timestamp() - INTERVAL '5 minutes')
      )
    ORDER BY job.next_retry_at, job.created_at, job.id
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 8), 32))
  ), claimed AS (
    UPDATE public.post_embedding_jobs job
    SET
      status = 'processing',
      attempts = job.attempts + 1,
      locked_at = clock_timestamp(),
      updated_at = clock_timestamp(),
      last_error = NULL
    FROM claimable
    WHERE job.id = claimable.id
    RETURNING job.*
  )
  SELECT
    claimed.id,
    claimed.post_id,
    claimed.input_hash,
    claimed.embedding_version,
    claimed.model,
    claimed.input_format_version,
    current_input.embedding_input,
    claimed.attempts
  FROM claimed
  JOIN LATERAL public.recommendation_embedding_input(claimed.post_id)
    current_input ON current_input.input_hash = claimed.input_hash
      AND current_input.embedding_version = claimed.embedding_version;

  UPDATE public.post_embedding_jobs job
  SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
  WHERE job.status = 'processing'
    AND job.locked_at >= clock_timestamp() - INTERVAL '1 minute'
    AND NOT EXISTS (
      SELECT 1
      FROM public.recommendation_embedding_input(job.post_id) current_input
      WHERE current_input.input_hash = job.input_hash
        AND current_input.embedding_version = job.embedding_version
    );
END;
$$;
NOTIFY pgrst,'reload schema';
CREATE OR REPLACE FUNCTION public.complete_post_embedding_job(
  p_job_id UUID,
  p_input_hash TEXT,
  p_embedding REAL[],
  p_norm DOUBLE PRECISION
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_job public.post_embedding_jobs%ROWTYPE;
  v_actual_norm DOUBLE PRECISION;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  SELECT SQRT(SUM(value::DOUBLE PRECISION * value::DOUBLE PRECISION))
  INTO v_actual_norm
  FROM unnest(p_embedding) AS item(value);

  IF COALESCE(array_length(p_embedding, 1), 0) <> 768
     OR p_norm IS NULL
     OR ABS(p_norm - 1.0) > 0.01
     OR v_actual_norm IS NULL
     OR ABS(v_actual_norm - 1.0) > 0.01
     OR v_actual_norm >= 'Infinity'::DOUBLE PRECISION
     OR v_actual_norm = 'NaN'::DOUBLE PRECISION
  THEN
    RAISE EXCEPTION 'Embedding norm or dimension invalid' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_job
  FROM public.post_embedding_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND OR v_job.status <> 'processing'
     OR v_job.input_hash IS DISTINCT FROM p_input_hash
  THEN
    RETURN FALSE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.recommendation_embedding_input(v_job.post_id) current_input
    WHERE current_input.input_hash = v_job.input_hash
      AND current_input.embedding_version = v_job.embedding_version
      AND current_input.model = v_job.model
      AND current_input.input_format_version = v_job.input_format_version
  ) THEN
    UPDATE public.post_embedding_jobs
    SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
    WHERE id = p_job_id;
    RETURN FALSE;
  END IF;

  -- Hold the consent row until commit: a concurrent withdrawal waits, then
  -- deletes these vectors. A withdrawal that won first prevents this write.
  PERFORM 1 FROM public.ai_processing_consents consent
  JOIN public.posts post ON post.user_id = consent.user_id
  WHERE post.id = v_job.post_id AND consent.version = '2026-09-11'
  FOR SHARE OF consent;
  IF NOT FOUND THEN
    UPDATE public.post_embedding_jobs
    SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
    WHERE id = p_job_id;
    RETURN FALSE;
  END IF;

  INSERT INTO public.post_embeddings (
    post_id, embedding_version, embedding, model, input_format_version,
    input_hash, status, generated_at, updated_at, last_error
  )
  VALUES (
    v_job.post_id, v_job.embedding_version, p_embedding::extensions.vector(768),
    v_job.model, v_job.input_format_version, v_job.input_hash, 'ready',
    clock_timestamp(), clock_timestamp(), NULL
  )
  ON CONFLICT (post_id, embedding_version) DO UPDATE
  SET
    embedding = EXCLUDED.embedding,
    model = EXCLUDED.model,
    input_format_version = EXCLUDED.input_format_version,
    input_hash = EXCLUDED.input_hash,
    status = 'ready',
    generated_at = EXCLUDED.generated_at,
    updated_at = EXCLUDED.updated_at,
    last_error = NULL
  WHERE public.post_embeddings.input_hash = EXCLUDED.input_hash;

  IF NOT FOUND THEN
    UPDATE public.post_embedding_jobs
    SET status = 'superseded', locked_at = NULL, updated_at = clock_timestamp()
    WHERE id = p_job_id;
    RETURN FALSE;
  END IF;

  UPDATE public.post_embedding_jobs
  SET status = 'ready', locked_at = NULL, updated_at = clock_timestamp()
  WHERE id = p_job_id;
  RETURN TRUE;
END;
$$;


COMMIT;
