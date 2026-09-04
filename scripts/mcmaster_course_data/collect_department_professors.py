#!/usr/bin/env python3
"""Collect department-level professor candidates from official McMaster pages.

This intentionally models department membership, not a claim that every person
has taught every course. The generated CSV is review input and is never written
to Supabase automatically.

Usage:

    python collect_department_professors.py
    python collect_department_professors.py --skip-engineering
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlparse

from collect_course_resources import clean_text, fetch_text, normalize_name


HERE = Path(__file__).resolve().parent
DEFAULT_OUTPUT = HERE / "generated" / "department_professors.csv"
DEFAULT_CACHE = HERE / "generated" / "department_professors.cache.json"

DIRECTORY_SOURCES = [
    {
        "source_name": "math_faculty",
        "url": "https://math.mcmaster.ca/people/faculty/",
        "department_codes": "MATH; STATS",
        "faculty_only": True,
    },
    {
        "source_name": "biology_faculty",
        "url": "https://biology.mcmaster.ca/people/faculty/",
        "department_codes": "BIOLOGY",
        "faculty_only": True,
    },
    {
        "source_name": "chemistry_full_time_faculty",
        "url": "https://chemistry.mcmaster.ca/people/full-time-faculty/",
        "department_codes": "CHEM; CHEMBIO",
        "faculty_only": True,
    },
    {
        "source_name": "economics_people",
        "url": "https://economics.mcmaster.ca/people/",
        "department_codes": "ECON",
        "faculty_only": False,
    },
    {
        "source_name": "pnb_faculty",
        "url": "https://pnb.mcmaster.ca/people/faculty/",
        "department_codes": "PSYCH; PNB",
        "faculty_only": True,
    },
    {
        "source_name": "physics_current_faculty",
        "url": "https://physics.mcmaster.ca/people/current-faculty/",
        "department_codes": "PHYSICS; ASTRON",
        "faculty_only": True,
    },
    {
        "source_name": "physics_teaching_specialists",
        "url": "https://physics.mcmaster.ca/people/instructors/",
        "department_codes": "PHYSICS; ASTRON",
        "faculty_only": False,
    },
]

DEGROOTE_DIRECTORY = "https://degroote.mcmaster.ca/contact/directory/"
ENGINEERING_DIRECTORY = "https://www.eng.mcmaster.ca/faculty-staff/faculty-directory/"

OUTPUT_FIELDS = [
    "professor_name",
    "role",
    "department_codes",
    "email",
    "profile_url",
    "source_name",
    "active_teaching_candidate",
    "needs_review",
    "retrieved_at",
]

ROLE_PATTERN = re.compile(
    r"\b(?:distinguished\s+university\s+)?(?:assistant\s+|associate\s+|adjunct\s+)?"
    r"(?:professor|instructor|lecturer)\b|\bteaching\s+(?:stream|faculty)\b",
    flags=re.IGNORECASE,
)

INACTIVE_PATTERN = re.compile(
    r"\b(?:emeritus|emerita|retired|former)\b",
    flags=re.IGNORECASE,
)


@dataclass
class ProfessorRecord:
    professor_name: str
    role: str
    department_codes: str
    email: str
    profile_url: str
    source_name: str
    active_teaching_candidate: bool
    needs_review: bool
    retrieved_at: str


def clean_person_name(value: str) -> str:
    value = clean_text(value)
    value = re.sub(
        r"^(?:Dr|Prof|Professor|Mr|Mrs|Ms)\.?\s+",
        "",
        value,
        flags=re.IGNORECASE,
    )
    return value.strip(" ,")


def plausible_person_name(value: str) -> bool:
    words = re.findall(r"[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ.'’()-]*", value)
    if not 2 <= len(words) <= 9:
        return False
    blocked = {
        "people listing",
        "faculty directory",
        "course outlines",
        "contact information",
        "related topics",
    }
    return value.casefold() not in blocked


def extract_role(parts: list[str]) -> str:
    candidates = []
    for part in parts:
        value = clean_text(part)
        if ROLE_PATTERN.search(value) and len(value) <= 180:
            candidates.append(value)
    return min(candidates, key=len) if candidates else ""


class HeadingDirectoryParser(HTMLParser):
    """Read MacSites-style people cards headed by an h3 person name."""

    def __init__(
        self,
        source_name: str,
        source_url: str,
        department_codes: str,
        faculty_only: bool,
        retrieved_at: str,
    ) -> None:
        super().__init__(convert_charrefs=True)
        self.source_name = source_name
        self.source_url = source_url
        self.department_codes = department_codes
        self.faculty_only = faculty_only
        self.retrieved_at = retrieved_at
        self.heading_depth = 0
        self.heading_parts: list[str] = []
        self.current_name = ""
        self.current_parts: list[str] = []
        self.current_emails: list[str] = []
        self.current_profile_url = ""
        self.current_anchor = ""
        self.records: list[ProfessorRecord] = []

    def flush(self) -> None:
        name = clean_person_name(self.current_name)
        role = extract_role(self.current_parts)
        if (
            plausible_person_name(name)
            and (role or self.faculty_only)
            and (role or self.current_emails)
        ):
            if not role:
                role = "Faculty"
            email = self.current_emails[0] if self.current_emails else ""
            self.records.append(ProfessorRecord(
                professor_name=name,
                role=role,
                department_codes=self.department_codes,
                email=email,
                profile_url=self.current_profile_url or self.source_url,
                source_name=self.source_name,
                active_teaching_candidate=not bool(INACTIVE_PATTERN.search(role)),
                needs_review=not bool(self.current_emails),
                retrieved_at=self.retrieved_at,
            ))
        self.current_name = ""
        self.current_parts = []
        self.current_emails = []
        self.current_profile_url = ""

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = dict(attrs)
        classes = set((attributes.get("class") or "").split())
        is_person_heading = tag == "h3" or (
            tag == "h2" and "faculty-card__name" in classes
        )
        if is_person_heading:
            self.flush()
            self.heading_depth = 1
            self.heading_parts = []
        elif self.heading_depth:
            self.heading_depth += 1

        if tag == "a":
            href = clean_text(attributes.get("href"))
            self.current_anchor = href
            if href.casefold().startswith("mailto:"):
                email = href.split(":", 1)[1].split("?", 1)[0].strip()
                if email and email not in self.current_emails:
                    self.current_emails.append(email)
            elif self.current_name and href and not href.startswith("#"):
                self.current_profile_url = urljoin(self.source_url, href)

    def handle_data(self, data: str) -> None:
        value = clean_text(data)
        if not value:
            return
        if self.heading_depth:
            self.heading_parts.append(value)
        elif self.current_name:
            self.current_parts.append(value)

    def handle_endtag(self, tag: str) -> None:
        if self.heading_depth:
            self.heading_depth -= 1
            if self.heading_depth == 0:
                self.current_name = clean_text(" ".join(self.heading_parts))
                self.current_parts = []
                self.current_emails = []
                self.current_profile_url = (
                    urljoin(self.source_url, self.current_anchor)
                    if self.current_anchor
                    else ""
                )
        if tag == "a":
            self.current_anchor = ""

    def close(self) -> None:
        super().close()
        self.flush()


class TableDirectoryParser(HTMLParser):
    """Read directories whose people are represented as HTML table rows."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_row = False
        self.in_cell = False
        self.cell_parts: list[str] = []
        self.row_cells: list[str] = []
        self.row_emails: list[str] = []
        self.rows: list[tuple[list[str], list[str]]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = dict(attrs)
        if tag == "tr":
            self.in_row = True
            self.row_cells = []
            self.row_emails = []
        elif self.in_row and tag in {"td", "th"}:
            self.in_cell = True
            self.cell_parts = []
        elif self.in_row and tag == "a":
            href = clean_text(attributes.get("href"))
            if href.casefold().startswith("mailto:"):
                self.row_emails.append(href.split(":", 1)[1].split("?", 1)[0])

    def handle_data(self, data: str) -> None:
        if self.in_cell:
            value = clean_text(data)
            if value:
                self.cell_parts.append(value)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self.in_cell:
            self.row_cells.append(clean_text(" ".join(self.cell_parts)))
            self.in_cell = False
        elif tag == "tr" and self.in_row:
            self.rows.append((self.row_cells, self.row_emails))
            self.in_row = False


def parse_heading_directory(source: dict, retrieved_at: str) -> list[ProfessorRecord]:
    parser = HeadingDirectoryParser(
        source["source_name"],
        source["url"],
        source["department_codes"],
        source["faculty_only"],
        retrieved_at,
    )
    parser.feed(fetch_text(source["url"]))
    parser.close()
    return parser.records


def parse_degroote(retrieved_at: str) -> list[ProfessorRecord]:
    parser = TableDirectoryParser()
    # DeGroote's edge cache intermittently returns 403 for the bare directory
    # URL. A stable daily query parameter avoids the bad cache entry while the
    # canonical profile/source URL remains unchanged in exported records.
    cache_key = retrieved_at[:10].replace("-", "")
    parser.feed(fetch_text(f"{DEGROOTE_DIRECTORY}?course-data={cache_key}"))
    records = []
    for cells, emails in parser.rows:
        if len(cells) < 3:
            continue
        name = clean_person_name(cells[0])
        role = clean_text(cells[1])
        department = clean_text(cells[2])
        if not plausible_person_name(name) or not ROLE_PATTERN.search(role):
            continue
        records.append(ProfessorRecord(
            professor_name=name,
            role=role,
            department_codes="COMMERCE",
            email=emails[0] if emails else "",
            profile_url=DEGROOTE_DIRECTORY,
            source_name=f"degroote_directory: {department}",
            active_teaching_candidate=not bool(INACTIVE_PATTERN.search(role)),
            needs_review=not bool(emails),
            retrieved_at=retrieved_at,
        ))
    return records


ENGINEERING_DEPARTMENT_PATTERNS = [
    (r"computing\s+(?:and|&)\s+software", "COMPSCI; SFWRENG; MECHTRON"),
    (r"electrical\s+(?:and|&)\s+computer", "ELECENG; COMPENG"),
    (r"chemical\s+engineering", "CHEMENG"),
    (r"civil\s+engineering", "CIVENG"),
    (r"engineering\s+physics", "ENGPHYS"),
    (r"materials\s+science\s+(?:and|&)\s+engineering", "MATLS"),
    (r"mechanical\s+engineering", "MECHENG"),
    (r"biomedical\s+engineering|ibiomed", "IBEHS"),
    (r"booth\s+school|engineering\s+practice\s+(?:and|&)", "ENGTECH"),
]


def engineering_department_codes(record: ProfessorRecord) -> str:
    path = urlparse(record.profile_url).path.casefold()
    path_mappings = [
        ("/cas/", "COMPSCI; SFWRENG; MECHTRON"),
        ("/ece/", "ELECENG; COMPENG"),
        ("/chemeng/", "CHEMENG"),
        ("/civil/", "CIVENG"),
        ("/engphys/", "ENGPHYS"),
        ("/materials/", "MATLS"),
        ("/mech/", "MECHENG"),
        ("/msbe/", "IBEHS"),
        ("/ibiomed/", "IBEHS"),
        ("/sept/", "ENGTECH"),
    ]
    for marker, codes in path_mappings:
        if marker in path:
            return codes

    haystack = f"{record.role} {record.source_name} {record.profile_url}"
    for pattern, codes in ENGINEERING_DEPARTMENT_PATTERNS:
        if re.search(pattern, haystack, flags=re.IGNORECASE):
            return codes
    return "ENGINEER"


def parse_engineering(retrieved_at: str, max_pages: int) -> list[ProfessorRecord]:
    records = []
    seen_page_identities: set[str] = set()
    for page in range(1, max_pages + 1):
        page_url = ENGINEERING_DIRECTORY if page == 1 else f"{ENGINEERING_DIRECTORY}?pg={page}"
        source = {
            "source_name": f"engineering_faculty_directory_page_{page}",
            "url": page_url,
            "department_codes": "ENGINEER",
            "faculty_only": True,
        }
        page_records = parse_heading_directory(source, retrieved_at)
        identities = {
            record.email.casefold() or normalize_name(record.professor_name)
            for record in page_records
        }
        new_identities = identities - seen_page_identities
        if page > 1 and not new_identities:
            break
        seen_page_identities.update(identities)
        for record in page_records:
            # Mac Engineering cards normally include the department in the role
            # line. Keep a conservative umbrella code if the wording changes.
            record.department_codes = engineering_department_codes(record)
            records.append(record)
        print(f"Engineering faculty directory: page {page}, {len(page_records)} candidates")
    return records


def deduplicate(records: list[ProfessorRecord]) -> list[ProfessorRecord]:
    unique: dict[tuple[str, str], ProfessorRecord] = {}
    for record in records:
        identity = record.email.casefold() or normalize_name(record.professor_name)
        key = identity, record.department_codes
        existing = unique.get(key)
        if existing is None:
            unique[key] = record
            continue
        if (not existing.email and record.email) or (
            existing.role == "Faculty" and record.role != "Faculty"
        ):
            unique[key] = record
    return sorted(
        unique.values(),
        key=lambda item: (item.department_codes, item.professor_name.casefold()),
    )


def load_cache(path: Path) -> dict[str, list[ProfessorRecord]]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return {
            source: [ProfessorRecord(**item) for item in items]
            for source, items in payload.items()
        }
    except (OSError, ValueError, TypeError) as error:
        print(f"WARNING: ignoring invalid professor cache {path}: {error}", file=sys.stderr)
        return {}


def save_cache(path: Path, cache: dict[str, list[ProfessorRecord]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        source: [asdict(record) for record in records]
        for source, records in sorted(cache.items())
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def collect_with_cache(
    cache: dict[str, list[ProfessorRecord]],
    cache_key: str,
    collector,
) -> list[ProfessorRecord]:
    try:
        records = collector()
        if not records:
            raise ValueError("source returned no professor records")
        cache[cache_key] = records
        return records
    except Exception as error:
        cached = cache.get(cache_key, [])
        if cached:
            print(
                f"WARNING: {cache_key} failed ({error}); retaining {len(cached)} cached records",
                file=sys.stderr,
            )
            return cached
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--skip-engineering", action="store_true")
    parser.add_argument("--engineering-max-pages", type=int, default=30)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    retrieved_at = datetime.now(timezone.utc).isoformat()
    records = []
    cache = load_cache(args.cache)
    for source in DIRECTORY_SOURCES:
        try:
            source_records = collect_with_cache(
                cache,
                source["source_name"],
                lambda source=source: parse_heading_directory(source, retrieved_at),
            )
            records.extend(source_records)
            print(f"Professor source: {source['source_name']} ({len(source_records)})")
        except Exception as error:
            print(
                f"WARNING: professor source {source['source_name']} failed: {error}",
                file=sys.stderr,
            )

    try:
        degroote_records = collect_with_cache(
            cache,
            "degroote_directory",
            lambda: parse_degroote(retrieved_at),
        )
        records.extend(degroote_records)
        print(f"Professor source: degroote_directory ({len(degroote_records)})")
    except Exception as error:
        print(f"WARNING: degroote_directory failed: {error}", file=sys.stderr)

    if not args.skip_engineering:
        try:
            engineering_records = collect_with_cache(
                cache,
                "engineering_faculty_directory",
                lambda: parse_engineering(retrieved_at, args.engineering_max_pages),
            )
            records.extend(engineering_records)
        except Exception as error:
            print(f"WARNING: engineering directory failed: {error}", file=sys.stderr)

    records = deduplicate(records)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(asdict(record) for record in records)
    save_cache(args.cache, cache)

    active = sum(record.active_teaching_candidate for record in records)
    print()
    print(f"Professor candidates: {len(records)}")
    print(f"Active teaching candidates: {active}")
    print(f"Output: {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
