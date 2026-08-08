BEGIN;

SELECT plan(3);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT count(*) FROM public.get_course_catalog()),
  (SELECT count(*) FROM public.courses),
  'the popular course surface returns the complete course catalog'
);

SELECT ok(
  (SELECT bool_and(is_popular) FROM public.get_course_catalog()),
  'the legacy visibility field keeps supported clients showing every course'
);

SELECT is(
  (
    SELECT array_agg(code ORDER BY ordinality)
    FROM public.get_course_catalog() WITH ORDINALITY
  ),
  (
    SELECT array_agg(code ORDER BY review_count DESC, code)
    FROM public.get_course_catalog()
  ),
  'courses are ranked by review count with a stable code tie-breaker'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
