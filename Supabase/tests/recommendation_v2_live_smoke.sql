-- Explicit post-deployment smoke test. No persistent user/session writes.
-- Run via authorized linked-project management connection; always ROLLBACK.
BEGIN;
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE v2_smoke_result(result jsonb);
DO $$
DECLARE viewer uuid; sid uuid; mode public.recommendation_feed_mode;
  n integer; invalid integer;
BEGIN
  SELECT p.id INTO viewer FROM public.profiles p
    WHERE p.school_id IS NOT NULL ORDER BY p.id LIMIT 1;
  IF viewer IS NULL THEN RAISE EXCEPTION 'No viewer available for smoke test'; END IF;
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',viewer,'role','authenticated')::text,true);
  PERFORM set_config('request.headers','{"x-cheese-recommendation-contract":"2"}',true);
  mode:=public.get_recommendation_feed_mode();
  IF NOT mode.use_recommendations OR NOT mode.cross_school_gate_enabled THEN
    RAISE EXCEPTION 'V2 mode not active for supported authenticated client'; END IF;
  sid:=public.create_recommendation_feed_session(true,false,NULL);
  IF sid IS NULL THEN RAISE EXCEPTION 'Session was not created'; END IF;
  SELECT count(*) INTO n FROM public.get_recommendation_feed_page(sid,0,20);
  SELECT count(*) INTO invalid FROM public.feed_session_items i
    WHERE i.session_id=sid AND NOT recommendation_private.allowed(i.post_id,viewer);
  IF invalid<>0 THEN RAISE EXCEPTION 'Session contains an ineligible post'; END IF;
  IF has_function_privilege('authenticated','public.backfill_cross_school_scores(integer)','EXECUTE')
    OR has_table_privilege('authenticated','public.cross_school_scores','SELECT') THEN
    RAISE EXCEPTION 'Unexpected client access to private scoring'; END IF;
  INSERT INTO v2_smoke_result VALUES(jsonb_build_object('mode_active',true,
    'session_created',true,'page_items',n,'ineligible_session_items',invalid,
    'client_private_access',false));
END $$;
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SELECT jsonb_build_object('smoke',(SELECT result FROM v2_smoke_result),
  'metrics',public.get_cross_school_metrics(),
  'v1_rollout',(SELECT rollout_percentage FROM public.recommendation_configuration),
  'migration_recorded',EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations WHERE version='20260910024900')) AS verification;
ROLLBACK;
