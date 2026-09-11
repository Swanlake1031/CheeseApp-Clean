BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_temp;
SELECT no_plan();

SELECT has_column('public','moderated_media','consent_version','moderation receipts record the media-safety disclosure version');
SELECT ok(NOT has_table_privilege('authenticated','public.moderated_media','INSERT'),'clients cannot forge a disclosed media-safety receipt');

SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-0000-0000-000000000002"}',true);
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SET LOCAL ROLE authenticated;
SELECT is(public.can_upload_moderated_media('avatars','00000000-0000-0000-0000-000000000002/new.jpg'),true,'a signed-in active owner can submit an image for safety review without optional AI consent');
SELECT is(public.can_upload_moderated_media('avatars','00000000-0000-0000-0000-000000000001/new.jpg'),false,'a signed-in account cannot submit another account image');
SELECT is(public.set_my_ai_consent(false),true,'optional AI consent can be withdrawn independently');
SELECT is(public.can_upload_moderated_media('avatars','00000000-0000-0000-0000-000000000002/new.jpg'),true,'withdrawing optional AI consent does not revoke image-review access');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
