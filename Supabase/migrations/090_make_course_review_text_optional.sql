-- Make the optional course review text optional at the RPC boundary as well.

BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_course_review(
  p_course_id UUID,
  p_professor_id UUID,
  p_course_rating SMALLINT,
  p_difficulty_rating SMALLINT,
  p_professor_rating SMALLINT,
  p_review_text TEXT DEFAULT NULL,
  p_academic_term_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_review_id UUID;
  v_review_text TEXT := NULLIF(btrim(p_review_text), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF p_course_rating NOT BETWEEN 1 AND 5
    OR p_difficulty_rating NOT BETWEEN 1 AND 5
    OR p_professor_rating NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'Ratings must be between 1 and 5'
      USING ERRCODE = '22023';
  END IF;

  IF v_review_text IS NOT NULL AND char_length(v_review_text) > 500 THEN
    RAISE EXCEPTION 'Review text exceeds 500 characters'
      USING ERRCODE = '22001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.course_professors
    WHERE course_id = p_course_id
      AND professor_id = p_professor_id
  ) THEN
    RAISE EXCEPTION 'Professor is not assigned to this course'
      USING ERRCODE = '23503';
  END IF;

  IF p_academic_term_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.academic_terms
      WHERE id = p_academic_term_id
    ) THEN
    RAISE EXCEPTION 'Academic term not found'
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.course_reviews (
    course_id,
    user_id,
    professor_id,
    academic_term_id,
    course_rating,
    difficulty_rating,
    professor_rating,
    review_text
  )
  VALUES (
    p_course_id,
    v_user_id,
    p_professor_id,
    p_academic_term_id,
    p_course_rating,
    p_difficulty_rating,
    p_professor_rating,
    v_review_text
  )
  ON CONFLICT (course_id, user_id) DO UPDATE
  SET
    professor_id = EXCLUDED.professor_id,
    academic_term_id = EXCLUDED.academic_term_id,
    course_rating = EXCLUDED.course_rating,
    difficulty_rating = EXCLUDED.difficulty_rating,
    professor_rating = EXCLUDED.professor_rating,
    review_text = EXCLUDED.review_text,
    updated_at = NOW()
  RETURNING id INTO v_review_id;

  RETURN v_review_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
