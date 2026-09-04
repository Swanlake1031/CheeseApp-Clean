#!/usr/bin/env python3

import unittest

from audit_candidate_outlines import (
    allowed_official_url,
    course_code_pattern,
    infer_term_and_year,
)


class CandidateOutlineAuditTests(unittest.TestCase):
    def test_term_inference_supports_words_and_engineering_shorthand(self):
        self.assertEqual(
            infer_term_and_year("outline-F2025.pdf", "")[:2],
            ("2025", "fall"),
        )
        self.assertEqual(
            infer_term_and_year("outline.pdf", "Academic Year 2025/26 Term: Fall")[:2],
            ("2025", "fall"),
        )

    def test_engineering_subject_aliases_match_official_templates(self):
        self.assertIsNotNone(course_code_pattern("CHEMENG 4A03").search("ChE 4A03"))
        self.assertIsNotNone(course_code_pattern("CIVENG 2X03").search("CIV ENG 2X03"))
        self.assertIsNotNone(course_code_pattern("ELECENG 2CI4").search("EE 2CI4"))

    def test_full_year_suffix_can_match_shared_ab_outline(self):
        self.assertIsNotNone(course_code_pattern("IBEHS 5P06A").search("IBEHS 5P06A/B"))

    def test_official_host_check_rejects_http_and_lookalikes(self):
        self.assertTrue(allowed_official_url("https://www.eng.mcmaster.ca/a.pdf"))
        self.assertFalse(allowed_official_url("http://www.eng.mcmaster.ca/a.pdf"))
        self.assertFalse(allowed_official_url("https://mcmaster.ca.example.com/a.pdf"))


if __name__ == "__main__":
    unittest.main()
