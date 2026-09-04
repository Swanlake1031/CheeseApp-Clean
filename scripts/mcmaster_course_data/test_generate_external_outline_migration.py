#!/usr/bin/env python3

import unittest
from pathlib import Path

from generate_external_outline_migration import (
    is_allowed_url,
    load_rows,
    render_migration,
    sql_text,
    year_level,
)


class ExternalOutlineMigrationTests(unittest.TestCase):
    def test_sql_text_escapes_apostrophes(self):
        self.assertEqual(sql_text("Student's outline"), "'Student''s outline'")
        self.assertEqual(sql_text(""), "NULL")

    def test_url_allowlist_rejects_lookalike_hosts(self):
        self.assertTrue(is_allowed_url("https://physics.mcmaster.ca/outline.pdf"))
        self.assertTrue(
            is_allowed_url("https://mcmaster.simplesyllabusca.com/doc/example")
        )
        self.assertFalse(is_allowed_url("https://mcmaster.ca.example.com/outline"))
        self.assertFalse(is_allowed_url("http://physics.mcmaster.ca/outline.pdf"))

    def test_year_level_uses_course_number(self):
        self.assertEqual(year_level("COMMERCE 1E03"), 1)
        self.assertEqual(year_level("IBEHS 5P03"), 5)

    def test_checked_snapshot_generates_expected_scope(self):
        directory = Path(__file__).resolve().parent
        courses, candidates = load_rows(
            directory / "generated" / "course_outline_index.csv",
            directory / "generated" / "outline_candidates.csv",
        )
        migration = render_migration(courses, candidates)

        self.assertEqual(len(courses), 229)
        self.assertEqual(len(candidates), 241)
        self.assertIn("ON CONFLICT (course_id, source_url) DO UPDATE", migration)
        self.assertNotIn("needs_review=true", migration.split("BEGIN;", 1)[1])

    def test_visual_audit_adds_only_approved_candidates(self):
        directory = Path(__file__).resolve().parent
        courses, candidates = load_rows(
            directory / "generated" / "course_outline_index.csv",
            directory / "generated" / "outline_candidates.csv",
            directory / "generated" / "outline_audit_results.csv",
        )

        self.assertEqual(len(courses), 381)
        self.assertEqual(len(candidates), 393)
        self.assertNotIn("COMMERCE 4EL3", {row["course_code"] for row in candidates})
        self.assertNotIn("IBEHS 3H03", {row["course_code"] for row in candidates})


if __name__ == "__main__":
    unittest.main()
