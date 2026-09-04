#!/usr/bin/env python3
"""Build a URL-first McMaster course-outline index from official sources.

Selection policy:

1. Prefer a public Simple Syllabus document whenever one exists.
2. Within that source, prefer the newest academic term and retain every
   section in that newest term.
3. Only when Simple Syllabus has no public document for a course, fall back
   to an official McMaster department page or official PDF URL.
4. Never download PDF bodies. The output is metadata and URLs only.

The script writes four CSV files:

* outline_candidates.csv: every discovered official candidate.
* course_outline_index.csv: one row per catalog course with preferred URLs.
* missing_courses.csv: catalog courses without any discovered official URL.
* coverage_by_department.csv: source and coverage totals by department.

Examples:

    python collect_course_resources.py
    python collect_course_resources.py --primary-only
    python collect_course_resources.py --refresh-simple --simple-min-year 2022

All network sources are public McMaster pages. No login, browser profile,
Supabase credential, or local PDF archive is used.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlencode, urljoin, urlparse
from urllib.request import Request, urlopen


HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE / "courses_fall_2026_all.csv"
DEFAULT_SIMPLE_CSV = HERE / "outlines_fall_2026.csv"
DEFAULT_OUTPUT_DIR = HERE / "generated"

SIMPLE_BASE = "https://mcmaster.simplesyllabusca.com"
SIMPLE_TERMS_URL = f"{SIMPLE_BASE}/api2/term"
SIMPLE_SEARCH_URL = f"{SIMPLE_BASE}/api2/doc-library-search"

HEADERS = {
    "Accept": "application/json, text/html;q=0.9, */*;q=0.8",
    "User-Agent": "CheeseApp-McMaster-Official-Resource-Index/0.2",
}

PRIMARY_DEPARTMENTS = {
    "MATH",
    "BIOLOGY",
    "CHEM",
    "COMMERCE",
    "ECON",
    "PSYCH",
    "PHYSICS",
}

# Broad Faculty of Engineering coverage. Keeping this as data makes it easy to
# narrow the product surface later without changing parsing code.
ENGINEERING_DEPARTMENTS = {
    "AUTOTECH",
    "BIOMEDDC",
    "BIOTECH",
    "CHALLENG",
    "CHEMBME",
    "CHEMENG",
    "CIVBME",
    "CIVDEM",
    "CIVENG",
    "CIVTECH",
    "CMTYENGA",
    "COMPENG",
    "COMPSCI",
    "ELECBME",
    "ELECENG",
    "ENGINEER",
    "ENGNMGT",
    "ENGPHYS",
    "ENGSOCTY",
    "ENGTECH",
    "ENRTECH",
    "EPHYSBME",
    "GENTECH",
    "IBEHS",
    "INTENG",
    "MANTECH",
    "MATLS",
    "MATLSBME",
    "MECHBME",
    "MECHENG",
    "MECHTRON",
    "NUCENG",
    "PROCTECH",
    "SFGNTECH",
    "SFWRBME",
    "SFWRENG",
    "SFWRTECH",
    "SMRTTECH",
    "TRONBME",
}

ENGINEERING_COURSE_PAGES = {
    "engineering_chemical": "https://www.eng.mcmaster.ca/chemeng/courses/",
    "engineering_civil": "https://www.eng.mcmaster.ca/civil/courses/",
    "engineering_computing_software": "https://www.eng.mcmaster.ca/cas/courses/",
    "engineering_electrical_computer": "https://www.eng.mcmaster.ca/ece/courses/",
    "engineering_engineering_physics": "https://www.eng.mcmaster.ca/engphys/courses/",
    "engineering_ibiomed": "https://www.eng.mcmaster.ca/ibiomed/courses/",
    "engineering_materials": "https://www.eng.mcmaster.ca/materials/courses/",
    "engineering_mechanical": "https://www.eng.mcmaster.ca/mech/courses/",
    "engineering_technology": "https://www.eng.mcmaster.ca/sept/courses/",
}

SCIENCE_ARCHIVE_PAGES = {
    "math_archive": "https://math.mcmaster.ca/undergraduate/course-outlines/",
    "biology_archive": "https://biology.mcmaster.ca/undergraduate/undergrad-course-outlines/",
    "chemistry_archive": "https://chemistry.mcmaster.ca/undergraduate/course-outlines/",
    "pnb_archive": "https://pnb.mcmaster.ca/undergraduate/course-outlines/",
    "physics_archive": "https://physics.mcmaster.ca/undergraduate-studies/current-students/course-outlines/",
}

TERM_ORDER = {
    "winter": 1,
    "spring": 2,
    "spring/summer": 3,
    "summer": 3,
    "fall": 4,
}

COURSE_FIELDS = ["course_code", "course_title", "department"]
CANDIDATE_FIELDS = [
    "course_code",
    "course_title",
    "department",
    "academic_year",
    "term",
    "section",
    "professor_name",
    "document_url",
    "source_page_url",
    "source_kind",
    "source_name",
    "source_priority",
    "is_preferred",
    "needs_review",
    "retrieved_at",
]


@dataclass
class Candidate:
    course_code: str
    course_title: str
    department: str
    academic_year: str
    term: str
    section: str
    professor_name: str
    document_url: str
    source_page_url: str
    source_kind: str
    source_name: str
    source_priority: int
    is_preferred: bool = False
    needs_review: bool = False
    retrieved_at: str = ""


def clean_text(value: str | None) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def normalize_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def slugify(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-")


def fetch_bytes(url: str, timeout: int = 45, retries: int = 2) -> bytes:
    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            request = Request(url, headers=HEADERS)
            with urlopen(request, timeout=timeout) as response:
                return response.read()
        except HTTPError as error:
            last_error = error
            if error.code == 404:
                raise
            if attempt < retries:
                delay = 4.0 if error.code in {403, 429} else 0.5
                time.sleep(delay * (attempt + 1))
        except (URLError, TimeoutError, OSError) as error:
            last_error = error
            if attempt < retries:
                time.sleep(0.5 * (attempt + 1))
    assert last_error is not None
    raise last_error


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", errors="replace")


def fetch_json(url: str, params: dict | None = None) -> dict:
    if params:
        url = f"{url}?{urlencode(params, doseq=True)}"
    return json.loads(fetch_bytes(url))


def load_catalog(path: Path, include_engineering: bool) -> list[dict[str, str]]:
    departments = set(PRIMARY_DEPARTMENTS)
    if include_engineering:
        departments.update(ENGINEERING_DEPARTMENTS)

    with path.open(newline="", encoding="utf-8-sig") as file:
        rows = list(csv.DictReader(file))

    missing = set(COURSE_FIELDS) - set(rows[0] if rows else {})
    if missing:
        raise ValueError(f"Catalog is missing columns: {', '.join(sorted(missing))}")

    selected = [
        {
            "course_code": clean_text(row["course_code"]).upper(),
            "course_title": clean_text(row["course_title"]),
            "department": clean_text(row["department"]).upper(),
        }
        for row in rows
        if clean_text(row["department"]).upper() in departments
    ]
    return sorted(selected, key=lambda row: row["course_code"])


def extract_simple_course_code(title: str) -> str:
    match = re.match(r"^([A-Z][A-Z0-9]*\s+[0-9][A-Z0-9]*)", title.upper())
    return clean_text(match.group(1)) if match else ""


def extract_simple_section(title: str, course_code: str) -> str:
    remainder = title[len(course_code):].split("_", 1)[0]
    sections = re.findall(r"\b(?:C|T|L)\d{2,3}\b", remainder.upper())
    return "; ".join(dict.fromkeys(sections))


def simple_editor_name(item: dict) -> str:
    marker = ""
    title = clean_text(item.get("title"))
    if "_" in title:
        marker = normalize_name(title.rsplit("_", 1)[1])

    for editor in item.get("editors", []):
        last_name = normalize_name(editor.get("last_name", ""))
        if len(last_name) >= 4 and marker.startswith(last_name):
            return clean_text(editor.get("full_name"))
    return ""


def parse_term_name(value: str) -> tuple[str, str]:
    match = re.search(
        r"\b(Fall|Winter|Spring/Summer|Spring|Summer)\s+(20\d{2})\b",
        value,
        flags=re.IGNORECASE,
    )
    if not match:
        return "", ""
    return match.group(2), match.group(1).lower()


def term_key(year: str, term: str) -> tuple[int, int]:
    numeric_year = int(year) if year.isdigit() else 0
    return numeric_year, TERM_ORDER.get(term.casefold(), 0)


def simple_record_from_item(
    item: dict,
    catalog_by_code: dict[str, dict[str, str]],
    retrieved_at: str,
) -> Candidate | None:
    if item.get("visibility") != "general_public":
        return None

    title = clean_text(item.get("title"))
    code = extract_simple_course_code(title)
    catalog = catalog_by_code.get(code)
    if not catalog:
        return None

    document_id = clean_text(item.get("code"))
    term_name = clean_text(item.get("term_name"))
    year, term = parse_term_name(term_name)
    slug = quote(
        slugify(" ".join([term_name, title, clean_text(item.get("sub_title"))])),
        safe="-",
    )
    return Candidate(
        course_code=code,
        course_title=catalog["course_title"],
        department=catalog["department"],
        academic_year=year,
        term=term,
        section=extract_simple_section(title, code),
        professor_name=simple_editor_name(item),
        document_url=f"{SIMPLE_BASE}/doc/{document_id}/{slug}?mode=view",
        source_page_url=SIMPLE_SEARCH_URL,
        source_kind="simple_syllabus",
        source_name="McMaster Simple Syllabus",
        source_priority=1,
        retrieved_at=retrieved_at,
    )


def load_simple_csv(
    path: Path,
    catalog_by_code: dict[str, dict[str, str]],
    retrieved_at: str,
) -> list[Candidate]:
    if not path.exists():
        return []

    candidates = []
    with path.open(newline="", encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            code = clean_text(row.get("course_code")).upper()
            catalog = catalog_by_code.get(code)
            if not catalog:
                continue
            year, term = parse_term_name(path.stem.replace("_", " "))
            candidates.append(Candidate(
                course_code=code,
                course_title=catalog["course_title"],
                department=catalog["department"],
                academic_year=year,
                term=term,
                section="",
                professor_name=clean_text(row.get("professor_name")),
                document_url=clean_text(row.get("url")),
                source_page_url=SIMPLE_SEARCH_URL,
                source_kind="simple_syllabus",
                source_name="McMaster Simple Syllabus",
                source_priority=1,
                retrieved_at=retrieved_at,
            ))
    return candidates


def fetch_all_simple_candidates(
    catalog_by_code: dict[str, dict[str, str]],
    minimum_year: int,
    retrieved_at: str,
) -> list[Candidate]:
    term_data = fetch_json(SIMPLE_TERMS_URL)
    terms = []
    for item in term_data.get("items", []):
        year, term = parse_term_name(clean_text(item.get("name")))
        if (
            item.get("is_published") is True
            and year
            and int(year) >= minimum_year
            and term
        ):
            terms.append(item)

    terms.sort(
        key=lambda item: item.get("start_date", ""),
        reverse=True,
    )

    candidates = []
    for term_index, term_item in enumerate(terms, start=1):
        term_id = term_item["entity_id"]
        term_name = clean_text(term_item.get("name"))
        page = 0
        while True:
            data = fetch_json(
                SIMPLE_SEARCH_URL,
                {"term_ids[]": term_id, "page": page},
            )
            pagination = data.get("pagination", {})
            for item in data.get("items", []):
                candidate = simple_record_from_item(
                    item,
                    catalog_by_code,
                    retrieved_at,
                )
                if candidate:
                    candidates.append(candidate)

            returned = int(pagination.get("returned", 0))
            page_size = int(pagination.get("page_size", 50))
            total = int(pagination.get("total", 0))
            if returned == 0 or (page + 1) * page_size >= total:
                break
            page += 1
        print(
            f"Simple Syllabus: {term_index}/{len(terms)} {term_name} "
            f"({len(candidates)} target candidates so far)"
        )
    return candidates


class LinkCollector(HTMLParser):
    """Collect links and the visible text immediately preceding each link."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.text_parts: list[str] = []
        self.links: list[dict[str, str]] = []
        self.current_link: dict[str, str] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag != "a":
            return
        attributes = dict(attrs)
        self.current_link = {
            "href": attributes.get("href", ""),
            "aria_label": attributes.get("aria-label", ""),
            "text": "",
            "context": clean_text(" ".join(self.text_parts[-80:])),
        }

    def handle_data(self, data: str) -> None:
        value = clean_text(data)
        if not value:
            return
        self.text_parts.append(value)
        if self.current_link is not None:
            self.current_link["text"] = clean_text(
                f"{self.current_link['text']} {value}"
            )

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.current_link is not None:
            self.links.append(self.current_link)
            self.current_link = None


