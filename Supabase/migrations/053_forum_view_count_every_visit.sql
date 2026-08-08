-- 053_forum_view_count_every_visit.sql
-- Keep browse history while counting every valid post open as a view.

CREATE OR REPLACE FUNCTION public.record_post_view(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
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

  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.view_history (user_id, post_id, viewed_at)
    VALUES (v_user_id, p_post_id, NOW())
    ON CONFLICT (user_id, post_id)
    DO UPDATE SET viewed_at = EXCLUDED.viewed_at;
  END IF;

  UPDATE public.posts
  SET view_count = COALESCE(view_count, 0) + 1
  WHERE id = p_post_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_post_view(UUID)
  TO authenticated, anon, service_role;

NOTIFY pgrst, 'reload schema';
