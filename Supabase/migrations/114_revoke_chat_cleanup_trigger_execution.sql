-- Trigger functions are internal entry points. PostgreSQL grants EXECUTE on new
-- functions to PUBLIC by default, so revoke it explicitly after migration 113.
REVOKE ALL ON FUNCTION public.enqueue_direct_message_media_cleanup() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enqueue_direct_message_media_cleanup() FROM anon;
REVOKE ALL ON FUNCTION public.enqueue_direct_message_media_cleanup() FROM authenticated;

REVOKE ALL ON FUNCTION public.enqueue_group_message_media_cleanup() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enqueue_group_message_media_cleanup() FROM anon;
REVOKE ALL ON FUNCTION public.enqueue_group_message_media_cleanup() FROM authenticated;
