-- Withdrawing optional AI consent must remove every vector derived for the
-- withdrawing account, including queued embedding work and its interest
-- profile.  Non-AI engagement records remain available to the product.
--
-- This is destructive only for optional-AI derivatives. Restore requires a
-- fresh user consent and a new embedding job; take the usual protected backup
-- before production rollout. Deploy after the worker version that rechecks
-- consent when completing an embedding job.

BEGIN;

CREATE OR REPLACE FUNCTION public.set_my_ai_consent(p_allowed BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_post_id UUID;
BEGIN
  IF v_user_id IS NULL
     OR p_allowed IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.profiles
       WHERE id = v_user_id
         AND deactivated_at IS NULL
     )
  THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF p_allowed THEN
    INSERT INTO public.ai_processing_consents (user_id, version)
    VALUES (v_user_id, '2026-09-11')
    ON CONFLICT (user_id) DO UPDATE
    SET version = EXCLUDED.version,
        accepted_at = NOW();

    FOR v_post_id IN
      SELECT id
      FROM public.posts
      WHERE user_id = v_user_id
        AND type = 'forum'
    LOOP
      PERFORM public.enqueue_forum_post_embedding(v_post_id);
    END LOOP;
  ELSE
    -- Deleting the consent row first serializes with completion: the worker
    -- holds this row while it writes, so either it completes before this
    -- transaction deletes the derivative or it observes withdrawal and stops.
    DELETE FROM public.ai_processing_consents
    WHERE user_id = v_user_id;

    DELETE FROM public.post_embedding_jobs AS job
    USING public.posts AS post_row
    WHERE job.post_id = post_row.id
      AND post_row.user_id = v_user_id;

    DELETE FROM public.post_embeddings AS embedding
    USING public.posts AS post_row
    WHERE embedding.post_id = post_row.id
      AND post_row.user_id = v_user_id;

    DELETE FROM public.user_interest_profiles
    WHERE user_id = v_user_id;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_ai_consent(BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_ai_consent(BOOLEAN)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