def normalize_subject_spacing(value: str) -> str:
    replacements = {
        "CHEM ENG": "CHEMENG",
        "COMP SCI": "COMPSCI",
        "ELEC ENG": "ELECENG",
        "ENG PHYS": "ENGPHYS",
        "MECH ENG": "MECHENG",
        "SFWR ENG": "SFWRENG",
    }
    normalized = value.upper().replace("&NBSP;", " ")
    for old, new in replacements.items():
        normalized = normalized.replace(old, new)
    return normalized


def find_catalog_codes(text: str, catalog_codes: set[str]) -> list[str]:
    normalized = normalize_subject_spacing(text)
    found = []
    pattern = re.compile(r"\b([A-Z][A-Z0-9]{1,11})\s+([0-9][A-Z0-9]{2,7})\b")
    for subject, number in pattern.findall(normalized):
        code = f"{subject} {number}"
        if code in catalog_codes and code not in found:
            found.append(code)
    compact = re.sub(r"[^A-Z0-9]", "", normalized)
    compact_hits = []
    for code in catalog_codes:
        compact_code = re.sub(r"[^A-Z0-9]", "", code)
        position = compact.find(compact_code)
        if position >= 0:
            compact_hits.append((position, code))
    for _, code in sorted(compact_hits):
        if code not in found:
            found.append(code)
    return found


