#!/usr/bin/env python3
"""Generate an idempotent Supabase migration from reviewed outline CSVs."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path
from urllib.parse import urlparse


ALLOWED_TERMS = {"winter", "spring", "summer", "fall"}


def sql_text(value: str | None) -> str:
    if not value:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def is_allowed_url(value: str) -> bool:
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and (
        host == "mcmaster.ca"
        or host.endswith(".mcmaster.ca")
        or host == "simplesyllabusca.com"
        or host.endswith(".simplesyllabusca.com")
    )


def year_level(course_code: str) -> int:
    course_number = course_code.split(maxsplit=1)[-1]
    match = re.search(r"[1-9]", course_number)
    if not match:
        raise ValueError(f"Cannot infer year level for {course_code}")
    return int(match.group())


def load_rows(
    course_index_path: Path,
    candidates_path: Path,
    audit_results_path: Path | None = None,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    with course_index_path.open(encoding="utf-8-sig", newline="") as handle:
        index_rows = list(csv.DictReader(handle))
    with candidates_path.open(encoding="utf-8-sig", newline="") as handle:
        candidate_rows = list(csv.DictReader(handle))

    safe_courses = {
        row["course_code"]: row
        for row in index_rows
        if row["outline_status"] == "found" and row["needs_review"] == "False"
    }
    safe_candidates = [
        row
        for row in candidate_rows
        if row["course_code"] in safe_courses
        and row["is_preferred"] == "True"
        and row["needs_review"] == "False"
    ]

    if audit_results_path is not None:
        with audit_results_path.open(encoding="utf-8-sig", newline="") as handle:
            approved_audits = {
                (row["course_code"], row["document_url"]): row
                for row in csv.DictReader(handle)
                if row["audit_status"] == "approved"
            }
        candidate_lookup = {
            (row["course_code"], row["document_url"]): row
            for row in candidate_rows
        }
        for key, audit in approved_audits.items():
            if key not in candidate_lookup:
                raise ValueError(f"Audited URL is absent from candidates: {key}")
            candidate = dict(candidate_lookup[key])
            candidate["academic_year"] = audit["academic_year"]
            candidate["term"] = audit["term"]
            candidate["needs_review"] = "False"
            safe_candidates.append(candidate)
            safe_courses[candidate["course_code"]] = next(
                row for row in index_rows
                if row["course_code"] == candidate["course_code"]
            )

    expected_pairs = {
        (course_code, url.strip())
        for course_code, row in safe_courses.items()
        for url in row["preferred_document_urls"].split("|")
        if url.strip()
    }
    actual_pairs = {
        (row["course_code"], row["document_url"])
        for row in safe_candidates
    }
    if len(actual_pairs) != len(safe_candidates):
        raise ValueError("Preferred candidates contain duplicate course URLs")
    if actual_pairs != expected_pairs:
        raise ValueError("Preferred candidate rows do not match the reviewed index")

    for row in safe_candidates:
        if row["term"] not in ALLOWED_TERMS or not row["academic_year"].isdigit():
            raise ValueError(f"Missing academic term for {row['course_code']}")
        if not is_allowed_url(row["document_url"]):
            raise ValueError(f"Unapproved document URL: {row['document_url']}")
        if row["source_page_url"] and not is_allowed_url(row["source_page_url"]):
            raise ValueError(f"Unapproved source page URL: {row['source_page_url']}")

    return (
        [safe_courses[code] for code in sorted(safe_courses)],
        sorted(
            safe_candidates,
            key=lambda row: (row["course_code"], row["document_url"]),
        ),
    )


def render_migration(
    courses: list[dict[str, str]],
    candidates: list[dict[str, str]],
) -> str:
    subjects = sorted(
        {"MATH", "STATS", "ECON", "COMMERCE"}
        | {row["department"] for row in courses}
    )
    subject_constraint = ", ".join(sql_text(subject) for subject in subjects)
    maximum_year_level = max(4, *(year_level(row["course_code"]) for row in courses))
    course_values = []
    for row in courses:
        course_values.append(
            "  ("
            + ", ".join(
                [
                    sql_text(row["course_code"]),
                    sql_text(row["course_title"]),
                    sql_text(row["department"]),
                    str(year_level(row["course_code"])),
                    "FALSE",
                ]
            )
            + ")"
        )

    outline_values = []
    for row in candidates:
        is_web = row["source_name"] == "McMaster Simple Syllabus"
        source_kind = "external_web" if is_web else "external_pdf"
        mime_type = "text/html" if is_web else "application/pdf"
        section_suffix = f" Section {row['section']}" if row["section"] else ""
        title = (
            f"{row['course_code']} Course Outline{section_suffix} "
            f"{row['term'].title()} {row['academic_year']}"
        )
        outline_values.append(
            "  ("
            + ", ".join(
                [
                    sql_text(row["course_code"]),
                    row["academic_year"],
                    sql_text(row["term"]),
                    sql_text(row["professor_name"]),
                    sql_text(title),
                    sql_text(source_kind),
                    sql_text(row["document_url"]),
                    sql_text(row["source_page_url"]),
                    sql_text(row["source_name"]),
                    sql_text(mime_type),
                ]
            )
            + ")"
        )

    return f"""-- Import only preferred course-outline links that passed review.
