-- 046_chat_list_swipe_state.sql
-- Support chat-list swipe actions:
-- - Mark as unread (manual_unread)
-- - Hide chat until new message (hide_until_at)

BEGIN;

ALTER TABLE public.user_conversation_settings
  ADD COLUMN IF NOT EXISTS manual_unread BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS hide_until_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS user_conversation_settings_manual_unread_idx
  ON public.user_conversation_settings(user_id, manual_unread)
  WHERE manual_unread = TRUE;

CREATE INDEX IF NOT EXISTS user_conversation_settings_hide_until_idx
  ON public.user_conversation_settings(user_id, hide_until_at DESC)
  WHERE hide_until_at IS NOT NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
