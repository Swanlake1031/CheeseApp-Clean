BEGIN;

SELECT plan(11);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.cancel_seller_secondhand_purchase_intent(uuid)',
    'EXECUTE'
  ),
  'sellers can cancel one active purchase intent'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '169a0000-0000-4000-8000-000000000001'::UUID,
  profile.id,
  profile.school_id,
  'secondhand',
  'Seller cancellation fixture',
  'Seller cancellation fixture',
  'active',
  FALSE,
  FALSE
FROM public.profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.secondhand_posts (
  id, price, category, condition, quantity
)
VALUES (
  '169a0000-0000-4000-8000-000000000001',
  35, 'other', 'good', 1
);

INSERT INTO public.conversations (
  id, user1_id, user2_id, related_post_id
)
VALUES
  (
    '169a0000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    '169a0000-0000-4000-8000-000000000001'
  ),
  (
    '169a0000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000003',
    '169a0000-0000-4000-8000-000000000001'
  );

INSERT INTO public.secondhand_purchase_intents (
  id, listing_id, conversation_id, seller_id, buyer_id, status
)
VALUES
  (
    '169a0000-0000-4000-8000-000000000004',
    '169a0000-0000-4000-8000-000000000001',
    '169a0000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    'active'
  ),
  (
    '169a0000-0000-4000-8000-000000000005',
    '169a0000-0000-4000-8000-000000000001',
    '169a0000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000003',
    'active'
  );

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.cancel_seller_secondhand_purchase_intent(
    '169a0000-0000-4000-8000-000000000004'
  ),
  TRUE,
  'the seller can cancel the current chat transaction'
);

RESET ROLE;

SELECT is(
  (SELECT status FROM public.secondhand_purchase_intents
   WHERE id = '169a0000-0000-4000-8000-000000000004'),
  'seller_stopped',
  'the selected purchase intent is ended'
);

SELECT is(
  (SELECT status FROM public.secondhand_purchase_intents
   WHERE id = '169a0000-0000-4000-8000-000000000005'),
  'active',
  'another buyer transaction remains active'
);

SELECT is(
  (SELECT status FROM public.posts
   WHERE id = '169a0000-0000-4000-8000-000000000001'),
  'active',
  'the marketplace listing remains active'
);

SELECT is(
  (SELECT is_private FROM public.posts
   WHERE id = '169a0000-0000-4000-8000-000000000001'),
  FALSE,
  'the marketplace listing remains public'
);

SELECT is(
  (SELECT hidden_at FROM public.posts
   WHERE id = '169a0000-0000-4000-8000-000000000001'),
  NULL::TIMESTAMPTZ,
  'cancelling the transaction does not hide the listing'
);

SELECT is(
  (
    SELECT content
    FROM public.messages
    WHERE conversation_id = '169a0000-0000-4000-8000-000000000002'
      AND metadata -> 'secondhand_transaction_event' ->> 'intent_id'
        = '169a0000-0000-4000-8000-000000000004'
    ORDER BY created_at DESC, id DESC
    LIMIT 1
  ),
  '卖家已取消交易',
  'the chat keeps an explicit seller-cancellation system message'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.stop_selling_secondhand_listing(
    '169a0000-0000-4000-8000-000000000001'
  ),
  TRUE,
  'the legacy action remains callable by installed clients'
);

RESET ROLE;

SELECT is(
  (SELECT is_private FROM public.posts
   WHERE id = '169a0000-0000-4000-8000-000000000001'),
  FALSE,
  'the legacy action can no longer hide the listing'
);

SELECT is(
  (SELECT status FROM public.posts
   WHERE id = '169a0000-0000-4000-8000-000000000001'),
  'active',
  'the legacy action can no longer inactivate the listing'
);

SELECT * FROM finish();
ROLLBACK;
