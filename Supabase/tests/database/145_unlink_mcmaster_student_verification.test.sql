BEGIN;

SELECT plan(7);

SELECT function_privs_are(
  'public',
  'unlink_mcmaster_student_verification',
  ARRAY['uuid'],
  'authenticated',
  ARRAY[]::TEXT[],
  'authenticated clients cannot unlink verification directly'
);

SELECT function_privs_are(
  'public',
  'unlink_mcmaster_student_verification',
  ARRAY['uuid'],
  'service_role',
  ARRAY['EXECUTE'],
  'only the service role can unlink verification'
);

DELETE FROM public.mcmaster_email_challenges
WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID;
DELETE FROM public.mcmaster_student_verifications
WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
   OR email = 'unlink-test@mcmaster.ca';

INSERT INTO public.mcmaster_student_verifications (user_id, email)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  'unlink-test@mcmaster.ca'
);

INSERT INTO public.mcmaster_email_challenges (
  user_id,
  email,
  code_hash,
  expires_at
)
VALUES (
  '00000000-0000-0000-0000-000000000001'::UUID,
  'unlink-test@mcmaster.ca',
  repeat('f', 64),
  clock_timestamp() + INTERVAL '10 minutes'
);

SET LOCAL ROLE service_role;
UPDATE public.profiles
SET is_mcmaster_verified = TRUE
WHERE id = '00000000-0000-0000-0000-000000000001'::UUID;

SELECT is(
  (
    SELECT unlinked
    FROM public.unlink_mcmaster_student_verification(
      '00000000-0000-0000-0000-000000000001'::UUID
    )
  ),
  TRUE,
  'the first unlink reports an existing binding'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.mcmaster_student_verifications
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'unlink deletes the verified email binding'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.mcmaster_email_challenges
    WHERE user_id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  0::BIGINT,
  'unlink deletes pending email challenges'
);

SELECT is(
  (
    SELECT is_mcmaster_verified
    FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000001'::UUID
  ),
  FALSE,
  'unlink removes the public student badge flag'
);

SELECT is(
  (
    SELECT unlinked
    FROM public.unlink_mcmaster_student_verification(
      '00000000-0000-0000-0000-000000000001'::UUID
    )
  ),
  FALSE,
  'repeated unlink is safely idempotent'
);

SELECT * FROM finish();
ROLLBACK;