-- Generated from the September 4, 2026 McMaster collection snapshot.
-- Rejected and unresolved manual-review rows are intentionally excluded.
-- This migration stores URL metadata only; it does not download or persist PDFs.

BEGIN;

ALTER TABLE public.courses
  DROP CONSTRAINT courses_subject_valid,
  DROP CONSTRAINT courses_year_level_valid,
  ADD CONSTRAINT courses_subject_valid
    CHECK (subject IN ({subject_constraint})),
  ADD CONSTRAINT courses_year_level_valid
    CHECK (year_level BETWEEN 1 AND {maximum_year_level});

-- V2 returns the extended catalog. Values above fourth year are intentionally
-- grouped into the client's existing "fourth year or above" filter.
CREATE OR REPLACE FUNCTION public.get_course_catalog_v2()
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
    LEAST(course.year_level, 4)::SMALLINT,
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
  LEFT JOIN public.course_reviews AS review ON review.course_id = course.id
  GROUP BY course.id, course.code, course.title, course.subject, course.year_level
  ORDER BY COUNT(review.id) DESC, course.code;
END;
$$;

-- Keep V1 restricted to subjects understood by released clients. It delegates
-- to V2 so aggregate/ranking behavior stays identical without exposing new enum
-- values that older app binaries cannot decode.
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT catalog.*
  FROM public.get_course_catalog_v2() AS catalog
  WHERE catalog.subject IN ('MATH', 'STATS', 'ECON', 'COMMERCE')
  ORDER BY catalog.review_count DESC, catalog.code;
$$;

REVOKE ALL ON FUNCTION public.get_course_catalog_v2()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_course_catalog_v2()
TO authenticated;

REVOKE ALL ON FUNCTION public.get_course_catalog()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_course_catalog()
TO authenticated;

INSERT INTO public.courses (code, title, subject, year_level, is_popular)
VALUES
{',\n'.join(course_values)}
ON CONFLICT (code) DO UPDATE
SET title = EXCLUDED.title,
    subject = EXCLUDED.subject,
    year_level = EXCLUDED.year_level,
    updated_at = NOW();

WITH reviewed_outlines(
  course_code, academic_year, term, professor_name, title,
  source_kind, source_url, source_page_url, source_name, mime_type
) AS (
  VALUES
{',\n'.join(outline_values)}
)
INSERT INTO public.course_external_outlines (
  course_id, academic_year, term, professor_name, title,
  source_kind, source_url, source_page_url, source_name, mime_type,
  last_verified_at
)
SELECT course.id, outline.academic_year, outline.term,
  outline.professor_name, outline.title, outline.source_kind,
  outline.source_url, outline.source_page_url, outline.source_name,
  outline.mime_type, NOW()
FROM reviewed_outlines AS outline
JOIN public.courses AS course ON course.code = outline.course_code
ON CONFLICT (course_id, source_url) DO UPDATE
SET academic_year = EXCLUDED.academic_year,
    term = EXCLUDED.term,
    professor_name = EXCLUDED.professor_name,
    title = EXCLUDED.title,
    source_kind = EXCLUDED.source_kind,
    source_page_url = EXCLUDED.source_page_url,
    source_name = EXCLUDED.source_name,
    mime_type = EXCLUDED.mime_type,
    last_verified_at = NOW();

NOTIFY pgrst, 'reload schema';

COMMIT;
"""


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--course-index",
        type=Path,
        default=directory / "generated" / "course_outline_index.csv",
    )
    parser.add_argument(
        "--candidates",
        type=Path,
        default=directory / "generated" / "outline_candidates.csv",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--audit-results", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    courses, candidates = load_rows(
        args.course_index,
        args.candidates,
        args.audit_results,
    )
    args.output.write_text(render_migration(courses, candidates), encoding="utf-8")
    print(f"Wrote {len(courses)} courses and {len(candidates)} outline URLs to {args.output}")


if __name__ == "__main__":
    main()
