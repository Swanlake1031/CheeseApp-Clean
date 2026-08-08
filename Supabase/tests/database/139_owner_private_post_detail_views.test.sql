BEGIN;

SELECT plan(4);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT fixture.id, fixture.user_id, profile.school_id, fixture.type,
       fixture.title, 'owner private detail contract', 'active', FALSE, TRUE
FROM (
  VALUES
    (
      '73900000-0000-4000-8000-000000000001'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'forum'::TEXT,
      'Owner private Forum post'::TEXT
    ),
    (
      '73900000-0000-4000-8000-000000000002'::UUID,
      '00000000-0000-0000-0000-000000000001'::UUID,
      'secondhand'::TEXT,
      'Owner private Marketplace post'::TEXT
    )
) AS fixture(id, user_id, type, title)
JOIN public.profiles profile ON profile.id = fixture.user_id;

INSERT INTO public.forum_posts (id, board_id, allow_comments)
SELECT
  '73900000-0000-4000-8000-000000000001'::UUID,
  board.id,
  TRUE
FROM public.forum_boards board
WHERE board.status <> 'archived'
ORDER BY board.id
LIMIT 1;

INSERT INTO public.secondhand_posts (
  id, price, original_price, category, condition, quantity
)
VALUES (
  '73900000-0000-4000-8000-000000000002',
  25, 50, 'other', 'good', 1
);

SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*) FROM public.forum_posts_view
    WHERE id = '73900000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'owner can reopen their private Forum post through the detail view'
);
SELECT is(
  (
    SELECT count(*) FROM public.secondhand_posts_view
    WHERE id = '73900000-0000-4000-8000-000000000002'
  ),
  1::BIGINT,
  'owner can reopen their private Marketplace post through the detail view'
);

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', TRUE);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT count(*) FROM public.forum_posts_view
    WHERE id = '73900000-0000-4000-8000-000000000001'
  ),
  0::BIGINT,
  'another user cannot read the owner private Forum post'
);
SELECT is(
  (
    SELECT count(*) FROM public.secondhand_posts_view
    WHERE id = '73900000-0000-4000-8000-000000000002'
  ),
  0::BIGINT,
  'another user cannot read the owner private Marketplace post'
);

SELECT * FROM finish();
ROLLBACK;
