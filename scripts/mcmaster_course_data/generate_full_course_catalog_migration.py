#!/usr/bin/env python3
"""Generate the full undergraduate catalog migration from MyTimetable CSV."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


SOURCE_NAME = "McMaster MyTimetable"
ACADEMIC_YEAR = 2026
TERM = "fall"
ACADEMIC_CAREER = "UGRD"
FALLBACK_PROFESSOR_ID = "00000000-0000-4000-8000-00000000c0de"


def sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def infer_year_level(course_code: str) -> int:
    parts = course_code.split(maxsplit=1)
    if len(parts) != 2:
        raise ValueError(f"Invalid course code: {course_code}")
    match = re.search(r"[1-9]", parts[1])
    if match is None:
        raise ValueError(f"Cannot infer year level for {course_code}")
    return int(match.group())


def load_courses(path: Path) -> list[dict[str, str | int]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        source_rows = list(csv.DictReader(handle))

    required_columns = {"course_code", "course_title", "department"}
    if not source_rows:
        raise ValueError("Course catalog is empty")
    if not required_columns.issubset(source_rows[0]):
        raise ValueError("Course catalog is missing required columns")

    courses: list[dict[str, str | int]] = []
    seen_codes: set[str] = set()
    for source_row in source_rows:
        code = source_row["course_code"].strip()
        title = source_row["course_title"].strip()
        subject = source_row["department"].strip()
        if not code or not title or not subject:
            raise ValueError("Course code, title, and department are required")
        if code in seen_codes:
            raise ValueError(f"Duplicate course code: {code}")
        if not re.fullmatch(r"[A-Z][A-Z0-9]*", subject):
            raise ValueError(f"Invalid department: {subject}")
        if code.split(maxsplit=1)[0] != subject:
            raise ValueError(f"Course department mismatch: {code} / {subject}")

        seen_codes.add(code)
        courses.append(
            {
                "code": code,
                "title": title,
                "subject": subject,
                "year_level": infer_year_level(code),
            }
        )

    return sorted(courses, key=lambda row: str(row["code"]))


def render_migration(courses: list[dict[str, str | int]]) -> str:
    subjects = sorted({str(row["subject"]) for row in courses})
    maximum_year_level = max(int(row["year_level"]) for row in courses)
    subject_constraint = ", ".join(sql_text(subject) for subject in subjects)
    course_values = ",\n".join(
        "  ("
        + ", ".join(
            [
                sql_text(str(row["code"])),
                sql_text(str(row["title"])),
                sql_text(str(row["subject"])),
                str(row["year_level"]),
                "FALSE",
            ]
        )
        + ")"
        for row in courses
    )
    offering_values = ",\n".join(
        f"  ({sql_text(str(row['code']))})" for row in courses
    )

    return f"""-- Publish the complete {ACADEMIC_YEAR} {TERM.title()} undergraduate catalog.
-- Source: {SOURCE_NAME}. PDF/outline availability is intentionally optional.
-- Existing courses, reviews, professor assignments, and outlines are preserved.

BEGIN;

ALTER TABLE public.courses
  DROP CONSTRAINT IF EXISTS courses_subject_valid,
  DROP CONSTRAINT IF EXISTS courses_year_level_valid,
  ADD CONSTRAINT courses_subject_valid
    CHECK (subject IN ({subject_constraint})),
  ADD CONSTRAINT courses_year_level_valid
    CHECK (year_level BETWEEN 1 AND {maximum_year_level});

CREATE TABLE IF NOT EXISTS public.course_catalog_offerings (
  course_id UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  academic_year SMALLINT NOT NULL,
  term TEXT NOT NULL,
  academic_career TEXT NOT NULL,
  source_name TEXT NOT NULL,
  last_verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (course_id, academic_year, term, academic_career),
  CONSTRAINT course_catalog_offerings_year_range
    CHECK (academic_year BETWEEN 2000 AND 2200),
  CONSTRAINT course_catalog_offerings_term_valid
    CHECK (term IN ('winter', 'spring', 'summer', 'fall')),
  CONSTRAINT course_catalog_offerings_career_valid
    CHECK (academic_career = 'UGRD'),
  CONSTRAINT course_catalog_offerings_source_not_blank
    CHECK (btrim(source_name) <> '')
);

ALTER TABLE public.course_catalog_offerings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can view course catalog offerings"
ON public.course_catalog_offerings;
CREATE POLICY "Authenticated can view course catalog offerings"
ON public.course_catalog_offerings
FOR SELECT
TO authenticated
USING (true);

REVOKE ALL ON public.course_catalog_offerings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.course_catalog_offerings TO authenticated;

INSERT INTO public.academic_terms (academic_year, term)
VALUES ({ACADEMIC_YEAR}, {sql_text(TERM)})
ON CONFLICT (academic_year, term) DO NOTHING;

INSERT INTO public.courses (code, title, subject, year_level, is_popular)
VALUES
{course_values}
ON CONFLICT (code) DO UPDATE
SET
  title = EXCLUDED.title,
  subject = EXCLUDED.subject,
  year_level = EXCLUDED.year_level,
  updated_at = NOW();

WITH offered_course_codes (code) AS (
  VALUES
{offering_values}
)
INSERT INTO public.course_catalog_offerings (
  course_id,
  academic_year,
  term,
  academic_career,
  source_name,
  last_verified_at
)
SELECT
  course.id,
  {ACADEMIC_YEAR},
  {sql_text(TERM)},
  {sql_text(ACADEMIC_CAREER)},
  {sql_text(SOURCE_NAME)},
  NOW()
FROM offered_course_codes
JOIN public.courses AS course USING (code)
ON CONFLICT (course_id, academic_year, term, academic_career) DO UPDATE
SET
  source_name = EXCLUDED.source_name,
  last_verified_at = EXCLUDED.last_verified_at;

-- Reviews currently require a professor selection. Courses without a known
-- assignment receive one neutral fallback option so they are immediately
-- reviewable; known course-professor assignments are left untouched.
INSERT INTO public.professors (id, name)
VALUES (
  {sql_text(FALLBACK_PROFESSOR_ID)}::UUID,
  'Instructor not listed'
)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name;

INSERT INTO public.course_professors (course_id, professor_id)
SELECT
  course.id,
  {sql_text(FALLBACK_PROFESSOR_ID)}::UUID
FROM public.courses AS course
WHERE NOT EXISTS (
  SELECT 1
  FROM public.course_professors AS course_professor
  WHERE course_professor.course_id = course.id
)
ON CONFLICT (course_id, professor_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_csv", type=Path)
    parser.add_argument("output_sql", type=Path)
    args = parser.parse_args()

    courses = load_courses(args.input_csv)
    args.output_sql.write_text(render_migration(courses), encoding="utf-8")
    print(
        f"Wrote {len(courses)} courses across "
        f"{len({row['subject'] for row in courses})} subjects to {args.output_sql}"
    )


if __name__ == "__main__":
    main()
