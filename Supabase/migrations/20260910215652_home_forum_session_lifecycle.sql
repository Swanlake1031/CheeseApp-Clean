-- Additive Home lifecycle API. Ranking, ignore policy, shaping, legacy RPCs and
-- continuation are untouched. No data deletion or session invalidation on install.
-- Deploy after prior migrations and before the new client. Rollback via a new
-- migration only after reverting client RPC usage; existing sessions stay usable.
BEGIN;
CREATE FUNCTION recommendation_private.home_post_visible(p_post_id uuid,p_viewer uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.posts p JOIN public.forum_posts f ON f.id=p.id
 JOIN public.forum_boards b ON b.id=f.board_id
 WHERE p.id=p_post_id AND p.type='forum' AND p.status='active' AND NOT p.is_private
 AND b.status<>'archived' AND public.can_view_post(p.id)
 AND recommendation_private.allowed(p.id,p_viewer)
 AND NOT EXISTS(SELECT 1 FROM public.user_hidden_forum_posts h WHERE h.user_id=p_viewer AND h.post_id=p.id)
 AND NOT EXISTS(SELECT 1 FROM public.user_blocks ub
 WHERE (ub.blocker_id=p_viewer AND ub.blocked_id=p.user_id)
 OR (ub.blocker_id=p.user_id AND ub.blocked_id=p_viewer)));
$$;
REVOKE ALL ON FUNCTION recommendation_private.home_post_visible(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.resolve_home_forum_session()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth,pg_temp AS $$
DECLARE viewer uuid:=auth.uid(); chosen public.feed_sessions%ROWTYPE;
 latest public.feed_sessions%ROWTYPE; mode public.recommendation_feed_mode;
 reused boolean:=true; reason text:='valid_session'; new_id uuid; items jsonb;
BEGIN
 IF viewer IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 -- Serialize resolve/create per viewer, including independent processes/devices.
 PERFORM pg_advisory_xact_lock(hashtextextended('home-forum-session:'||viewer::text,20260910));
 PERFORM 1 FROM public.cross_school_configuration WHERE singleton FOR SHARE;
 mode:=public.get_recommendation_feed_mode();
 IF NOT mode.use_recommendations THEN RETURN NULL; END IF;
 SELECT * INTO chosen FROM public.feed_sessions s
 WHERE s.user_id=viewer AND NOT s.is_shadow AND s.expires_at>clock_timestamp()
 AND s.algorithm_version=mode.algorithm_version
 AND recommendation_private.session_valid(s.id)
 AND NOT EXISTS(SELECT 1 FROM public.feed_session_items i WHERE i.session_id=s.id
   AND NOT recommendation_private.home_post_visible(i.post_id,viewer))
 ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
 IF NOT FOUND THEN
  SELECT * INTO latest FROM public.feed_sessions s WHERE s.user_id=viewer AND NOT s.is_shadow
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  reason:=CASE WHEN NOT FOUND THEN 'missing_session'
    WHEN latest.expires_at<=clock_timestamp() THEN 'expired_session' ELSE 'server_policy_invalidated' END;
  reused:=false;
  -- This is the sole Home force-create path: no reusable valid session exists.
  new_id:=public.create_recommendation_feed_session(true,false,NULL);
  IF new_id IS NULL THEN RAISE EXCEPTION 'Recommendation mode changed; retry resolution' USING ERRCODE='P0001'; END IF;
  SELECT * INTO chosen FROM public.feed_sessions WHERE id=new_id;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('session_id',i.session_id,'post_id',i.post_id,'position',i.position)
 ORDER BY i.position),'[]'::jsonb) INTO items FROM public.feed_session_items i
 WHERE i.session_id=chosen.id AND recommendation_private.home_post_visible(i.post_id,viewer);
 RETURN jsonb_build_object('session_id',chosen.id,'created_at',chosen.created_at,'expires_at',chosen.expires_at,
 'reused',reused,'reason',reason,'items',items);
END;
$$;

-- Revalidate cached continuation without moving its cursor or changing its order.
CREATE FUNCTION public.validate_home_forum_posts(p_post_ids uuid[])
RETURNS SETOF uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 IF coalesce(cardinality(p_post_ids),0)>100 THEN RAISE EXCEPTION 'At most 100 posts' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT p.id FROM public.posts p WHERE p.id=ANY(p_post_ids)
 AND recommendation_private.home_post_visible(p.id,auth.uid());
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_home_forum_session(),public.validate_home_forum_posts(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_home_forum_session(),public.validate_home_forum_posts(uuid[]) TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
