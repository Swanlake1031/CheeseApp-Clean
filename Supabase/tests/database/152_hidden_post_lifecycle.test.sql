BEGIN;

SELECT plan(21);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.get_my_profile_activity_page(text,text,text,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ),
  'owners can page public and hidden published content through one contract'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.process_secondhand_availability_lifecycle(integer)',
    'EXECUTE'
  ),
  'the trusted lifecycle worker remains available'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  fixture.id,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  fixture.post_type,
  fixture.title,
  fixture.title,
  'active',
  FALSE,
  FALSE
FROM (
  VALUES
    (
      '75200000-0000-4000-8000-000000000001'::UUID,
      'forum'::TEXT,
      'Recoverable hidden forum post'::TEXT
    ),
    (
      '75200000-0000-4000-8000-000000000002'::UUID,
      'secondhand'::TEXT,
      'Automatically hidden listing'::TEXT
    )
) AS fixture(id, post_type, title)
JOIN public.profiles profile
  ON profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments)
SELECT
  '75200000-0000-4000-8000-000000000001'::UUID,
  board.id,
  TRUE
FROM public.forum_boards board
WHERE board.status <> 'archived'
ORDER BY board.id
LIMIT 1;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, quantity
)
VALUES (
  '75200000-0000-4000-8000-000000000002',
  25, 'other', 'good', 1
);

SELECT set_config('cheese.secondhand_lifecycle_write', 'allowed', TRUE);
UPDATE public.secondhand_posts
SET availability_confirmed_at = clock_timestamp() - INTERVAL '31 days',
    expires_at = clock_timestamp() - INTERVAL '1 day'
WHERE id = '75200000-0000-4000-8000-000000000002';
SELECT set_config('cheese.secondhand_lifecycle_write', '', TRUE);

SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.set_my_post_hidden(
    '75200000-0000-4000-8000-000000000001',
    TRUE
  ),
  TRUE,
  'an owner can hide a Forum post'
);
SELECT is(
  (
    SELECT status
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000001'
  ),
  'active',
  'hiding does not delete or inactivate the post row'
);
SELECT is(
  (
    SELECT hidden_reason
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000001'
  ),
  'user',
  'manual hiding records its reason'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'published', 'forum', 'visible', NULL, NULL, 30
    )
    WHERE post_id = '75200000-0000-4000-8000-000000000001'
  ),
  0::BIGINT,
  'hidden content disappears from the owner public list'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'published', 'forum', 'hidden', NULL, NULL, 30
    )
    WHERE post_id = '75200000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'the same post appears in private content'
);
SELECT is(
  public.set_my_post_hidden(
    '75200000-0000-4000-8000-000000000001',
    FALSE
  ),
  FALSE,
  'an owner can restore the same Forum post'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000001'
      AND status = 'active'
      AND is_private = FALSE
      AND hidden_at IS NULL
      AND hidden_reason IS NULL
  ),
  1::BIGINT,
  'restoring keeps the original post id and clears hidden metadata'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT listings_hidden
    FROM public.process_secondhand_availability_lifecycle(20)
  ),
  1,
  'the 30-day worker auto-hides an expired public listing'
);
SELECT is(
  (
    SELECT status
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  'active',
  'automatic hiding does not inactivate or delete the listing'
);
SELECT is(
  (
    SELECT hidden_reason
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  'auto_expired',
  'automatic hiding records the expiry reason'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.secondhand_posts_view
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  0::BIGINT,
  'a non-owner service request cannot read the hidden listing view row'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*)
    FROM public.get_my_profile_activity_page(
      'published', 'secondhand', 'hidden', NULL, NULL, 30
    )
    WHERE post_id = '75200000-0000-4000-8000-000000000002'
  ),
  1::BIGINT,
  'an auto-hidden listing appears in owner private content'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.secondhand_posts_view
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  1::BIGINT,
  'the owner can still open the hidden listing detail'
);
SELECT is(
  public.set_my_post_hidden(
    '75200000-0000-4000-8000-000000000002',
    FALSE
  ),
  FALSE,
  'the owner can restore the same auto-hidden listing'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.posts
    WHERE id = '75200000-0000-4000-8000-000000000002'
      AND status = 'active'
      AND is_private = FALSE
  ),
  1::BIGINT,
  'restoring makes the original listing public again'
);
SELECT is(
  (
    SELECT availability_cycle
    FROM public.secondhand_posts
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  2,
  'restoring starts a new availability cycle'
);
SELECT ok(
  (
    SELECT expires_at BETWEEN clock_timestamp() + INTERVAL '29 days'
                          AND clock_timestamp() + INTERVAL '31 days'
    FROM public.secondhand_posts
    WHERE id = '75200000-0000-4000-8000-000000000002'
  ),
  'restoring schedules a fresh 30-day public period'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'service_role', TRUE);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', TRUE);
SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT listings_hidden
    FROM public.process_secondhand_availability_lifecycle(20)
  ),
  0,
  'the worker does not immediately re-hide a restored listing'
);
SELECT is(
  (
    SELECT count(*)
    FROM public.posts
    WHERE id IN (
      '75200000-0000-4000-8000-000000000001'::UUID,
      '75200000-0000-4000-8000-000000000002'::UUID
    )
  ),
  2::BIGINT,
  'both post assets remain present throughout hide and restore transitions'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
