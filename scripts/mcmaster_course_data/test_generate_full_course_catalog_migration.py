#!/usr/bin/env python3

import csv
import tempfile
import unittest
from pathlib import Path

from generate_full_course_catalog_migration import (
    FALLBACK_PROFESSOR_ID,
    infer_year_level,
    load_courses,
    render_migration,
    sql_text,
)


class FullCourseCatalogMigrationTests(unittest.TestCase):
    def test_sql_text_escapes_apostrophes(self):
        self.assertEqual(sql_text("Children's Literature"), "'Children''s Literature'")

    def test_infer_year_level_supports_fifth_year(self):
        self.assertEqual(infer_year_level("MATH 1X03"), 1)
        self.assertEqual(infer_year_level("IBEHS 5P03"), 5)

    def test_official_snapshot_has_complete_expected_scope(self):
        directory = Path(__file__).resolve().parent
        courses = load_courses(directory / "courses_fall_2026_all.csv")

        self.assertEqual(len(courses), 1604)
        self.assertEqual(len({row["subject"] for row in courses}), 127)
        self.assertEqual(len({row["code"] for row in courses}), 1604)
        self.assertTrue(all(row["title"] for row in courses))

    def test_migration_preserves_existing_data_and_enables_reviews(self):
        directory = Path(__file__).resolve().parent
        courses = load_courses(directory / "courses_fall_2026_all.csv")
        migration = render_migration(courses)

        self.assertIn("ON CONFLICT (code) DO UPDATE", migration)
        self.assertNotIn("DELETE FROM public.courses", migration)
        self.assertIn("course_catalog_offerings", migration)
        self.assertIn(FALLBACK_PROFESSOR_ID, migration)
        self.assertIn("WHERE NOT EXISTS", migration)

    def test_duplicate_course_codes_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "courses.csv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["course_code", "course_title", "department"],
                )
                writer.writeheader()
                writer.writerow(
                    {"course_code": "MATH 1X03", "course_title": "A", "department": "MATH"}
                )
                writer.writerow(
                    {"course_code": "MATH 1X03", "course_title": "B", "department": "MATH"}
                )

            with self.assertRaisesRegex(ValueError, "Duplicate course code"):
                load_courses(path)


if __name__ == "__main__":
    unittest.main()
