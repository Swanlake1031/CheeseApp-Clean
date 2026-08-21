-- 179_group_message_realtime.sql
--
-- Group rooms already use the same realtime lifecycle as direct-message rooms,
-- but group_messages was never added to the Supabase Realtime publication.
-- Publish the table so open group rooms receive inserts, recalls, and deletes
-- without requiring the user to leave and reopen the conversation.

BEGIN;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END
$$;

COMMIT;
