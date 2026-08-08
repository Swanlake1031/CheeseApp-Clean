-- ECON 1B03 pilot: course identity, private outline metadata, and typed reviews.
--
-- Deployment order:
-- 1. Apply this migration.
-- 2. Upload the validated PDF with upsert=false to the immutable storage_path.
-- 3. Verify authenticated read access and confirm anonymous/write access fails.
--
-- Rollback limits:
-- - Dropping course_reviews deletes pilot review data.
-- - Storage objects must be removed separately before dropping the bucket.
-- - This migration seeds only ECON 1B03, Colin Mang, Summer 2026, and one outline.

BEGIN;

CREATE TABLE public.courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT courses_code_not_blank CHECK (btrim(code) <> ''),
  CONSTRAINT courses_title_not_blank CHECK (btrim(title) <> '')
);

INSERT INTO public.courses (id, code, title)
VALUES (
  'ec011b03-0000-4000-8000-000000000001',
  'ECON 1B03',
  'Introductory Microeconomics'
);

CREATE TABLE public.professors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT professors_name_not_blank CHECK (btrim(name) <> '')
);

INSERT INTO public.professors (id, name)
VALUES (
  'c0110000-0000-4000-8000-000000000001',
  'Colin Mang'
);

CREATE TABLE public.academic_terms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  academic_year SMALLINT NOT NULL,
  term TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT academic_terms_year_range
    CHECK (academic_year BETWEEN 2000 AND 2200),
  CONSTRAINT academic_terms_term_valid
    CHECK (term IN ('winter', 'spring', 'summer', 'fall')),
  UNIQUE (academic_year, term)
);

INSERT INTO public.academic_terms (id, academic_year, term)
VALUES (
  '20260000-0000-4000-8000-000000000001',
  2026,
  'summer'
);

CREATE TABLE public.course_professors (
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  professor_id UUID NOT NULL REFERENCES public.professors(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (course_id, professor_id)
);

INSERT INTO public.course_professors (course_id, professor_id)
VALUES (
  'ec011b03-0000-4000-8000-000000000001',
  'c0110000-0000-4000-8000-000000000001'
);

CREATE TABLE public.course_outlines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  academic_year SMALLINT NOT NULL,
  term TEXT NOT NULL,
  professor_name TEXT,
  title TEXT NOT NULL,
  storage_path TEXT NOT NULL UNIQUE,
  original_filename TEXT NOT NULL,
  mime_type TEXT NOT NULL DEFAULT 'application/pdf',
  file_size_bytes BIGINT NOT NULL,
  sha256 TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT course_outlines_academic_year_range
    CHECK (academic_year BETWEEN 2000 AND 2200),
  CONSTRAINT course_outlines_term_valid
    CHECK (term IN ('winter', 'spring', 'summer', 'fall')),
  CONSTRAINT course_outlines_professor_name_not_blank
    CHECK (professor_name IS NULL OR btrim(professor_name) <> ''),
  CONSTRAINT course_outlines_title_not_blank CHECK (btrim(title) <> ''),
  CONSTRAINT course_outlines_storage_path_bound_to_metadata
    CHECK (
      storage_path =
        course_id::TEXT || '/' ||
        academic_year::TEXT || '/' ||
        term || '/' ||
        sha256 || '.pdf'
    ),
  CONSTRAINT course_outlines_original_filename_not_blank
    CHECK (btrim(original_filename) <> ''),
  CONSTRAINT course_outlines_pdf_mime CHECK (mime_type = 'application/pdf'),
  CONSTRAINT course_outlines_file_size
    CHECK (file_size_bytes BETWEEN 1 AND 20971520),
  CONSTRAINT course_outlines_sha256 CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  UNIQUE (course_id, academic_year, term, sha256)
);

