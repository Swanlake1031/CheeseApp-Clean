-- ============================================
-- 014_urgent_expiry_patch.sql
-- 让 urgent 与 pinned 一样受 pinned_until 控制并自动降级
-- ============================================

-- 1) 统一过期降级函数：urgent + pinned
CREATE OR REPLACE FUNCTION public.normalize_expired_highlights()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total INTEGER := 0;
  v_affected INTEGER := 0;
BEGIN
  UPDATE public.rent_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.secondhand_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.ride_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.team_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  UPDATE public.forum_posts
  SET highlight_type = 'normal'::public.post_highlight_type
  WHERE highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
    AND pinned_until IS NOT NULL
    AND pinned_until < NOW();
  GET DIAGNOSTICS v_affected = ROW_COUNT;
  v_total := v_total + v_affected;

  RETURN v_total;
END;
$$;

-- 2) 实时指标同步时也做过期降级（urgent + pinned）
CREATE OR REPLACE FUNCTION public.sync_post_metrics(p_post_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_type TEXT;
  v_created_at TIMESTAMPTZ;
  v_view_count INTEGER;
  v_like_count INTEGER;
  v_comment_count INTEGER;
  v_save_count INTEGER;
  v_hot_score DOUBLE PRECISION;
BEGIN
  SELECT p.type, p.created_at, COALESCE(p.view_count, 0)
    INTO v_type, v_created_at, v_view_count
  FROM public.posts p
  WHERE p.id = p_post_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::INTEGER
    INTO v_like_count
  FROM public.likes l
  WHERE l.target_type = 'post'
    AND l.target_id = p_post_id;

  SELECT COUNT(*)::INTEGER
    INTO v_comment_count
  FROM public.comments c
  WHERE c.post_id = p_post_id
    AND c.is_deleted = FALSE;

  SELECT COUNT(*)::INTEGER
    INTO v_save_count
  FROM public.favorites f
  WHERE f.post_id = p_post_id;

  v_hot_score := public.calculate_hot_score(
    v_view_count,
    v_like_count,
    v_comment_count,
    v_save_count,
    v_created_at
  );

  IF v_type = 'rent' THEN
    UPDATE public.rent_posts r
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
            AND r.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE r.highlight_type
        END
    WHERE r.id = p_post_id;

  ELSIF v_type = 'secondhand' THEN
    UPDATE public.secondhand_posts s
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN s.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND s.pinned_until IS NOT NULL
            AND s.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE s.highlight_type
        END
    WHERE s.id = p_post_id;

  ELSIF v_type = 'ride' THEN
    UPDATE public.ride_posts r
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN r.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND r.pinned_until IS NOT NULL
            AND r.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE r.highlight_type
        END
    WHERE r.id = p_post_id;

  ELSIF v_type = 'team' THEN
    UPDATE public.team_posts t
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN t.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND t.pinned_until IS NOT NULL
            AND t.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE t.highlight_type
        END
    WHERE t.id = p_post_id;

  ELSIF v_type = 'forum' THEN
    UPDATE public.forum_posts f
    SET view_count = v_view_count,
        like_count = v_like_count,
        comment_count = v_comment_count,
        save_count = v_save_count,
        hot_score = v_hot_score,
        highlight_type = CASE
          WHEN f.highlight_type IN ('pinned'::public.post_highlight_type, 'urgent'::public.post_highlight_type)
            AND f.pinned_until IS NOT NULL
            AND f.pinned_until < NOW()
          THEN 'normal'::public.post_highlight_type
          ELSE f.highlight_type
        END
    WHERE f.id = p_post_id;
  END IF;
END;
$$;

-- 3) 立刻执行一次，清掉历史过期 urgent/pinned
SELECT public.normalize_expired_highlights();

-- 4) (可选) 你若开了 pg_cron，可每小时自动跑一次
-- SELECT cron.schedule(
--   'normalize-expired-highlights-hourly',
--   '0 * * * *',
--   $$SELECT public.normalize_expired_highlights();$$
-- );
