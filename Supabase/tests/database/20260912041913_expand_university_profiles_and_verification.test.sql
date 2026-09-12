BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT no_plan();

SELECT is(
  (SELECT COUNT(*)::INTEGER FROM schools WHERE name IN (
    'University of Alberta', 'University of British Columbia', 'Brock University',
    'University of Calgary', 'Carleton University', 'Concordia University',
    'Dalhousie University', 'University of Guelph', 'Simon Fraser University',
    'Lakehead University', 'McGill University', 'University of Manitoba',
    'McMaster University', 'Université de Montréal', 'Ontario Tech University',
    'Queen''s University', 'University of Toronto', 'Toronto Metropolitan University',
    'Trent University', 'University of Waterloo', 'Other'
  )),
  21,
  'requested universities and Other exist'
);
SELECT is((SELECT badge_code FROM schools WHERE name='Carleton University'),'C','Carleton badge code is configured');
SELECT is((SELECT badge_code FROM schools WHERE name='Ontario Tech University'),'OT','Ontario Tech badge code is configured');
SELECT is((SELECT verification_domains FROM schools WHERE name='University of Toronto'),ARRAY['mail.utoronto.ca']::TEXT[],'Toronto student domain is configured');

INSERT INTO auth.users(id,email)
VALUES ('41913000-0000-4000-8000-000000000001','profile-status@test.invalid');
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims','{"sub":"41913000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $q$SELECT complete_profile('Worker',NULL,'prefer_not_to_say',NULL,NULL,NULL,'working')$q$,
  'working profile may omit school'
);
RESET ROLE;
SELECT is((SELECT profile_status FROM profiles WHERE id=auth.uid()),'working','working status persists');
SELECT is((SELECT university FROM profiles WHERE id=auth.uid()),NULL,'working profile may keep public school empty');

SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $q$SELECT complete_profile('Student',NULL,'prefer_not_to_say',NULL,NULL,NULL,'student')$q$,
  '22023','School is required for students','student profile requires school'
);
SELECT lives_ok(
  $q$SELECT complete_profile('Student','University of Calgary','prefer_not_to_say',NULL,NULL,NULL,'student')$q$,
  'student profile accepts configured university'
);
RESET ROLE;
SELECT is((SELECT profile_status FROM profiles WHERE id=auth.uid()),'student','student status persists');
SELECT is((SELECT university FROM profiles WHERE id=auth.uid()),'University of Calgary','student school is canonicalized');

SET LOCAL ROLE service_role;
SELECT throws_ok(
  $q$SELECT issue_school_email_challenge(
    '41913000-0000-4000-8000-000000000001',
    (SELECT id FROM schools WHERE name='University of Calgary'),
    'student@wrong.example','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )$q$,
  '22023','Email domain does not match the selected school',
  'verification rejects an unrelated email domain'
);
SELECT lives_ok(
  $q$SELECT issue_school_email_challenge(
    '41913000-0000-4000-8000-000000000001',
    (SELECT id FROM schools WHERE name='University of Calgary'),
    'student@ucalgary.ca','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )$q$,
  'verification accepts the selected school domain'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
