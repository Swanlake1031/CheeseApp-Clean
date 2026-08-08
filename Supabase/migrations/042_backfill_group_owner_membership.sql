-- 042_backfill_group_owner_membership.sql
-- Root-cause data repair:
-- Ensure every chat_groups.owner_id has a matching owner row in chat_group_members.

BEGIN;

INSERT INTO public.chat_group_members (group_id, user_id, role)
SELECT g.id, g.owner_id, 'owner'
FROM public.chat_groups g
ON CONFLICT (group_id, user_id) DO UPDATE
SET role = 'owner';

NOTIFY pgrst, 'reload schema';

COMMIT;
