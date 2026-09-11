-- App Store safety boundary. New migration; historical deactivation is unchanged.
-- Destructive data: removes residual identity/contact metadata and credentials of
-- already deactivated accounts; purges their verification records and push tokens.
-- Back up DB and Storage before production. PII erasure is irreversible without
-- that protected backup; never restore erased identities as a routine rollback.
-- Deploy Worker/app support first, then migrate, verify permissions and moderation
-- tests, then distribute the new client. Keep release blocked until media scanning
-- and operational reviewer staffing are verified. Existing reports are retained.
BEGIN;
-- Active accounts still require a school; erased tombstones must not retain it.
ALTER TABLE public.profiles ALTER COLUMN school_id DROP NOT NULL;
ALTER TABLE public.profiles ADD CONSTRAINT active_profile_requires_school
 CHECK(deactivated_at IS NOT NULL OR school_id IS NOT NULL);
CREATE SCHEMA IF NOT EXISTS moderation_private;
REVOKE ALL ON SCHEMA moderation_private FROM PUBLIC, anon, authenticated;

CREATE TABLE moderation_private.account_media_cleanup (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL,
 bucket text NOT NULL CHECK(bucket='avatars'), object_path text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz,
 locked_at timestamptz, lock_token uuid, attempt_count integer NOT NULL DEFAULT 0,
 last_error_code text, UNIQUE(bucket,object_path)
);
ALTER TABLE moderation_private.account_media_cleanup ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION public.claim_account_media_cleanup_batch(p_limit integer,p_lock_token uuid)
RETURNS TABLE(cleanup_id uuid,bucket text,object_path text,attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF p_lock_token IS NULL THEN RAISE EXCEPTION 'lock_token_required'; END IF;
 RETURN QUERY WITH candidates AS (
 SELECT q.id FROM moderation_private.account_media_cleanup q
 WHERE q.resolved_at IS NULL AND (q.locked_at IS NULL OR q.locked_at < now()-interval '5 minutes')
 ORDER BY q.created_at FOR UPDATE SKIP LOCKED LIMIT least(greatest(coalesce(p_limit,20),1),50)
 ) UPDATE moderation_private.account_media_cleanup q SET locked_at=now(),lock_token=p_lock_token,attempt_count=q.attempt_count+1
 FROM candidates WHERE q.id=candidates.id RETURNING q.id,q.bucket,q.object_path,q.attempt_count;
END;
$$;
CREATE FUNCTION public.complete_account_media_cleanup_job(p_cleanup_id uuid,p_lock_token uuid,p_succeeded boolean,p_error_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 UPDATE moderation_private.account_media_cleanup SET resolved_at=CASE WHEN p_succeeded THEN now() END,
  last_error_code=left(regexp_replace(coalesce(p_error_code,''),'[^a-zA-Z0-9_.:-]','_','g'),120),
  locked_at=CASE WHEN p_succeeded THEN NULL ELSE now() END,lock_token=NULL
 WHERE id=p_cleanup_id AND lock_token=p_lock_token;
 RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_account_media_cleanup_batch(integer,uuid),public.complete_account_media_cleanup_job(uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_account_media_cleanup_batch(integer,uuid),public.complete_account_media_cleanup_job(uuid,uuid,boolean,text) TO service_role;

CREATE TABLE moderation_private.suspensions (
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 reviewer_id uuid NOT NULL,
 reason text NOT NULL
);
ALTER TABLE moderation_private.suspensions ENABLE ROW LEVEL SECURITY;
CREATE TABLE moderation_private.audit_log (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 reviewer_id uuid NOT NULL, report_kind text NOT NULL, report_id uuid NOT NULL,
 action text NOT NULL, note text NOT NULL CHECK (length(note) BETWEEN 5 AND 1000),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE moderation_private.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_reports ADD COLUMN status text NOT NULL DEFAULT 'pending'
 CHECK (status IN ('pending','reviewing','resolved','dismissed'));

CREATE FUNCTION moderation_private.require_admin() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS (
  SELECT 1 FROM public.content_studio_roles r JOIN public.profiles p ON p.id = r.user_id
  WHERE r.user_id = auth.uid() AND r.role = 'admin' AND p.deactivated_at IS NULL
 ) THEN RAISE EXCEPTION 'moderation_access_denied' USING ERRCODE = '42501'; END IF;
END;
$$;

-- Deterministic first-line filtering also runs on direct REST/RPC writes. No
-- client bypass flag and no exception for service-role generated UGC.
CREATE FUNCTION moderation_private.check_text(p_text text) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE t text := lower(normalize(coalesce(p_text,''), NFKC));
BEGIN
 t := regexp_replace(t, '[​‌‍﻿]', '', 'g');
 IF length(t) > 20000 THEN RAISE EXCEPTION 'content_too_long' USING ERRCODE = '22023'; END IF;
 IF t ~ '(child[[:space:]_-]*porn|rape[[:space:]]+you|kill[[:space:]]+yourself|kill[[:space:]]+all[[:space:]]|buy[[:space:]]+(cocaine|heroin)|sell[[:space:]]+(cocaine|heroin)|儿童色情|幼童色情|未成年裸照|去死吧|我要杀了你|出售毒品|代开发票|裸聊交易)'
 OR t ~ '(https?://)?(bit[.]ly|tinyurl[.]com|t[.]me)/'
 OR t ~ '((guaranteed|稳赚)[[:space:]]*(profit|收益)|free[[:space:]]+crypto[[:space:]]+giveaway)'
 THEN RAISE EXCEPTION 'content_not_allowed' USING ERRCODE = '22023'; END IF;
END;
$$;

CREATE FUNCTION moderation_private.filter_ugc() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE row_data jsonb := to_jsonb(NEW); field text; actor uuid := auth.uid();
BEGIN
 IF actor IS NOT NULL AND (EXISTS (SELECT 1 FROM moderation_private.suspensions WHERE user_id=actor)
 OR EXISTS (SELECT 1 FROM public.profiles WHERE id=actor AND deactivated_at IS NOT NULL))
 THEN RAISE EXCEPTION 'account_restricted' USING ERRCODE='42501'; END IF;
 FOREACH field IN ARRAY TG_ARGV LOOP
  IF TG_OP = 'INSERT' OR row_data->field IS DISTINCT FROM to_jsonb(OLD)->field THEN
   PERFORM moderation_private.check_text(row_data->>field);
  END IF;
 END LOOP;
 RETURN NEW;
END;
$$;
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.posts FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('title','description');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.comments FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('content');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.messages FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('content');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.group_messages FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('content');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('full_name','bio','wechat_id');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.chat_groups FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('name','announcement');
CREATE TRIGGER safety_filter BEFORE INSERT OR UPDATE ON public.chat_group_members FOR EACH ROW
 EXECUTE FUNCTION moderation_private.filter_ugc('nickname');

CREATE FUNCTION public.moderation_queue(p_limit integer DEFAULT 100)
RETURNS TABLE (kind text, id uuid, reason text, details text, status text,
 created_at timestamptz, target_id uuid, content text, due_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM moderation_private.require_admin();
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
 RETURN QUERY SELECT q.*, q.created_at + CASE WHEN q.reason IN ('harassment','inappropriate')
  THEN interval '4 hours' ELSE interval '24 hours' END
 FROM (
 SELECT 'post'::text, r.id,r.reason,r.details,r.status,r.created_at,r.post_id,
  left(coalesce(p.title,'') || E'\n' || coalesce(p.description,''),4000) FROM public.post_reports r LEFT JOIN public.posts p ON p.id=r.post_id
 UNION ALL SELECT 'comment',r.id,r.reason,r.details,r.status,r.created_at,r.comment_id,left(c.content,4000)
 FROM public.comment_reports r LEFT JOIN public.comments c ON c.id=r.comment_id
 UNION ALL SELECT 'message',r.id,r.reason,r.details,r.status,r.created_at,coalesce(r.direct_message_id,r.group_message_id),
 left(coalesce(m.content,g.content),4000) FROM public.message_reports r LEFT JOIN public.messages m ON m.id=r.direct_message_id
 LEFT JOIN public.group_messages g ON g.id=r.group_message_id
 UNION ALL SELECT 'user',r.id,r.reason,r.details,r.status,r.created_at,r.reported_user_id,left(p.full_name,4000)
 FROM public.user_reports r LEFT JOIN public.profiles p ON p.id=r.reported_user_id
 ) AS q(kind,id,reason,details,status,created_at,target_id,content)
 WHERE q.status IN ('pending','reviewing') ORDER BY q.created_at LIMIT p_limit;
END;
$$;

-- Only the administrator and the reported object determine which media can be read.
CREATE FUNCTION public.moderation_report_media(p_kind text,p_id uuid)
RETURNS TABLE(bucket text,object_path text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM moderation_private.require_admin();
 IF p_kind='post' THEN
  RETURN QUERY SELECT i.bucket,i.object_path FROM public.post_reports r
  JOIN public.post_images i ON i.post_id=r.post_id WHERE r.id=p_id AND i.bucket='post-images' AND i.object_path IS NOT NULL;
 ELSIF p_kind='message' THEN
  RETURN QUERY SELECT coalesce(m.metadata,g.metadata)->>'image_bucket',coalesce(m.metadata,g.metadata)->>'image_object_path'
  FROM public.message_reports r LEFT JOIN public.messages m ON m.id=r.direct_message_id
  LEFT JOIN public.group_messages g ON g.id=r.group_message_id
  WHERE r.id=p_id AND coalesce(m.metadata,g.metadata)->>'image_bucket'='chat-images';
 ELSIF p_kind='user' THEN
  RETURN QUERY SELECT 'avatars'::text,replace(v.url,'https://zeuivahkowbxmfzsnagt.supabase.co/storage/v1/object/public/avatars/','')
  FROM public.user_reports r JOIN public.profiles p ON p.id=r.reported_user_id
  CROSS JOIN LATERAL (VALUES(p.avatar_url),(p.cover_image_url)) v(url)
  WHERE r.id=p_id AND v.url LIKE 'https://zeuivahkowbxmfzsnagt.supabase.co/storage/v1/object/public/avatars/%';
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.moderation_report_media(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.moderation_report_media(text,uuid) TO authenticated;

CREATE FUNCTION public.moderation_resolve(p_kind text,p_id uuid,p_action text,p_note text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE t text; r jsonb; target uuid; actor uuid; new_status text;
BEGIN
 PERFORM moderation_private.require_admin();
 IF p_action IS NULL OR p_note IS NULL OR p_action NOT IN ('review','dismiss','remove','suspend') OR length(btrim(p_note)) NOT BETWEEN 5 AND 1000
 THEN RAISE EXCEPTION 'invalid_moderation_action' USING ERRCODE='22023'; END IF;
 t := CASE p_kind WHEN 'post' THEN 'post_reports' WHEN 'comment' THEN 'comment_reports'
 WHEN 'message' THEN 'message_reports' WHEN 'user' THEN 'user_reports' END;
 IF t IS NULL THEN RAISE EXCEPTION 'invalid_report_kind'; END IF;
 EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE id=$1 FOR UPDATE',t) INTO r USING p_id;
 IF r IS NULL OR r->>'status' NOT IN ('pending','reviewing') THEN RAISE EXCEPTION 'report_not_open'; END IF;
 IF p_kind='post' THEN
  target := (r->>'post_id')::uuid; SELECT user_id INTO actor FROM public.posts WHERE id=target;
  IF p_action='remove' THEN UPDATE public.posts SET status='deleted' WHERE id=target; END IF;
 ELSIF p_kind='comment' THEN
  target := (r->>'comment_id')::uuid; SELECT user_id INTO actor FROM public.comments WHERE id=target;
  IF p_action='remove' THEN UPDATE public.comments SET is_deleted=true,content='[Removed by moderation]' WHERE id=target; END IF;
 ELSIF p_kind='message' THEN
  IF r->>'direct_message_id' IS NOT NULL THEN
   target := (r->>'direct_message_id')::uuid; SELECT sender_id INTO actor FROM public.messages WHERE id=target;
   IF p_action='remove' THEN UPDATE public.messages SET is_deleted=true,content='[Removed by moderation]',metadata='{}'::jsonb WHERE id=target; END IF;
  ELSE
   target := (r->>'group_message_id')::uuid; SELECT sender_id INTO actor FROM public.group_messages WHERE id=target;
   IF p_action='remove' THEN UPDATE public.group_messages SET is_deleted=true,content='[Removed by moderation]',metadata='{}'::jsonb WHERE id=target; END IF;
  END IF;
 ELSE
  actor := (r->>'reported_user_id')::uuid;
  IF p_action='remove' THEN RAISE EXCEPTION 'use_suspend_for_user_report'; END IF;
 END IF;
 IF p_action='suspend' THEN
  IF actor IS NULL OR actor=auth.uid() THEN RAISE EXCEPTION 'invalid_suspension_target'; END IF;
  INSERT INTO moderation_private.suspensions(user_id,reviewer_id,reason) VALUES(actor,auth.uid(),p_note)
   ON CONFLICT(user_id) DO UPDATE SET reviewer_id=excluded.reviewer_id,reason=excluded.reason;
  UPDATE auth.users SET banned_until=now()+interval '100 years' WHERE auth.users.id=actor;
  DELETE FROM auth.sessions WHERE user_id=actor;
 END IF;
 new_status := CASE p_action WHEN 'review' THEN 'reviewing' WHEN 'dismiss' THEN 'dismissed' ELSE 'resolved' END;
 EXECUTE format('UPDATE public.%I SET status=$1 WHERE id=$2',t) USING new_status,p_id;
 INSERT INTO moderation_private.audit_log(reviewer_id,report_kind,report_id,action,note)
 VALUES(auth.uid(),p_kind,p_id,p_action,btrim(p_note));
 RETURN true;
END;
$$;
CREATE FUNCTION public.moderation_restore_user(p_user_id uuid,p_note text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM moderation_private.require_admin();
 IF p_note IS NULL OR length(btrim(p_note)) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'review_note_required'; END IF;
 DELETE FROM moderation_private.suspensions WHERE user_id=p_user_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'no_moderation_suspension'; END IF;
 UPDATE auth.users u SET banned_until=NULL FROM public.profiles p
 WHERE u.id=p_user_id AND p.id=u.id AND p.deactivated_at IS NULL;
 INSERT INTO moderation_private.audit_log(reviewer_id,report_kind,report_id,action,note)
 VALUES(auth.uid(),'user',p_user_id,'restore',p_note);
 RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.moderation_restore_user(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.moderation_restore_user(uuid,text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA moderation_private FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.moderation_queue(integer),public.moderation_resolve(text,uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.moderation_queue(integer),public.moderation_resolve(text,uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_group_id UUID;
  v_now TIMESTAMPTZ := NOW();
  v_tombstone_email TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO moderation_private.account_media_cleanup(user_id,bucket,object_path)
  SELECT v_user_id,o.bucket_id,o.name FROM storage.objects o
  WHERE o.bucket_id='avatars' AND (o.owner=v_user_id OR split_part(o.name,'/',1)=v_user_id::text)
  ON CONFLICT(bucket,object_path) DO NOTHING;
  DELETE FROM moderation_private.suspensions WHERE user_id=v_user_id;

  v_tombstone_email := format(
    'deactivated+%s@deleted.cheeseapp.local',
    replace(v_user_id::text, '-', '')
  );

  FOR v_group_id IN
    SELECT gm.group_id
    FROM public.chat_group_members gm
    WHERE gm.user_id = v_user_id
  LOOP
    BEGIN
      PERFORM public.leave_chat_group(v_group_id);
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.chat_group_members
      WHERE group_id = v_group_id
        AND user_id = v_user_id;
    END;
  END LOOP;

  DELETE FROM public.user_chat_group_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_conversation_settings
  WHERE user_id = v_user_id;

  DELETE FROM public.user_blocks
  WHERE blocker_id = v_user_id
     OR blocked_id = v_user_id;

  DELETE FROM public.user_reports
  WHERE reporter_id = v_user_id
     OR reported_user_id = v_user_id;

  DELETE FROM public.user_follows
  WHERE follower_id = v_user_id
     OR following_id = v_user_id;

  -- Keep authored comments on posts that remain after deactivation. The later
  -- post deletion still cascades comments belonging to the user's own posts.
  UPDATE public.comments
  SET
    author_is_deactivated = TRUE,
    updated_at = v_now
  WHERE user_id = v_user_id;

  DELETE FROM public.likes
  WHERE user_id = v_user_id;

  DELETE FROM public.favorites
  WHERE user_id = v_user_id;

  DELETE FROM public.view_history
  WHERE user_id = v_user_id;

  DELETE FROM public.posts
  WHERE user_id = v_user_id;

  UPDATE public.profiles
  SET
    email = v_tombstone_email,
    full_name = '已注销',
    avatar_url = NULL,
    cover_image_url = NULL, phone = NULL, student_id = NULL, major = NULL,
    wechat_id = NULL, gender = NULL, occupation = NULL, grad_year = NULL,
    school_id = NULL, campus_id = NULL, is_mcmaster_verified = FALSE,
    university = '已注销',
    bio = '此账号已注销',
    verified = FALSE,
    is_anonymous = FALSE,
    deactivated_at = v_now,
    updated_at = v_now
  WHERE id = v_user_id;

  UPDATE auth.users
  SET
    email = v_tombstone_email,
    phone = NULL,
    banned_until = v_now + INTERVAL '100 years',
    updated_at = v_now,
    email_change='',phone_change='',confirmation_token='',recovery_token='',
    email_change_token_new='',email_change_token_current='',phone_change_token='',reauthentication_token='',
    encrypted_password = '',
    raw_app_meta_data = '{}'::jsonb,
    raw_user_meta_data = jsonb_build_object('deactivated_at', v_now)
  WHERE id = v_user_id;

  DELETE FROM auth.sessions
  WHERE user_id = v_user_id;

  DELETE FROM auth.identities
  WHERE user_id = v_user_id;

  DELETE FROM public.user_push_tokens WHERE user_id = v_user_id;
  DELETE FROM public.user_notification_preferences WHERE user_id = v_user_id;
  DELETE FROM public.mcmaster_email_challenges WHERE user_id = v_user_id;
  DELETE FROM public.mcmaster_student_verifications WHERE user_id = v_user_id;
  DELETE FROM auth.mfa_factors WHERE user_id = v_user_id;
  DELETE FROM auth.one_time_tokens WHERE user_id = v_user_id;
  RETURN TRUE;
END;
$$;
-- Erase pre-existing residual PII too, rather than only protecting future deletes.
UPDATE public.profiles SET cover_image_url=NULL,phone=NULL,student_id=NULL,major=NULL,
 wechat_id=NULL,gender=NULL,occupation=NULL,grad_year=NULL,school_id=NULL,campus_id=NULL,
 is_mcmaster_verified=false WHERE deactivated_at IS NOT NULL;
INSERT INTO moderation_private.account_media_cleanup(user_id,bucket,object_path)
 SELECT p.id,o.bucket_id,o.name FROM public.profiles p JOIN storage.objects o
 ON (o.owner=p.id OR split_part(o.name,'/',1)=p.id::text) AND o.bucket_id='avatars'
 WHERE p.deactivated_at IS NOT NULL ON CONFLICT(bucket,object_path) DO NOTHING;
UPDATE auth.users u SET email_change='',phone_change='',confirmation_token='',recovery_token='',
 email_change_token_new='',email_change_token_current='',phone_change_token='',reauthentication_token='',raw_user_meta_data=jsonb_build_object('deactivated_at',p.deactivated_at),
 raw_app_meta_data='{}'::jsonb,encrypted_password='',phone=NULL
 FROM public.profiles p WHERE p.id=u.id AND p.deactivated_at IS NOT NULL;
DELETE FROM public.user_push_tokens WHERE user_id IN (SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL);
DELETE FROM public.mcmaster_email_challenges WHERE user_id IN (SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL);
DELETE FROM public.mcmaster_student_verifications WHERE user_id IN (SELECT id FROM public.profiles WHERE deactivated_at IS NOT NULL);
REVOKE ALL ON FUNCTION public.touch_cheese_ai_interaction_updated_at() FROM PUBLIC,anon,authenticated;
ALTER VIEW public.forum_posts_view SET (security_barrier=true);
ALTER VIEW public.profile_public_view SET (security_barrier=true);
NOTIFY pgrst, 'reload schema';
COMMIT;
