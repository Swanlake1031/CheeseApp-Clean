-- Index the referencing columns visited when a post is deleted. PostgreSQL
-- does not automatically index foreign keys. No user data is removed.
-- These tables were inspected in production and contain only hundreds of
-- records; ordinary index creation is short and transactional at this size.
BEGIN;
SET LOCAL lock_timeout = '2s';
CREATE INDEX IF NOT EXISTS view_history_post_id_idx ON public.view_history(post_id);
CREATE INDEX IF NOT EXISTS system_messages_post_id_idx ON public.system_messages(post_id);
CREATE INDEX IF NOT EXISTS content_mentions_post_id_idx ON public.content_mentions(post_id);
CREATE INDEX IF NOT EXISTS cheese_ai_interactions_post_id_idx ON public.cheese_ai_interactions(post_id);
COMMIT;
