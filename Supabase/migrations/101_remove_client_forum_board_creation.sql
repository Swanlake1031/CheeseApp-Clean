-- 101_remove_client_forum_board_creation.sql
-- Forum boards are system-managed. Authenticated app users, including Forum
-- admins, may manage existing boards through their assigned permissions but
-- cannot create new board records from a client session.

DROP POLICY IF EXISTS "Forum admins can create boards" ON public.forum_boards;
REVOKE INSERT ON public.forum_boards FROM authenticated;
