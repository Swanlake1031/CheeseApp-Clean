-- Make the course catalog the single source of truth for Course discovery.
-- This migration adds metadata only; it does not insert sample courses.

BEGIN;

ALTER TABLE public.courses
  ADD COLUMN subject TEXT,
  ADD COLUMN year_level SMALLINT,
  ADD COLUMN is_popular BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.courses
SET
  subject = 'ECON',
  year_level = 1,
  is_popular = TRUE
WHERE code = 'ECON 1B03';

ALTER TABLE public.courses
  ALTER COLUMN subject SET NOT NULL,
  ALTER COLUMN year_level SET NOT NULL,
  ADD CONSTRAINT courses_subject_valid
    CHECK (subject IN ('MATH', 'STATS', 'ECON', 'COMMERCE')),
  ADD CONSTRAINT courses_year_level_valid
    CHECK (year_level BETWEEN 1 AND 4);

CREATE OR REPLACE FUNCTION public.get_course_catalog()
RETURNS TABLE (
  id UUID,
  code TEXT,
  title TEXT,
  subject TEXT,
  year_level SMALLINT,
  is_popular BOOLEAN,
  professors JSONB,
  review_count BIGINT,
  overall_rating NUMERIC,
  fun_rating NUMERIC,
  useful_rating NUMERIC,
  easy_a_rating NUMERIC,
  professor_rating NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    course.id,
    course.code,
    course.title,
    course.subject,
    course.year_level,
    course.is_popular,
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', professor.id,
            'name', professor.name
          )
          ORDER BY professor.name
        )
        FROM public.course_professors AS course_professor
        JOIN public.professors AS professor
          ON professor.id = course_professor.professor_id
        WHERE course_professor.course_id = course.id
      ),
      '[]'::JSONB
    ) AS professors,
    COUNT(review.id)::BIGINT AS review_count,
    ROUND(AVG(review.overall_rating)::NUMERIC, 1) AS overall_rating,
    ROUND(AVG(review.fun_rating)::NUMERIC, 1) AS fun_rating,
    ROUND(AVG(review.useful_rating)::NUMERIC, 1) AS useful_rating,
    ROUND(AVG(review.easy_a_rating)::NUMERIC, 1) AS easy_a_rating,
    ROUND(AVG(review.professor_rating)::NUMERIC, 1) AS professor_rating
  FROM public.courses AS course
  LEFT JOIN public.course_reviews AS review
    ON review.course_id = course.id
  GROUP BY
    course.id,
    course.code,
    course.title,
    course.subject,
    course.year_level,
    course.is_popular
  ORDER BY course.is_popular DESC, course.code;
END;
$$;

REVOKE ALL ON FUNCTION public.get_course_catalog()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_course_catalog()
TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