INSERT INTO public.course_outlines (
  course_id,
  academic_year,
  term,
  professor_name,
  title,
  storage_path,
  original_filename,
  mime_type,
  file_size_bytes,
  sha256
)
VALUES (
  'ec011b03-0000-4000-8000-000000000001',
  2026,
  'summer',
  'Colin Mang',
  'ECON 1B03 Course Outline Summer 2026',
  'ec011b03-0000-4000-8000-000000000001/2026/summer/8b0b4371f4c5b7e68aa635713f9a3100d38c4b5f93ae62240f920a405c01bad2.pdf',
  'ECON 1B03 Course Outline Summer 2026 - C.Mang.pdf',
  'application/pdf',
  216207,
  '8b0b4371f4c5b7e68aa635713f9a3100d38c4b5f93ae62240f920a405c01bad2'
);

CREATE INDEX course_outlines_course_term_idx
  ON public.course_outlines (course_id, academic_year DESC, term);

CREATE TABLE public.course_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  professor_id UUID NOT NULL REFERENCES public.professors(id) ON DELETE RESTRICT,
  academic_term_id UUID REFERENCES public.academic_terms(id) ON DELETE SET NULL,
  course_rating SMALLINT NOT NULL,
  difficulty_rating SMALLINT NOT NULL,
  professor_rating SMALLINT NOT NULL,
  review_text TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT course_reviews_course_rating
    CHECK (course_rating BETWEEN 1 AND 5),
  CONSTRAINT course_reviews_difficulty_rating
    CHECK (difficulty_rating BETWEEN 1 AND 5),
  CONSTRAINT course_reviews_professor_rating
    CHECK (professor_rating BETWEEN 1 AND 5),
  CONSTRAINT course_reviews_text_length
    CHECK (review_text IS NULL OR char_length(review_text) <= 500),
  UNIQUE (course_id, user_id)
);

CREATE INDEX course_reviews_course_updated_idx
  ON public.course_reviews (course_id, updated_at DESC);

ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.professors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.academic_terms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_professors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_outlines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view courses"
ON public.courses
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Authenticated can view course outlines"
ON public.course_outlines
FOR SELECT
TO authenticated
USING (true);

REVOKE ALL ON public.courses FROM anon, authenticated;
REVOKE ALL ON public.professors FROM anon, authenticated;
REVOKE ALL ON public.academic_terms FROM anon, authenticated;
REVOKE ALL ON public.course_professors FROM anon, authenticated;
REVOKE ALL ON public.course_outlines FROM anon, authenticated;
REVOKE ALL ON public.course_reviews FROM anon, authenticated;

GRANT SELECT ON public.courses TO authenticated;
GRANT SELECT ON public.course_outlines TO authenticated;

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
        'course_rating', review.course_rating,
        'difficulty_rating', review.difficulty_rating,
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
    'course_rating', ROUND(AVG(course_rating)::NUMERIC, 1),
    'difficulty_rating', ROUND(AVG(difficulty_rating)::NUMERIC, 1),
    'professor_rating', ROUND(AVG(professor_rating)::NUMERIC, 1)
  )
  INTO v_aggregate
  FROM public.course_reviews
  WHERE course_id = p_course_id;

  RETURN jsonb_build_object(
    'professors', v_professors,
    'reviews', v_reviews,
    'aggregate', v_aggregate
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_course_review(
  p_course_id UUID,
  p_professor_id UUID,
  p_course_rating SMALLINT,
  p_difficulty_rating SMALLINT,
  p_professor_rating SMALLINT,
  p_review_text TEXT,
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

CREATE OR REPLACE FUNCTION public.delete_course_review(
  p_course_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_deleted_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.course_reviews
  WHERE course_id = p_course_id
    AND user_id = v_user_id;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
  RETURN v_deleted_count > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.get_course_review_snapshot(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.delete_course_review(UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_course_review_snapshot(UUID)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_course_review(
  UUID, UUID, SMALLINT, SMALLINT, SMALLINT, TEXT, UUID
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_course_review(UUID)
TO authenticated;

INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'course-outlines',
  'course-outlines',
  false,
  20971520,
  ARRAY['application/pdf']
);

CREATE POLICY "Authenticated can view registered course outlines"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'course-outlines'
  AND EXISTS (
    SELECT 1
    FROM public.course_outlines AS outline
    WHERE outline.storage_path = storage.objects.name
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;
