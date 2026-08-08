BEGIN;

SELECT plan(16);

SELECT has_column(
  'public', 'profiles', 'is_mcmaster_verified',
  'profiles exposes a server-owned McMaster badge flag'
);
SELECT has_table(
  'public', 'mcmaster_student_verifications',
  'verified McMaster identities have a private table'
);
SELECT has_table(
  'public', 'mcmaster_email_challenges',
  'verification challenges have a private table'
);
SELECT function_privs_are(
  'public',
  'issue_mcmaster_email_challenge',
  ARRAY['uuid', 'text', 'text'],
  'authenticated',
  ARRAY[]::TEXT[],
  'authenticated clients cannot issue challenge rows directly'
);
SELECT function_privs_are(
  'public',
  'confirm_mcmaster_email_challenge',
  ARRAY['uuid', 'text', 'text'],
  'service_role',
  ARRAY['EXECUTE'],
  'only the server function can confirm verification'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT throws_like(
  $$UPDATE public.profiles
    SET is_mcmaster_verified = TRUE
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID$$,
  '%server managed%',
  'an authenticated user cannot award their own badge'
);

RESET ROLE;
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
OR email = 'student@mcmaster.ca';
UPDATE public.profiles
SET is_mcmaster_verified = FALSE
WHERE id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

SELECT throws_like(
  $$SELECT * FROM public.issue_mcmaster_email_challenge(
    '00000000-0000-0000-0000-000000000001'::UUID,
    'student@example.com',
    repeat('a', 64)
  )$$,
  '%valid @mcmaster.ca%',
  'the database rejects non-McMaster addresses'
);

SELECT is(
  (
    SELECT status FROM public.issue_mcmaster_email_challenge(
      '00000000-0000-0000-0000-000000000001'::UUID,
      'student@mcmaster.ca',
      repeat('a', 64)
    )
  ),
  'issued',
  'the server can issue a valid challenge'
);

SELECT is(
  (
    SELECT status FROM public.issue_mcmaster_email_challenge(
      '00000000-0000-0000-0000-000000000001'::UUID,
      'student@mcmaster.ca',
      repeat('b', 64)
    )
  ),
  'cooldown',
  'immediate resend attempts are rate limited'
);

SELECT is(
  (
    SELECT status FROM public.confirm_mcmaster_email_challenge(
      '00000000-0000-0000-0000-000000000001'::UUID,
      'student@mcmaster.ca',
      repeat('b', 64)
    )
  ),
  'invalid',
  'an incorrect code hash is rejected'
);

SELECT is(
  (
    SELECT remaining_attempts FROM public.confirm_mcmaster_email_challenge(
      '00000000-0000-0000-0000-000000000001'::UUID,
      'student@mcmaster.ca',
      repeat('b', 64)
    )
  ),
  3,
  'incorrect attempts decrement the server-side allowance'
);

SELECT is(
  (
    SELECT status FROM public.confirm_mcmaster_email_challenge(
      '00000000-0000-0000-0000-000000000001'::UUID,
      'student@mcmaster.ca',
      repeat('a', 64)
    )
  ),
  'verified',
  'the matching challenge confirms the identity'
);

SELECT is(
  (
    SELECT is_mcmaster_verified FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  TRUE,
  'successful verification awards the public profile badge'
);

SELECT is(
  (
    SELECT email FROM public.mcmaster_student_verifications
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  'student@mcmaster.ca',
  'the private verification record stores the normalized address'
);

SELECT is(
  (
    SELECT is_mcmaster_verified FROM public.profile_public_view
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  TRUE,
  'the public profile contract exposes only the badge state'
);

SELECT is(
  (
    SELECT COUNT(*) FROM public.mcmaster_email_challenges
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'a successful verification consumes the challenge'
);

SELECT * FROM finish();
ROLLBACK;
