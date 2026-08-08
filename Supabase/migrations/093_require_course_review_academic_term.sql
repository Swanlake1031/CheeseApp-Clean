-- Require every course review to identify the academic year and term.
--
-- Destructive behavior:
-- - Deletes pre-release pilot reviews whose academic_term_id is NULL because
--   their term cannot be inferred safely.
-- - Deleted pilot reviews cannot be reconstructed by this migration.
--
-- Deployment order:
-- 1. Apply this migration.
-- 2. Ship an app build that requires academic_term_id when saving reviews.
--
-- Rollback limit:
-- - The NOT NULL constraint and RPC changes can be reverted.
-- - Deleted null-term pilot reviews require an external backup to restore.

BEGIN;

INSERT INTO public.academic_terms (academic_year, term)
VALUES
  (2025, 'fall'),
  (2026, 'winter'),
  (2026, 'spring'),
  (2026, 'summer')
ON CONFLICT (academic_year, term) DO NOTHING;

DELETE FROM public.course_reviews
WHERE academic_term_id IS NULL;

ALTER TABLE public.course_reviews
  DROP CONSTRAINT IF EXISTS course_reviews_academic_term_id_fkey;

ALTER TABLE public.course_reviews
  ALTER COLUMN academic_term_id SET NOT NULL;

ALTER TABLE public.course_reviews
  ADD CONSTRAINT course_reviews_academic_term_id_fkey
  FOREIGN KEY (academic_term_id)
  REFERENCES public.academic_terms(id)
  ON DELETE RESTRICT;

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
  v_academic_terms JSONB;
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
        'id', academic_term.id,
        'academic_year', academic_term.academic_year,
        'term', academic_term.term
      )
      ORDER BY
        academic_term.academic_year DESC,
        CASE academic_term.term
          WHEN 'fall' THEN 4
          WHEN 'summer' THEN 3
          WHEN 'spring' THEN 2
          WHEN 'winter' THEN 1
        END DESC
    ),
    '[]'::JSONB
  )
  INTO v_academic_terms
  FROM public.academic_terms AS academic_term;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', review.id,
        'professor_id', review.professor_id,
        'professor_name', professor.name,
        'academic_term_id', academic_term.id,
        'academic_year', academic_term.academic_year,
        'term', academic_term.term,
        'overall_rating', review.overall_rating,
        'fun_rating', review.fun_rating,
        'useful_rating', review.useful_rating,
        'easy_a_rating', review.easy_a_rating,
        'professor_rating', review.professor_rating,
        'review_text', review.review_text,
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
  JOIN public.academic_terms AS academic_term
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
    'academic_terms', v_academic_terms,
    'reviews', v_reviews,
    'aggregate', v_aggregate,
    'professor_aggregates', v_professor_aggregates
  );
END;
$$;

DROP FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
);

CREATE FUNCTION public.upsert_course_review(
  p_course_id UUID,
  p_professor_id UUID,
  p_overall_rating SMALLINT,
  p_fun_rating SMALLINT,
  p_useful_rating SMALLINT,
  p_easy_a_rating SMALLINT,
  p_professor_rating SMALLINT,
  p_review_text TEXT,
  p_academic_term_id UUID
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

  IF p_academic_term_id IS NULL THEN
    RAISE EXCEPTION 'Academic term is required'
      USING ERRCODE = '23502';
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.academic_terms
    WHERE id = p_academic_term_id
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

REVOKE ALL ON FUNCTION public.get_course_review_snapshot(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_course_review_snapshot(UUID)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
