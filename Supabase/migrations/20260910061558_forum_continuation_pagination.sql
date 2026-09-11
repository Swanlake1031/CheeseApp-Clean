-- Additive browsing continuation; no ranking/model/weight changes or data deletion.
-- Deploy before the client. Rollback: stop client use before dropping this RPC
-- in a new migration. Existing V2 sessions and their event positions stay intact.
BEGIN;
CREATE FUNCTION public.get_forum_continuation_page(
 p_excluded_ids uuid[] DEFAULT '{}',
 p_before_time timestamptz DEFAULT NULL,
 p_before_id uuid DEFAULT NULL,
 p_limit integer DEFAULT 20
) RETURNS TABLE(post_id uuid, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth,pg_temp AS $$
DECLARE viewer uuid := auth.uid();
BEGIN
 IF viewer IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 IF coalesce(cardinality(p_excluded_ids),0)>100 THEN
  RAISE EXCEPTION 'At most 100 initial exclusions' USING ERRCODE='22023'; END IF;
 IF (p_before_time IS NULL) <> (p_before_id IS NULL) THEN
  RAISE EXCEPTION 'Both cursor fields are required' USING ERRCODE='22023'; END IF;
 RETURN QUERY
 SELECT p.id,p.created_at
 FROM public.posts p
 JOIN public.forum_posts f ON f.id=p.id
 JOIN public.forum_boards b ON b.id=f.board_id
 WHERE p.type='forum' AND p.status='active' AND NOT p.is_private
   AND b.status<>'archived'
   AND public.can_view_post(p.id)
   AND recommendation_private.allowed(p.id,viewer)
   AND NOT EXISTS(SELECT 1 FROM unnest(p_excluded_ids) excluded(id) WHERE excluded.id=p.id)
   AND NOT EXISTS(SELECT 1 FROM public.user_hidden_forum_posts h WHERE h.user_id=viewer AND h.post_id=p.id)
   AND NOT EXISTS(SELECT 1 FROM public.user_blocks ub
     WHERE (ub.blocker_id=viewer AND ub.blocked_id=p.user_id)
        OR (ub.blocker_id=p.user_id AND ub.blocked_id=viewer))
   AND (p_before_time IS NULL OR (p.created_at,p.id)<(p_before_time,p_before_id))
 ORDER BY p.created_at DESC,p.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,20),20));
END;
$$;
REVOKE ALL ON FUNCTION public.get_forum_continuation_page(uuid[],timestamptz,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_forum_continuation_page(uuid[],timestamptz,uuid,integer) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
