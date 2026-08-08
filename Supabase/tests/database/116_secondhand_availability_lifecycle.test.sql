BEGIN;

SELECT plan(17);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.process_secondhand_availability_lifecycle(integer)',
    'EXECUTE'
  ),
  'clients cannot execute the lifecycle worker'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.process_secondhand_availability_lifecycle(integer)',
    'EXECUTE'
  ),
  'only the trusted worker can execute lifecycle processing'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.respond_secondhand_availability(uuid,text)',
    'EXECUTE'
  ),
  'authenticated sellers can invoke the protected response RPC'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  fixture.id,
  fixture.user_id,
  profile.school_id,
  'secondhand',
  fixture.title,
  'test',
  'active',
  FALSE,
  FALSE
FROM (
  VALUES
    (
      '71600000-0000-4000-8000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'Reminder due'
    ),
    (
      '71600000-0000-4000-8000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'Auto inactive'
    ),
    (
      '71600000-0000-4000-8000-000000000003'::UUID,
      '00000000-0000-0000-0000-000000000002'::UUID,
      'Fresh listing'
    )
) AS fixture(id, user_id, title)
JOIN public.profiles profile ON profile.id = fixture.user_id;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, quantity
)
VALUES
  (
    '71600000-0000-4000-8000-000000000001',
    10, 'home_appliances', 'good', 1
  ),
  (
    '71600000-0000-4000-8000-000000000002',
    20, 'digital_electronics', 'good', 1
  ),
  (
    '71600000-0000-4000-8000-000000000003',
    30, 'sports_outdoors', 'good', 1
  );

SELECT set_config(
  'cheese.secondhand_lifecycle_write',
  'allowed',
  TRUE
);
UPDATE public.posts
SET created_at = CASE id
  WHEN '71600000-0000-4000-8000-000000000001'::UUID
    THEN clock_timestamp() - INTERVAL '15 days'
  WHEN '71600000-0000-4000-8000-000000000002'::UUID
    THEN clock_timestamp() - INTERVAL '31 days'
  ELSE clock_timestamp() - INTERVAL '2 days'
END
WHERE id IN (
  '71600000-0000-4000-8000-000000000001'::UUID,
  '71600000-0000-4000-8000-000000000002'::UUID,
  '71600000-0000-4000-8000-000000000003'::UUID
);
UPDATE public.secondhand_posts
SET expires_at = CASE id
  WHEN '71600000-0000-4000-8000-000000000001'::UUID
    THEN clock_timestamp() + INTERVAL '15 days'
  WHEN '71600000-0000-4000-8000-000000000002'::UUID
    THEN clock_timestamp() - INTERVAL '1 day'
  ELSE clock_timestamp() + INTERVAL '28 days'
END;
SELECT set_config(
  'cheese.secondhand_lifecycle_write',
  '',
  TRUE
);

SELECT set_config(
  'request.jwt.claim.role',
  'service_role',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT reminders_created
    FROM public.process_secondhand_availability_lifecycle(20)
  ),
  1,
  '14-day due listing creates one reminder'
);
SELECT is(
  (
    SELECT status
    FROM public.posts
    WHERE id = '71600000-0000-4000-8000-000000000002'
  ),
  'inactive',
  '30-day ignored listing becomes inactive'
);
SELECT is(
  (
    SELECT status
    FROM public.posts
    WHERE id = '71600000-0000-4000-8000-000000000002'
  ),
  'inactive',
  'automatic lifecycle never marks a listing sold'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE post_id = '71600000-0000-4000-8000-000000000001'
      AND kind = 'secondhand_availability'
  ),
  1::BIGINT,
  'the reminder is visible in the system message timeline'
);
SELECT is(
  (
    SELECT reminders_created
    FROM public.process_secondhand_availability_lifecycle(20)
  ),
  0,
  're-running the worker is idempotent'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.system_messages
    WHERE post_id = '71600000-0000-4000-8000-000000000001'
      AND kind = 'secondhand_availability'
  ),
  1::BIGINT,
  'retry does not duplicate the reminder'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claim.role',
  'authenticated',
  TRUE
);
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$
    SELECT *
    FROM public.respond_secondhand_availability(
      '71600000-0000-4000-8000-000000000001',
      'still_available'
    )
  $$,
  '42501',
  NULL,
  'another user cannot confirm the seller listing'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000001',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT status
    FROM public.respond_secondhand_availability(
      '71600000-0000-4000-8000-000000000001',
      'still_available'
    )
  ),
  'active',
  'seller can confirm that a listing is still available'
);
SELECT is(
  (
    SELECT availability_cycle
    FROM public.secondhand_posts
    WHERE id = '71600000-0000-4000-8000-000000000001'
  ),
  1,
  'confirmation does not extend the fixed expiry cycle'
);
SELECT is(
  (
    SELECT availability_reminder_sent_at IS NOT NULL
    FROM public.secondhand_posts
    WHERE id = '71600000-0000-4000-8000-000000000001'
  ),
  TRUE,
  'confirmation keeps the one-time reminder marker'
);
SELECT throws_ok(
  $$
    SELECT * FROM public.respond_secondhand_availability(
      '71600000-0000-4000-8000-000000000002',
      'still_available'
    )
  $$,
  '55000',
  NULL,
  'seller cannot reactivate a listing after fixed expiry'
);
SELECT is(
  (
    SELECT status
    FROM public.respond_secondhand_availability(
      '71600000-0000-4000-8000-000000000001',
      'sold'
    )
  ),
  'completed',
  'sold requires an explicit seller action'
);
SELECT ok(
  (
    SELECT sold_at IS NOT NULL
    FROM public.secondhand_posts
    WHERE id = '71600000-0000-4000-8000-000000000001'
  ),
  'explicit sold action records database time'
);

SELECT throws_ok(
  $$
    UPDATE public.secondhand_posts
    SET availability_cycle = availability_cycle + 1
    WHERE id = '71600000-0000-4000-8000-000000000002'
  $$,
  '42501',
  NULL,
  'clients cannot mutate protected lifecycle fields directly'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
