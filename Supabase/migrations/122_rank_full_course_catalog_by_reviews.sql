-- "Popular courses" is the complete catalog ranked by real review volume.
--
-- Keep the legacy is_popular output column for supported app versions that
-- still filter on it, but return TRUE for every catalog row. New clients no
-- longer use this compatibility field to decide course visibility.

BEGIN;

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
    TRUE AS is_popular,
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
    course.year_level
  ORDER BY COUNT(review.id) DESC, course.code;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