def infer_term(text: str, url: str) -> tuple[str, str, bool]:
    combined = clean_text(f"{text} {url}")
    year, term = parse_term_name(combined)
    if year:
        return year, term, False

    annual = re.search(r"(20\d{2})\s*[-_/]\s*(?:20)?(\d{2})", combined)
    term_number = re.search(r"\bTERM\s*([12])\b", combined, flags=re.IGNORECASE)
    if annual and term_number:
        start_year = int(annual.group(1))
        if term_number.group(1) == "1":
            return str(start_year), "fall", False
        return str(start_year + 1), "winter", False

    return "", "", True


def document_code_conflicts(course_code: str, document_url: str) -> bool:
    """Return true when a PDF filename names another course, not the card's course.

    Official course cards occasionally contain a stale or shifted outline link.
    Cross-listed filenames remain valid because this compares the course number
    independently of its subject prefix (for example, MECHENG 4BB3 may be named
    `ME-4BB3` in a shared IBEHS document).
    """
    target_number = course_code.split()[-1].upper()
    filename = unquote(Path(urlparse(document_url).path).name).upper()
    filename_tokens = re.sub(r"[^A-Z0-9]", " ", filename).split()
    acceptable_numbers = {target_number}
    if target_number.endswith(("A", "S")) and target_number[-2].isdigit():
        # Full-year/placement catalog suffixes are often omitted from the
        # shared outline filename (4Y04A -> 4Y04).
        acceptable_numbers.add(target_number[:-1])
    if acceptable_numbers.intersection(filename_tokens):
        return False

    course_like_numbers = set(re.findall(
        r"(?<![A-Z0-9])([1-7][A-Z]{1,5}[0-9][A-Z0-9]?)(?![A-Z0-9])",
        filename,
    ))
    return bool(course_like_numbers)


