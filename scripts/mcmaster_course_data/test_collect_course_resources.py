import unittest
import csv
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from collect_course_resources import (
    Candidate,
    CommerceTableParser,
    document_code_conflicts,
    EngineeringCourseParser,
    discover_commerce_pages,
    find_catalog_codes,
    infer_term,
    load_commerce_manifest,
    mark_preferred,
)


class CourseResourceTests(unittest.TestCase):
    def test_simple_always_beats_newer_fallback(self):
        candidates = [
            Candidate(
                "MATH 1X03", "Calculus", "MATH", "2025", "fall", "",
                "A", "https://simple.example/1", "", "simple_syllabus",
                "simple", 1,
            ),
            Candidate(
                "MATH 1X03", "Calculus", "MATH", "2026", "fall", "",
                "B", "https://math.example/2.pdf", "", "official_department",
                "math", 2,
            ),
        ]
        mark_preferred(candidates)
        self.assertTrue(candidates[0].is_preferred)
        self.assertFalse(candidates[1].is_preferred)

    def test_all_sections_in_newest_term_are_preferred(self):
        candidates = [
            Candidate("CHEM 1A03", "Chem", "CHEM", "2025", "fall", "C01", "A", "u1", "", "simple_syllabus", "simple", 1),
            Candidate("CHEM 1A03", "Chem", "CHEM", "2026", "fall", "C01", "B", "u2", "", "simple_syllabus", "simple", 1),
            Candidate("CHEM 1A03", "Chem", "CHEM", "2026", "fall", "C02", "C", "u3", "", "simple_syllabus", "simple", 1),
        ]
        mark_preferred(candidates)
        self.assertEqual([False, True, True], [item.is_preferred for item in candidates])

    def test_engineering_parser_keeps_card_boundary(self):
        html = """
        <li class="course-listing__course"><span>MECH ENG 2C04</span>
        <p>Prerequisite: ENGINEER 1P13 TERM 1</p>
        <div>Instructor Dr. Elizabeth Hassan</div>
        <a href="Course-Outline-2026-2027-ME-2C04.pdf">Download the Outline</a>
        </li>
        """
        parser = EngineeringCourseParser()
        parser.feed(html)
        text, links = parser.cards[0]
        codes = find_catalog_codes(text, {"MECHENG 2C04", "ENGINEER 1P13"})
        self.assertEqual("MECHENG 2C04", codes[0])
        self.assertEqual(1, len(links))
        self.assertEqual(("2026", "fall", False), infer_term(text, links[0]))

    def test_compact_cross_listed_codes_are_found(self):
        codes = find_catalog_codes(
            "MECHTRON-SFWRENG4AA4-DouglasDown_Fall2026.pdf",
            {"SFWRENG 4AA4", "MECHTRON 4AA4"},
        )
        self.assertIn("SFWRENG 4AA4", codes)

    def test_stale_engineering_card_pdf_is_a_conflict(self):
        self.assertTrue(document_code_conflicts(
            "AUTOTECH 2AE3",
            "https://eng.example/AUTOTECH-2AC3-Winter-2024.pdf",
        ))

    def test_cross_listed_pdf_with_target_number_is_not_a_conflict(self):
        self.assertFalse(document_code_conflicts(
            "MECHENG 4BB3",
            "https://eng.example/IBEHS-4B03-ME-4BB3-course-outline.pdf",
        ))

    def test_full_year_suffix_may_be_omitted_from_pdf_name(self):
        self.assertFalse(document_code_conflicts(
            "IBEHS 4E09A",
            "https://eng.example/IBEHS-4E09-Thesis-Course-Outline.pdf",
        ))

    def test_commerce_table_parser_keeps_term_and_cells(self):
        html = """
        <h4><strong>Winter 2026</strong></h4>
        <table><tr><td>1AA3</td><td>C01</td><td>E. Islam</td>
        <td><a href="outline.pdf">Outline</a></td></tr></table>
        """
        parser = CommerceTableParser()
        parser.feed(html)
        term, cells, links = parser.rows[0]
        self.assertEqual("Winter 2026", term)
        self.assertEqual(["1AA3", "C01", "E. Islam", "Outline"], cells)
        self.assertEqual(["outline.pdf"], links)

    def test_commerce_page_discovery_uses_slug(self):
        html = '<a href="/descriptions/1aa3/">Accounting</a>'
        pages = discover_commerce_pages(html, {"COMMERCE 1AA3"})
        self.assertEqual(
            "https://ug.degroote.mcmaster.ca/descriptions/1aa3/",
            pages["COMMERCE 1AA3"],
        )

    def test_existing_commerce_manifest_is_url_only_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outlines.csv"
            with path.open("w", newline="", encoding="utf-8") as file:
                writer = csv.DictWriter(file, fieldnames=[
                    "course_code",
                    "course_title",
                    "term",
                    "section",
                    "instructor",
                    "pdf_url",
                    "course_page_url",
                ])
                writer.writeheader()
                writer.writerow({
                    "course_code": "1AA3",
                    "course_title": "Accounting",
                    "term": "Winter 2026",
                    "section": "C01",
                    "instructor": "E. Islam",
                    "pdf_url": "https://example.edu/1aa3.pdf",
                    "course_page_url": "https://example.edu/1aa3/",
                })
            candidates = load_commerce_manifest(
                path,
                {"COMMERCE 1AA3": {
                    "course_code": "COMMERCE 1AA3",
                    "course_title": "Accounting",
                    "department": "COMMERCE",
                }},
                {"COMMERCE 1AA3"},
                "now",
            )
            self.assertEqual(1, len(candidates))
            self.assertEqual("2026", candidates[0].academic_year)
            self.assertEqual(
                "https://example.edu/1aa3.pdf",
                candidates[0].document_url,
            )


if __name__ == "__main__":
    unittest.main()
