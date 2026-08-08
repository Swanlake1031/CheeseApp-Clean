BEGIN;

SELECT plan(21);

SELECT is(to_regclass('public.user_geo_profiles'), NULL, 'IP/geo profile table is removed');
SELECT is(to_regclass('public.geo_feed_posts_v1'), NULL, 'geo feed source view is removed');

SELECT is(
  to_regprocedure('public.get_geo_feed(uuid,text,integer,jsonb,double precision,double precision,double precision,double precision,integer)'),
  NULL,
  'distance-ranked geo feed RPC is removed'
);
SELECT is(
  to_regprocedure('public.update_profile_last_known_geo(double precision,double precision)'),
  NULL,
  'profile coordinate writer is removed'
);
SELECT is(
  to_regprocedure('public.upsert_user_geo_profile(text,text,text,text,text,text)'),
  NULL,
  'IP-derived location writer is removed'
);

SELECT hasnt_column('public', 'profiles', 'last_known_geo', 'profiles no longer store coordinates');
SELECT hasnt_column('public', 'profiles', 'location_updated_at', 'profiles no longer track location updates');
SELECT hasnt_column('public', 'posts', 'geo', 'posts no longer store map coordinates');
SELECT hasnt_column('public', 'school_campuses', 'geo', 'campuses no longer store map coordinates');
SELECT hasnt_column('public', 'schools', 'default_radius_km', 'schools no longer configure distance radius');
SELECT hasnt_column('public', 'secondhand_posts', 'pickup_location', 'Secondhand no longer stores inferred pickup location');

SELECT is(
  to_regprocedure('public.create_secondhand_post(uuid,text,text,numeric,text,text,numeric,boolean,boolean,text,boolean,integer,boolean)'),
  NULL,
  'legacy location-bearing Secondhand create RPC is removed'
);
SELECT is(
  to_regprocedure('public.publish_secondhand_post(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,text,timestamp with time zone)'),
  NULL,
  'location-bearing Secondhand publish RPC is removed'
);
SELECT isnt(
  to_regprocedure('public.publish_secondhand_post(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,timestamp with time zone)'),
  NULL,
  'location-free Secondhand publish RPC exists'
);
SELECT isnt(
  to_regprocedure('public.publish_secondhand_post_with_mentions(uuid,uuid,text,text,boolean,boolean,numeric,text,text,boolean,timestamp with time zone,uuid[])'),
  NULL,
  'location-free atomic mention publish RPC exists'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'secondhand_posts_view'
      AND column_name IN ('pickup_location', 'latitude', 'longitude', 'distance_to_school_km')
  ),
  0::BIGINT,
  'Secondhand read contract exposes no location or distance fields'
);

SELECT isnt(
  to_regprocedure('public.get_hot_secondhand_posts(integer)'),
  NULL,
  'location-free hot Secondhand feed RPC remains available'
);

SELECT ok(
  NOT ('ip_masked' = ANY(COALESCE(procedure.proargnames, ARRAY[]::TEXT[])))
  AND NOT ('region' = ANY(COALESCE(procedure.proargnames, ARRAY[]::TEXT[])))
  AND NOT ('country_name' = ANY(COALESCE(procedure.proargnames, ARRAY[]::TEXT[]))),
  'profile search result contract has no inferred location fields'
)
FROM pg_proc procedure
WHERE procedure.oid = 'public.search_profiles(text,integer)'::REGPROCEDURE;

SELECT is(
  (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND udt_schema = 'extensions'
      AND udt_name = 'geography'
  ),
  0::BIGINT,
  'active public tables contain no PostGIS geography columns'
);

SELECT is(
  to_regtype('extensions.geography'),
  NULL,
  'PostGIS geography type is removed with the retired location feature'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.proname ~ '(geo|location|distance|anchor)'
  ),
  0::BIGINT,
  'no public location, distance, or geo helper functions remain'
);

SELECT * FROM finish();
ROLLBACK;