class EngineeringCourseParser(HTMLParser):
    """Parse one official Engineering course-listing card at a time."""

    VOID_TAGS = {
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.card_depth: int | None = None
        self.card_text: list[str] = []
        self.card_links: list[str] = []
        self.cards: list[tuple[str, list[str]]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag not in self.VOID_TAGS:
            self.depth += 1
        attributes = dict(attrs)
        classes = set((attributes.get("class") or "").split())
        if (
            tag == "li"
            and "course-listing__course" in classes
            and self.card_depth is None
        ):
            self.card_depth = self.depth
            self.card_text = []
            self.card_links = []

        if self.card_depth is not None and tag == "a":
            href = clean_text(attributes.get("href"))
            if href:
                self.card_links.append(href)

    def handle_data(self, data: str) -> None:
        if self.card_depth is not None:
            value = clean_text(data)
            if value:
                self.card_text.append(value)

    def handle_endtag(self, tag: str) -> None:
        if tag == "li" and self.card_depth == self.depth:
            self.cards.append((clean_text(" ".join(self.card_text)), self.card_links))
            self.card_depth = None
            self.card_text = []
            self.card_links = []
        if tag not in self.VOID_TAGS:
            self.depth = max(0, self.depth - 1)


def extract_instructors(card_text: str) -> str:
    matches = re.findall(
        r"(?:Sessional\s+)?Instructor\s+(.+?)(?=(?:Sessional\s+)?Instructor|Download the Outline|$)",
        card_text,
        flags=re.IGNORECASE,
    )
    names = []
    for value in matches:
        name = clean_text(value)
        name = re.split(
            r"\b(?:TERM|Prerequisite|Antirequisite)\b",
            name,
            maxsplit=1,
            flags=re.IGNORECASE,
        )[0]
        name = re.sub(r"^(?:Dr|Prof|Professor)\.?\s+", "", name, flags=re.IGNORECASE)
        if 2 <= len(name.split()) <= 8 and name not in names:
            names.append(name)
    return "; ".join(names)


def scrape_engineering_pages(
    catalog_by_code: dict[str, dict[str, str]],
    missing_simple: set[str],
    retrieved_at: str,
) -> list[Candidate]:
    catalog_codes = set(catalog_by_code)
    candidates = []
    for source_name, page_url in ENGINEERING_COURSE_PAGES.items():
        try:
            parser = EngineeringCourseParser()
            parser.feed(fetch_text(page_url))
        except Exception as error:
            print(f"WARNING: {source_name} failed: {error}", file=sys.stderr)
            continue

        page_count = 0
        for card_text, links in parser.cards:
            codes = find_catalog_codes(card_text, catalog_codes)
            if not codes:
                continue
            # The card heading is the first course code in the card. Later codes
            # can be prerequisites or cross-list references.
            code = codes[0]
            if code not in missing_simple:
                continue
            catalog = catalog_by_code[code]
            professor = extract_instructors(card_text)
            for href in links:
                document_url = urljoin(page_url, href)
                if ".pdf" not in urlparse(document_url).path.casefold():
                    continue
                if document_code_conflicts(code, document_url):
                    print(
                        f"WARNING: skipped mismatched outline on {source_name}: "
                        f"{code} -> {document_url}",
                        file=sys.stderr,
                    )
                    continue
                year, term, needs_review = infer_term(card_text, document_url)
                candidates.append(Candidate(
                    course_code=code,
                    course_title=catalog["course_title"],
                    department=catalog["department"],
                    academic_year=year,
                    term=term,
                    section="",
                    professor_name=professor,
                    document_url=document_url,
                    source_page_url=page_url,
                    source_kind="official_department",
                    source_name=source_name,
                    source_priority=2,
                    needs_review=needs_review,
                    retrieved_at=retrieved_at,
                ))
                page_count += 1
        print(f"Official source: {source_name} ({page_count} target URLs)")
    return candidates


def scrape_cas_macdrive(
    catalog_by_code: dict[str, dict[str, str]],
    missing_simple: set[str],
    retrieved_at: str,
) -> list[Candidate]:
    """Index public CAS MacDrive folders without downloading their PDFs."""
    listing_url = "https://www.cas.mcmaster.ca/course_permission/courses.php"
    try:
        parser = LinkCollector()
        parser.feed(fetch_text(listing_url))
    except Exception as error:
        print(f"WARNING: CAS course listing failed: {error}", file=sys.stderr)
        return []

    catalog_codes = set(catalog_by_code)
    candidates = []
    seen_tokens = set()
    for link in parser.links:
        folder_url = urljoin(listing_url, link["href"])
        token_match = re.search(r"macdrive\.mcmaster\.ca/d/([A-Za-z0-9]+)/?", folder_url)
        if not token_match:
            continue
        token = token_match.group(1)
        if token in seen_tokens:
            continue
        seen_tokens.add(token)

        term_text = clean_text(f"{link['text']} {link['context']}")
        year, term = parse_term_name(term_text)
        api_url = (
            "https://macdrive.mcmaster.ca/api/v2.1/share-links/"
            f"{token}/dirents/"
        )
        try:
            data = fetch_json(api_url, {"path": "/", "thumbnail_size": 48})
        except Exception as error:
            print(f"WARNING: CAS MacDrive {token} failed: {error}", file=sys.stderr)
            continue

        folder_count = 0
        for item in data.get("dirent_list", []):
            file_path = clean_text(item.get("file_path"))
            file_name = clean_text(item.get("file_name"))
            if item.get("is_dir") or not file_name.casefold().endswith(".pdf"):
                continue
            codes = find_catalog_codes(file_name, catalog_codes)
            for code in codes:
                if code not in missing_simple:
                    continue
                catalog = catalog_by_code[code]
                document_url = (
                    f"https://macdrive.mcmaster.ca/d/{token}/files/?"
                    + urlencode({"p": file_path, "dl": "1"})
                )
                candidates.append(Candidate(
                    course_code=code,
                    course_title=catalog["course_title"],
                    department=catalog["department"],
                    academic_year=year,
                    term=term,
                    section="",
                    professor_name="",
                    document_url=document_url,
                    source_page_url=folder_url,
                    source_kind="official_department",
                    source_name="cas_macdrive",
                    source_priority=2,
                    needs_review=not bool(year and term),
                    retrieved_at=retrieved_at,
                ))
                folder_count += 1
        print(
            f"Official source: cas_macdrive {year} {term} "
            f"({folder_count} target URL mappings)"
        )
    return candidates


class CommerceTableParser(HTMLParser):
    """Parse DeGroote's explicit term/course/section/instructor tables."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.in_h4 = False
        self.h4_parts: list[str] = []
        self.current_term = ""
        self.in_row = False
        self.in_cell = False
        self.cell_parts: list[str] = []
        self.row_cells: list[str] = []
        self.row_links: list[str] = []
        self.rows: list[tuple[str, list[str], list[str]]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = dict(attrs)
        if tag == "h4":
            self.in_h4 = True
            self.h4_parts = []
        elif tag == "tr":
            self.in_row = True
            self.row_cells = []
            self.row_links = []
        elif self.in_row and tag in {"td", "th"}:
            self.in_cell = True
            self.cell_parts = []
        elif self.in_row and tag == "a":
            href = clean_text(attributes.get("href"))
            if href:
                self.row_links.append(href)

    def handle_data(self, data: str) -> None:
        value = clean_text(data)
        if not value:
            return
        if self.in_h4:
            self.h4_parts.append(value)
        if self.in_cell:
            self.cell_parts.append(value)

    def handle_endtag(self, tag: str) -> None:
        if tag == "h4" and self.in_h4:
            heading = clean_text(" ".join(self.h4_parts))
            if parse_term_name(heading)[0]:
                self.current_term = heading
            self.in_h4 = False
        elif tag in {"td", "th"} and self.in_cell:
            self.row_cells.append(clean_text(" ".join(self.cell_parts)))
            self.in_cell = False
        elif tag == "tr" and self.in_row:
            self.rows.append((self.current_term, self.row_cells, self.row_links))
            self.in_row = False


def discover_commerce_pages(html: str, catalog_codes: set[str]) -> dict[str, str]:
    parser = LinkCollector()
    parser.feed(html)
    by_number = {code.split()[1].casefold(): code for code in catalog_codes if code.startswith("COMMERCE ")}
    pages = {}
    for link in parser.links:
        href = urljoin("https://ug.degroote.mcmaster.ca/", link["href"])
        if "/descriptions/" not in href:
            continue
        slug = urlparse(href).path.rstrip("/").rsplit("/", 1)[-1].casefold()
        code = by_number.get(slug)
        if not code:
            context_codes = find_catalog_codes(link["context"], catalog_codes)
            code = context_codes[-1] if context_codes else ""
        if code:
            pages[code] = href
    return pages


def scrape_commerce(
    catalog_by_code: dict[str, dict[str, str]],
    missing_simple: set[str],
    retrieved_at: str,
) -> list[Candidate]:
    start_url = "https://ug.degroote.mcmaster.ca/registration/commerce-courses/"
    commerce_codes = {
        code for code in catalog_by_code
        if code.startswith("COMMERCE ") and code in missing_simple
    }
    if not commerce_codes:
        return []

    try:
        page_map = discover_commerce_pages(fetch_text(start_url), commerce_codes)
    except Exception as error:
        print(f"WARNING: commerce index failed: {error}", file=sys.stderr)
        return []

    candidates = []
    for index, code in enumerate(sorted(commerce_codes), start=1):
        page_url = page_map.get(code)
        if not page_url:
            page_url = (
                "https://ug.degroote.mcmaster.ca/descriptions/"
                f"{code.split()[1].casefold()}/"
            )
        try:
            parser = CommerceTableParser()
            parser.feed(fetch_text(page_url))
        except Exception as error:
            print(f"WARNING: {code} failed: {error}", file=sys.stderr)
            continue

        catalog = catalog_by_code[code]
        for term_name, cells, links in parser.rows:
            pdf_links = [
                urljoin(page_url, link)
                for link in links
                if ".pdf" in urlparse(link).path.casefold()
            ]
            if not pdf_links or not cells:
                continue
            row_number = re.sub(r"[^A-Z0-9]", "", cells[0].upper())
            if row_number and row_number != code.split()[1]:
                continue
            year, term = parse_term_name(term_name)
            section = cells[1] if len(cells) >= 2 else ""
            professor = cells[2] if len(cells) >= 3 else ""
            for document_url in pdf_links:
                candidates.append(Candidate(
                    course_code=code,
                    course_title=catalog["course_title"],
                    department=catalog["department"],
                    academic_year=year,
                    term=term,
                    section=section,
                    professor_name=professor,
                    document_url=document_url,
                    source_page_url=page_url,
                    source_kind="official_department",
                    source_name="degroote_commerce",
                    source_priority=2,
                    needs_review=not bool(year and term),
                    retrieved_at=retrieved_at,
                ))
        if index % 10 == 0 or index == len(commerce_codes):
            print(f"DeGroote: {index}/{len(commerce_codes)} course pages")
        # DeGroote throttles bursts of otherwise valid public requests.
        time.sleep(1.0)
    return candidates


def load_commerce_manifest(
    path: Path | None,
    catalog_by_code: dict[str, dict[str, str]],
    missing_simple: set[str],
    retrieved_at: str,
) -> list[Candidate]:
    """Reuse URL metadata from an earlier official DeGroote crawl."""
    if path is None or not path.exists():
        return []

    candidates = []
    with path.open(newline="", encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            raw_code = clean_text(row.get("course_code")).upper()
            code = (
                raw_code
                if raw_code.startswith("COMMERCE ")
                else f"COMMERCE {raw_code}"
            )
            catalog = catalog_by_code.get(code)
            document_url = clean_text(
                row.get("pdf_url") or row.get("document_url")
            )
            if not catalog or code not in missing_simple or not document_url:
                continue
            year, term = parse_term_name(clean_text(row.get("term")))
            candidates.append(Candidate(
                course_code=code,
                course_title=catalog["course_title"],
                department=catalog["department"],
                academic_year=year,
                term=term,
                section=clean_text(row.get("section")),
                professor_name=clean_text(
                    row.get("instructor") or row.get("professor_name")
                ),
                document_url=document_url,
                source_page_url=clean_text(row.get("course_page_url")),
                source_kind="official_department",
                source_name="degroote_commerce",
                source_priority=2,
                needs_review=not bool(year and term),
                retrieved_at=retrieved_at,
            ))
    return candidates


def scrape_generic_archives(
    catalog_by_code: dict[str, dict[str, str]],
    missing_after_structured: set[str],
    retrieved_at: str,
) -> list[Candidate]:
    catalog_codes = set(catalog_by_code)
    candidates = []
    for source_name, page_url in SCIENCE_ARCHIVE_PAGES.items():
        try:
            parser = LinkCollector()
            parser.feed(fetch_text(page_url))
        except Exception as error:
            print(f"WARNING: {source_name} failed: {error}", file=sys.stderr)
            continue

        count = 0
        for link in parser.links:
            document_url = urljoin(page_url, link["href"])
            if ".pdf" not in urlparse(document_url).path.casefold():
                continue
            context = clean_text(f"{link['context']} {link['text']} {link['aria_label']}")
            codes = find_catalog_codes(context, catalog_codes)
            if not codes:
                codes = find_catalog_codes(document_url, catalog_codes)
            if not codes:
                continue
            code = codes[-1]
            if code not in missing_after_structured:
                continue
            catalog = catalog_by_code[code]
            year, term, needs_review = infer_term(context, document_url)
            candidates.append(Candidate(
                course_code=code,
                course_title=catalog["course_title"],
                department=catalog["department"],
                academic_year=year,
                term=term,
                section="",
                professor_name="",
                document_url=document_url,
                source_page_url=page_url,
                source_kind="official_department",
                source_name=source_name,
                source_priority=2,
                needs_review=True if needs_review else True,
                retrieved_at=retrieved_at,
            ))
            count += 1
        print(f"Official archive: {source_name} ({count} review-required URLs)")
    return candidates


def deduplicate_candidates(candidates: list[Candidate]) -> list[Candidate]:
    unique = {}
    for candidate in candidates:
        if not candidate.document_url:
            continue
        key = (
            candidate.course_code,
            candidate.document_url,
            candidate.section.casefold(),
        )
        existing = unique.get(key)
        if existing is None or term_key(
            candidate.academic_year,
            candidate.term,
        ) > term_key(existing.academic_year, existing.term):
            unique[key] = candidate
    return list(unique.values())


def mark_preferred(candidates: list[Candidate]) -> None:
    by_course: dict[str, list[Candidate]] = defaultdict(list)
    for candidate in candidates:
        by_course[candidate.course_code].append(candidate)

    for course_candidates in by_course.values():
        best_priority = min(item.source_priority for item in course_candidates)
        source_candidates = [
            item for item in course_candidates
            if item.source_priority == best_priority
        ]
        newest_term = max(
            (term_key(item.academic_year, item.term) for item in source_candidates),
            default=(0, 0),
        )
        newest_candidates = [
            item for item in source_candidates
            if term_key(item.academic_year, item.term) == newest_term
        ]
        if newest_term == (0, 0):
            newest_candidates = source_candidates[:1]
        for item in newest_candidates:
            item.is_preferred = True


def write_outputs(
    output_dir: Path,
    catalog: list[dict[str, str]],
    candidates: list[Candidate],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    candidates.sort(key=lambda item: (
        item.course_code,
        item.source_priority,
        -term_key(item.academic_year, item.term)[0],
        -term_key(item.academic_year, item.term)[1],
        item.section,
        item.document_url,
    ))

    with (output_dir / "outline_candidates.csv").open(
        "w", newline="", encoding="utf-8-sig"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=CANDIDATE_FIELDS)
        writer.writeheader()
        writer.writerows(asdict(item) for item in candidates)

    preferred_by_course: dict[str, list[Candidate]] = defaultdict(list)
    for candidate in candidates:
        if candidate.is_preferred:
            preferred_by_course[candidate.course_code].append(candidate)

    index_fields = COURSE_FIELDS + [
        "outline_status",
        "preferred_source_kind",
        "preferred_source_name",
        "preferred_academic_year",
        "preferred_term",
        "preferred_professors",
        "preferred_document_urls",
        "preferred_source_page_url",
        "needs_review",
    ]
    index_rows = []
    missing_rows = []
    for course in catalog:
        preferred = preferred_by_course.get(course["course_code"], [])
        if not preferred:
            missing_rows.append(course)
            index_rows.append({
                **course,
                "outline_status": "missing",
                "preferred_source_kind": "",
                "preferred_source_name": "",
                "preferred_academic_year": "",
                "preferred_term": "",
                "preferred_professors": "",
                "preferred_document_urls": "",
                "preferred_source_page_url": "",
                "needs_review": False,
            })
            continue

        first = preferred[0]
        professors = sorted({
            item.professor_name for item in preferred if item.professor_name
        })
        urls = list(dict.fromkeys(item.document_url for item in preferred))
        index_rows.append({
            **course,
            "outline_status": "found",
            "preferred_source_kind": first.source_kind,
            "preferred_source_name": first.source_name,
            "preferred_academic_year": first.academic_year,
            "preferred_term": first.term,
            "preferred_professors": "; ".join(professors),
            "preferred_document_urls": " | ".join(urls),
            "preferred_source_page_url": first.source_page_url,
            "needs_review": any(item.needs_review for item in preferred),
        })

    with (output_dir / "course_outline_index.csv").open(
        "w", newline="", encoding="utf-8-sig"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=index_fields)
        writer.writeheader()
        writer.writerows(index_rows)

    with (output_dir / "missing_courses.csv").open(
        "w", newline="", encoding="utf-8-sig"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=COURSE_FIELDS)
        writer.writeheader()
        writer.writerows(missing_rows)

    coverage_fields = [
        "department",
        "catalog_courses",
        "courses_with_preferred_url",
        "simple_syllabus_courses",
        "official_fallback_courses",
        "missing_courses",
        "coverage_percent",
    ]
    course_counts = Counter(row["department"] for row in catalog)
    source_counts: dict[str, Counter] = defaultdict(Counter)
    for code, items in preferred_by_course.items():
        department = items[0].department
        source_counts[department]["found"] += 1
        source_counts[department][items[0].source_kind] += 1

    coverage_rows = []
    for department, total in sorted(course_counts.items()):
        found = source_counts[department]["found"]
        coverage_rows.append({
            "department": department,
            "catalog_courses": total,
            "courses_with_preferred_url": found,
            "simple_syllabus_courses": source_counts[department]["simple_syllabus"],
            "official_fallback_courses": source_counts[department]["official_department"],
            "missing_courses": total - found,
            "coverage_percent": f"{100 * found / total:.1f}",
        })

    with (output_dir / "coverage_by_department.csv").open(
        "w", newline="", encoding="utf-8-sig"
    ) as file:
        writer = csv.DictWriter(file, fieldnames=coverage_fields)
        writer.writeheader()
        writer.writerows(coverage_rows)

    print()
    print(f"Catalog courses: {len(catalog)}")
    print(f"Courses with preferred URL: {len(preferred_by_course)}")
    print(f"Missing courses: {len(missing_rows)}")
    print(f"All candidates: {len(candidates)}")
    print(f"Output: {output_dir.resolve()}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--simple-csv", type=Path, default=DEFAULT_SIMPLE_CSV)
    parser.add_argument(
        "--commerce-manifest",
        type=Path,
        help="Optional URL-only CSV created by an earlier DeGroote crawl.",
    )
    parser.add_argument("--refresh-simple", action="store_true")
    parser.add_argument("--simple-min-year", type=int, default=2022)
    parser.add_argument("--primary-only", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    retrieved_at = datetime.now(timezone.utc).isoformat()
    try:
        catalog = load_catalog(args.catalog, not args.primary_only)
        catalog_by_code = {row["course_code"]: row for row in catalog}

        if args.refresh_simple:
            simple_candidates = fetch_all_simple_candidates(
                catalog_by_code,
                args.simple_min_year,
                retrieved_at,
            )
        else:
            simple_candidates = load_simple_csv(
                args.simple_csv,
                catalog_by_code,
                retrieved_at,
            )
        simple_codes = {item.course_code for item in simple_candidates}
        missing_simple = set(catalog_by_code) - simple_codes
        print(f"Simple Syllabus matched courses: {len(simple_codes)}")

        commerce_manifest_candidates = load_commerce_manifest(
            args.commerce_manifest,
            catalog_by_code,
            missing_simple,
            retrieved_at,
        )
        manifest_codes = {
            item.course_code for item in commerce_manifest_candidates
        }
        if commerce_manifest_candidates:
            print(
                "Existing DeGroote manifest: "
                f"{len(manifest_codes)} courses, "
                f"{len(commerce_manifest_candidates)} URL rows"
            )

        commerce_candidates = scrape_commerce(
            catalog_by_code,
            missing_simple - manifest_codes,
            retrieved_at,
        )
        engineering_candidates = []
        cas_macdrive_candidates = []
        if not args.primary_only:
            engineering_candidates = scrape_engineering_pages(
                catalog_by_code,
                missing_simple,
                retrieved_at,
            )
            cas_macdrive_candidates = scrape_cas_macdrive(
                catalog_by_code,
                missing_simple,
                retrieved_at,
            )

        structured_codes = {
            item.course_code
            for item in (
                commerce_manifest_candidates
                + commerce_candidates
                + engineering_candidates
                + cas_macdrive_candidates
            )
        }
        generic_candidates = scrape_generic_archives(
            catalog_by_code,
            missing_simple - structured_codes,
            retrieved_at,
        )

        candidates = deduplicate_candidates(
            simple_candidates
            + commerce_manifest_candidates
            + commerce_candidates
            + engineering_candidates
            + cas_macdrive_candidates
            + generic_candidates
        )
        mark_preferred(candidates)
        write_outputs(args.output_dir, catalog, candidates)
        return 0
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
