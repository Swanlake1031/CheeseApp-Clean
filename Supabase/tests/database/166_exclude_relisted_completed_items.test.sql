BEGIN;

SELECT plan(8);

SELECT has_column(
  'public',
  'secondhand_purchase_intents',
  'relisted_at',
  'completed purchase intents record when their listing was restored'
);

DELETE FROM public.conversations
WHERE user1_id = '00000000-0000-0000-0000-000000000001'::UUID
  AND user2_id = '00000000-0000-0000-0000-000000000002'::UUID;

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '166a0000-0000-4000-8000-000000000001'::UUID,
  profile.id,
  profile.school_id,
  'secondhand',
  'Relist archive fixture',
  'Relist archive fixture',
  'completed',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, quantity, sold_count, sold_at
)
VALUES (
  '166a0000-0000-4000-8000-000000000001',
  42, 'other', 'good', 1, 1, clock_timestamp()
);

INSERT INTO public.conversations (
  id, user1_id, user2_id, related_post_id
)
VALUES (
  '166a0000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '166a0000-0000-4000-8000-000000000001'
);

INSERT INTO public.secondhand_purchase_intents (
  id, listing_id, conversation_id, seller_id, buyer_id,
  status, ended_at
)
VALUES (
  '166a0000-0000-4000-8000-000000000003',
  '166a0000-0000-4000-8000-000000000001',
  '166a0000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'completed',
  clock_timestamp()
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_completed_secondhand_transactions('seller')
    WHERE listing_id = '166a0000-0000-4000-8000-000000000001'
  ),
  1::BIGINT,
  'a completed listing initially appears for the seller'
);

SELECT is(
  public.relist_completed_secondhand_listing(
    '166a0000-0000-4000-8000-000000000003',
    '166a0000-0000-4000-8000-000000000001'
  ),
  TRUE,
  'the seller can restore the completed listing'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_completed_secondhand_transactions('seller')
    WHERE listing_id = '166a0000-0000-4000-8000-000000000001'
  ),
  0::BIGINT,
  'a restored listing immediately disappears for the seller'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.get_my_completed_secondhand_transactions('buyer')
    WHERE listing_id = '166a0000-0000-4000-8000-000000000001'
  ),
  0::BIGINT,
  'the same restored listing disappears for the buyer'
);

RESET ROLE;

SELECT is(
  (
    SELECT status
    FROM public.secondhand_purchase_intents
    WHERE id = '166a0000-0000-4000-8000-000000000003'
  ),
  'completed',
  'the immutable transaction status remains completed for audit history'
);

SELECT ok(
  (
    SELECT relisted_at IS NOT NULL
    FROM public.secondhand_purchase_intents
    WHERE id = '166a0000-0000-4000-8000-000000000003'
  ),
  'the previous transaction lifecycle is marked as relisted'
);

SELECT is(
  (
    SELECT status
    FROM public.posts
    WHERE id = '166a0000-0000-4000-8000-000000000001'
  ),
  'active',
  'the listing itself returns to the active marketplace lifecycle'
);

SELECT * FROM finish();
ROLLBACK;
