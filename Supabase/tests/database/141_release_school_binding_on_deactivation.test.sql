BEGIN;

SELECT plan(6);

SELECT set_config(
  'request.jwt.claims',
  '{"role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

DELETE FROM public.mcmaster_email_challenges
WHERE user_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);
DELETE FROM public.mcmaster_student_verifications
WHERE user_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
)
OR email = 'released@mcmaster.ca';

UPDATE public.profiles
SET is_mcmaster_verified = TRUE
WHERE id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.mcmaster_student_verifications (user_id, email)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  'released@mcmaster.ca'
);

INSERT INTO public.mcmaster_email_challenges (
  user_id,
  email,
  code_hash,
  expires_at
)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  'released@mcmaster.ca',
  repeat('a', 64),
  NOW() + INTERVAL '10 minutes'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.mcmaster_student_verifications
    WHERE email = 'released@mcmaster.ca'
  ),
  1::BIGINT,
  'the school email starts bound to the active account'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT ok(
  public.deactivate_my_account(),
  'the user can deactivate the account'
);

RESET ROLE;
SELECT set_config(
  'request.jwt.claims',
  '{"role":"service_role"}',
  TRUE
);
SET LOCAL ROLE service_role;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.mcmaster_student_verifications
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'deactivation deletes the private school email binding'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.mcmaster_email_challenges
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'deactivation deletes pending school email challenges'
);

SELECT is(
  (
    SELECT is_mcmaster_verified
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  FALSE,
  'deactivation removes the public McMaster verification badge'
);

INSERT INTO public.mcmaster_student_verifications (user_id, email)
VALUES (
  '00000000-0000-0000-0000-000000000002'::UUID,
  'released@mcmaster.ca'
);

SELECT is(
  (
    SELECT user_id
    FROM public.mcmaster_student_verifications
    WHERE email = 'released@mcmaster.ca'
  ),
  '00000000-0000-0000-0000-000000000002'::UUID,
  'the released school email can bind to a different account'
);

SELECT * FROM finish();
ROLLBACK;
