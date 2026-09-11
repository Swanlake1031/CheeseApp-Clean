-- Keep historical board/tag records. Remove labels from semantic input only.
-- Deploy before the tag-free client. No post, board, or tag data is deleted.
-- Derived vectors must be regenerated: until ready, semantic ranking uses its
-- existing neutral fallback and foreign-school eligibility fails closed.
-- Existing model/weights/thresholds stay unchanged; monitor score calibration.
-- Rollback requires a forward input-function restoration and another requeue;
-- regenerated vectors cannot be restored without a predeployment DB backup.
BEGIN;
DO $$
DECLARE definition text;
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid='public.recommendation_embedding_input(uuid)'::regprocedure)
     IS DISTINCT FROM '9683efe665df338613b756af5bac6806' THEN
    RAISE EXCEPTION 'Unexpected recommendation embedding input definition';
  END IF;
  SELECT pg_get_functiondef('public.recommendation_embedding_input(uuid)'::regprocedure) INTO definition;
  -- Keep the existing input envelope but no manually chosen label content.
  EXECUTE replace(definition, $old$COALESCE('#' || board.name, '')$old$, $new$''$new$);
END $$;

-- Requeue all currently eligible text so cached vectors cannot retain tags.
-- Existing enqueue triggers rebuild interest vectors and invalidate cached q.
-- Inactive posts can still contribute to interest profiles: invalidate their
-- derived vectors too, without deleting their historical content or labels.
UPDATE public.post_embeddings e
SET status='pending', embedding=NULL, generated_at=NULL, updated_at=clock_timestamp()
WHERE e.input_hash IS DISTINCT FROM
  (SELECT i.input_hash FROM public.recommendation_embedding_input(e.post_id) i)
  AND (e.embedding IS NOT NULL OR e.status='ready');
DO $$
DECLARE post_id uuid;
BEGIN
  FOR post_id IN
    SELECT p.id FROM public.posts p
    JOIN public.forum_posts f ON f.id=p.id
    JOIN public.forum_boards b ON b.id=f.board_id
    WHERE p.type='forum' AND p.status='active' AND b.status<>'archived'
      AND (nullif(btrim(p.title),'') IS NOT NULL OR nullif(btrim(p.description),'') IS NOT NULL)
  LOOP
    PERFORM public.enqueue_forum_post_embedding(post_id);
  END LOOP;
END $$;
-- Stored rankings may contain tag-influenced scores. Expire, do not delete.
UPDATE public.feed_sessions SET expires_at=clock_timestamp()
WHERE expires_at>clock_timestamp();
COMMIT;
