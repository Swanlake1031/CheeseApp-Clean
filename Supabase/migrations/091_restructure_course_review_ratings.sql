-- Replace the pre-release pilot rating dimensions with the final five-part contract.
-- This intentionally deletes the single pilot review because difficulty cannot be
-- truthfully converted into fun, useful, or Easy A scores.

BEGIN;

DELETE FROM public.course_reviews;

DROP FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
);

ALTER TABLE public.course_reviews
  DROP CONSTRAINT course_reviews_course_rating,
  DROP CONSTRAINT course_reviews_difficulty_rating,
  DROP COLUMN course_rating,
  DROP COLUMN difficulty_rating,
  ADD COLUMN overall_rating SMALLINT NOT NULL,
  ADD COLUMN fun_rating SMALLINT NOT NULL,
  ADD COLUMN useful_rating SMALLINT NOT NULL,
  ADD COLUMN easy_a_rating SMALLINT NOT NULL,
  ADD CONSTRAINT course_reviews_overall_rating
    CHECK (overall_rating BETWEEN 1 AND 5),
  ADD CONSTRAINT course_reviews_fun_rating
    CHECK (fun_rating BETWEEN 1 AND 5),
  ADD CONSTRAINT course_reviews_useful_rating
    CHECK (useful_rating BETWEEN 1 AND 5),
  ADD CONSTRAINT course_reviews_easy_a_rating
    CHECK (easy_a_rating BETWEEN 1 AND 5);

CREATE OR REPLACE FUNCTION public.get_course_review_snapshot(
  p_course_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_professors JSONB;
  v_reviews JSONB;
  v_aggregate JSONB;
  v_professor_aggregates JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.courses WHERE id = p_course_id
  ) THEN
    RAISE EXCEPTION 'Course not found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', professor.id, 'name', professor.name)
      ORDER BY professor.name
    ),
    '[]'::JSONB
  )
  INTO v_professors
  FROM public.course_professors AS course_professor
  JOIN public.professors AS professor
    ON professor.id = course_professor.professor_id
  WHERE course_professor.course_id = p_course_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', review.id,
        'professor_id', review.professor_id,
        'professor_name', professor.name,
        'overall_rating', review.overall_rating,
        'fun_rating', review.fun_rating,
        'useful_rating', review.useful_rating,
        'easy_a_rating', review.easy_a_rating,
        'professor_rating', review.professor_rating,
        'review_text', review.review_text,
        'academic_year', academic_term.academic_year,
        'term', academic_term.term,
        'created_at', review.created_at,
        'updated_at', review.updated_at,
        'is_mine', review.user_id = v_user_id
      )
      ORDER BY review.updated_at DESC
    ),
    '[]'::JSONB
  )
  INTO v_reviews
  FROM public.course_reviews AS review
  JOIN public.professors AS professor
    ON professor.id = review.professor_id
  LEFT JOIN public.academic_terms AS academic_term
    ON academic_term.id = review.academic_term_id
  WHERE review.course_id = p_course_id;

  SELECT jsonb_build_object(
    'review_count', COUNT(*),
    'overall_rating', ROUND(AVG(overall_rating)::NUMERIC, 1),
    'fun_rating', ROUND(AVG(fun_rating)::NUMERIC, 1),
    'useful_rating', ROUND(AVG(useful_rating)::NUMERIC, 1),
    'easy_a_rating', ROUND(AVG(easy_a_rating)::NUMERIC, 1),
    'professor_rating', ROUND(AVG(professor_rating)::NUMERIC, 1)
  )
  INTO v_aggregate
  FROM public.course_reviews
  WHERE course_id = p_course_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'professor_id', grouped.professor_id,
        'aggregate', jsonb_build_object(
          'review_count', grouped.review_count,
          'overall_rating', grouped.overall_rating,
          'fun_rating', grouped.fun_rating,
          'useful_rating', grouped.useful_rating,
          'easy_a_rating', grouped.easy_a_rating,
          'professor_rating', grouped.professor_rating
        )
      )
      ORDER BY grouped.professor_id
    ),
    '[]'::JSONB
  )
  INTO v_professor_aggregates
  FROM (
    SELECT
      professor_id,
      COUNT(*) AS review_count,
      ROUND(AVG(overall_rating)::NUMERIC, 1) AS overall_rating,
      ROUND(AVG(fun_rating)::NUMERIC, 1) AS fun_rating,
      ROUND(AVG(useful_rating)::NUMERIC, 1) AS useful_rating,
      ROUND(AVG(easy_a_rating)::NUMERIC, 1) AS easy_a_rating,
      ROUND(AVG(professor_rating)::NUMERIC, 1) AS professor_rating
    FROM public.course_reviews
    WHERE course_id = p_course_id
    GROUP BY professor_id
  ) AS grouped;

  RETURN jsonb_build_object(
    'professors', v_professors,
    'reviews', v_reviews,
    'aggregate', v_aggregate,
    'professor_aggregates', v_professor_aggregates
  );
END;
$$;

CREATE FUNCTION public.upsert_course_review(
  p_course_id UUID,
  p_professor_id UUID,
  p_overall_rating SMALLINT,
  p_fun_rating SMALLINT,
  p_useful_rating SMALLINT,
  p_easy_a_rating SMALLINT,
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

  IF p_overall_rating NOT BETWEEN 1 AND 5
    OR p_fun_rating NOT BETWEEN 1 AND 5
    OR p_useful_rating NOT BETWEEN 1 AND 5
    OR p_easy_a_rating NOT BETWEEN 1 AND 5
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
      SELECT 1 FROM public.academic_terms WHERE id = p_academic_term_id
    ) THEN
    RAISE EXCEPTION 'Academic term not found'
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO public.course_reviews (
    course_id, user_id, professor_id, academic_term_id,
    overall_rating, fun_rating, useful_rating, easy_a_rating,
    professor_rating, review_text
  )
  VALUES (
    p_course_id, v_user_id, p_professor_id, p_academic_term_id,
    p_overall_rating, p_fun_rating, p_useful_rating, p_easy_a_rating,
    p_professor_rating, v_review_text
  )
  ON CONFLICT (course_id, user_id) DO UPDATE
  SET
    professor_id = EXCLUDED.professor_id,
    academic_term_id = EXCLUDED.academic_term_id,
    overall_rating = EXCLUDED.overall_rating,
    fun_rating = EXCLUDED.fun_rating,
    useful_rating = EXCLUDED.useful_rating,
    easy_a_rating = EXCLUDED.easy_a_rating,
    professor_rating = EXCLUDED.professor_rating,
    review_text = EXCLUDED.review_text,
    updated_at = NOW()
  RETURNING id INTO v_review_id;

  RETURN v_review_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
