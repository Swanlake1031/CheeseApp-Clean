 -- 036_forum_view_tracking.sql
-- Real forum/post view tracking:
-- 1) Record per-user browse history in view_history.
-- 2) Increment posts.view_count once per user per post.

CREATE OR REPLACE FUNCTION public.record_post_view(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_inserted_rows INTEGER := 0;
BEGIN
  IF p_post_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.posts p
    WHERE p.id = p_post_id
      AND p.status = 'active'
  ) THEN
    RETURN;
  END IF;

  -- Fallback for unauthenticated reads: count each visit.
  IF v_user_id IS NULL THEN
    UPDATE public.posts
    SET view_count = COALESCE(view_count, 0) + 1
    WHERE id = p_post_id;
    RETURN;
  END IF;

  -- First visit by this user increments view_count.
  INSERT INTO public.view_history (user_id, post_id, viewed_at)
  VALUES (v_user_id, p_post_id, NOW())
  ON CONFLICT (user_id, post_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;

  IF v_inserted_rows = 0 THEN
    -- Already viewed before: refresh "recently viewed" timestamp only.
    UPDATE public.view_history
    SET viewed_at = NOW()
    WHERE user_id = v_user_id
      AND post_id = p_post_id;
    RETURN;
  END IF;

  UPDATE public.posts
  SET view_count = COALESCE(view_count, 0) + 1
  WHERE id = p_post_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_post_view(UUID)
  TO authenticated, anon, service_role;

NOTIFY pgrst, 'reload schema';
