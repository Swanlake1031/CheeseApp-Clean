import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from collect_department_professors import (
    HeadingDirectoryParser,
    ProfessorRecord,
    TableDirectoryParser,
    clean_person_name,
    collect_with_cache,
    load_cache,
    save_cache,
)


class DepartmentProfessorTests(unittest.TestCase):
    def test_heading_directory_extracts_faculty_and_email(self):
        parser = HeadingDirectoryParser(
            "math", "https://math.example/faculty", "MATH; STATS", True,
            "2026-09-04T00:00:00+00:00",
        )
        parser.feed("""
        <h3>Dr. Ada Lovelace</h3>
        <p>Associate Professor and Undergraduate Chair</p>
        <a href="mailto:ada@mcmaster.ca">ada@mcmaster.ca</a>
        """)
        parser.close()
        self.assertEqual(1, len(parser.records))
        self.assertEqual("Ada Lovelace", parser.records[0].professor_name)
        self.assertEqual("ada@mcmaster.ca", parser.records[0].email)
        self.assertTrue(parser.records[0].active_teaching_candidate)

    def test_engineering_h2_card_keeps_profile_url(self):
        parser = HeadingDirectoryParser(
            "engineering", "https://eng.example/directory/", "ENGINEER", True,
            "2026-09-04T00:00:00+00:00",
        )
        parser.feed("""
        <article><a href="/ece/faculty/ada/">
        <h2 class="faculty-card__name">Dr. Ada Lovelace</h2>
        <div class="faculty-card__role">Assistant Professor</div>
        <div class="faculty-card__department">Electrical &amp; Computer Engineering</div>
        </a></article>
        """)
        parser.close()
        self.assertEqual(1, len(parser.records))
        self.assertEqual(
            "https://eng.example/ece/faculty/ada/",
            parser.records[0].profile_url,
        )

    def test_emeritus_is_retained_but_not_active_candidate(self):
        parser = HeadingDirectoryParser(
            "physics", "https://physics.example/faculty", "PHYSICS", True,
            "2026-09-04T00:00:00+00:00",
        )
        parser.feed("""
        <h3>Grace Hopper</h3><p>Professor Emeritus</p>
        <a href="mailto:grace@mcmaster.ca">email</a>
        """)
        parser.close()
        self.assertFalse(parser.records[0].active_teaching_candidate)

    def test_table_directory_preserves_columns(self):
        parser = TableDirectoryParser()
        parser.feed("""
        <table><tr><td>Dr. Grace Hopper</td><td>Professor</td>
        <td>Faculty, Analytics</td><td><a href="mailto:g@mcmaster.ca">g</a></td>
        </tr></table>
        """)
        self.assertEqual("Professor", parser.rows[0][0][1])
        self.assertEqual(["g@mcmaster.ca"], parser.rows[0][1])

    def test_name_title_is_removed(self):
        self.assertEqual("Grace Hopper", clean_person_name("Prof. Grace Hopper"))

    def test_failed_refresh_retains_cached_records(self):
        record = ProfessorRecord(
            professor_name="Ada Lovelace",
            role="Professor",
            department_codes="COMMERCE",
            email="ada@mcmaster.ca",
            profile_url="https://example.com/ada",
            source_name="degroote_directory",
            active_teaching_candidate=True,
            needs_review=False,
            retrieved_at="2026-09-04T00:00:00+00:00",
        )
        cache = {"degroote_directory": [record]}

        def fail():
            raise RuntimeError("temporary 403")

        self.assertEqual(
            [record],
            collect_with_cache(cache, "degroote_directory", fail),
        )

    def test_cache_round_trip(self):
        record = ProfessorRecord(
            professor_name="Ada Lovelace",
            role="Professor",
            department_codes="MATH",
            email="",
            profile_url="https://example.com/ada",
            source_name="math_faculty",
            active_teaching_candidate=True,
            needs_review=True,
            retrieved_at="2026-09-04T00:00:00+00:00",
        )
        with TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            save_cache(path, {"math_faculty": [record]})
            self.assertEqual(record, load_cache(path)["math_faculty"][0])


if __name__ == "__main__":
    unittest.main()
