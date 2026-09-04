#!/usr/bin/env python3
"""Download candidate PDFs temporarily and classify them for publication."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import hashlib
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.request import Request, urlopen

from pypdf import PdfReader


HEADERS = {"User-Agent": "Mozilla/5.0 CheeseApp outline auditor"}
MAX_BYTES = 25 * 1024 * 1024
TERM_PATTERN = r"(fall|winter|spring|summer)"
YEAR_PATTERN = r"(20\d{2})"
HARD_REJECT_PATTERNS = (
    "curriculum proposal",
    "course proposal",
    "course change request",
    "undergraduate council package",
    "project proposal outline",
    "early assessment form",
    "project form permission",
)
DRAFT_PATTERNS = ("for approval", "proposed course")

SUBJECT_ALIASES = {
    "CHEMENG": ("CHEMENG", "CHEM ENG", "CHE", "CHEMICAL ENGINEERING"),
    "CIVENG": ("CIVENG", "CIV ENG", "CE", "CIVIL ENGINEERING"),
    "COMPENG": ("COMPENG", "COMP ENG", "CE", "COMPUTER ENGINEERING"),
    "ELECENG": ("ELECENG", "ELEC ENG", "EE", "ELECTRICAL ENGINEERING"),
    "ENGPHYS": ("ENGPHYS", "ENG PHYS", "ENGINEERING PHYSICS"),
    "GENTECH": ("GENTECH", "SFGNTECH"),
}


@dataclass
class AuditResult:
    course_code: str
    course_title: str
    department: str
    document_url: str
    source_page_url: str
    source_name: str
    audit_status: str
    academic_year: str
    term: str
    course_code_found: bool
    page_count: int
    pdf_sha256: str
    evidence: str
    rejection_reason: str


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def allowed_official_url(value: str) -> bool:
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and (
        host == "mcmaster.ca"
        or host.endswith(".mcmaster.ca")
        or host == "simplesyllabusca.com"
        or host.endswith(".simplesyllabusca.com")
    )


def course_code_pattern(course_code: str) -> re.Pattern[str]:
    subject, number = course_code.split(maxsplit=1)
    aliases = SUBJECT_ALIASES.get(subject, (subject,))
    subject_pattern = "(?:" + "|".join(
        re.escape(alias).replace(r"\ ", r"\s+") for alias in aliases
    ) + ")"
    number_variants = [number]
    if re.fullmatch(r"[0-9][A-Z0-9]*[0-9][AS]", number):
        number_variants.append(number[:-1])
    number_pattern = "(?:" + "|".join(map(re.escape, number_variants)) + ")"
    return re.compile(
        rf"(?<![A-Z0-9]){subject_pattern}\s*[-_/]?\s*{number_pattern}(?![A-Z0-9])",
        re.IGNORECASE,
    )


def infer_term_and_year(filename_text: str, document_text: str) -> tuple[str, str, str]:
    sources = (("filename", filename_text), ("document", document_text[:12000]))
    for source_name, source_text in sources:
        normalized = normalize_text(unquote(source_text)).lower()
        academic_year = re.search(
            rf"academic\s+year\s+{YEAR_PATTERN}(?:[/\-]\d{{2,4}})?"
            rf".{{0,35}}?term\s*:?\s*{TERM_PATTERN}",
            normalized,
        )
        if academic_year:
            return (
                academic_year.group(1),
                academic_year.group(2),
                f"{source_name}: {academic_year.group(0)}",
            )
        forward = re.search(
            rf"{TERM_PATTERN}[^a-z0-9]{{0,35}}{YEAR_PATTERN}", normalized
        )
        if forward:
            return forward.group(2), forward.group(1), f"{source_name}: {forward.group(0)}"
        reverse = re.search(
            rf"{YEAR_PATTERN}[^a-z0-9]{{0,35}}{TERM_PATTERN}", normalized
        )
        if reverse:
            return reverse.group(1), reverse.group(2), f"{source_name}: {reverse.group(0)}"
        shorthand = re.search(r"(?<![a-z0-9])([fw])[-_ ]?(20\d{2})(?!\d)", normalized)
        if shorthand:
            term = "fall" if shorthand.group(1) == "f" else "winter"
            return shorthand.group(2), term, f"{source_name}: {shorthand.group(0)}"
    return "", "", ""


def download_pdf(url: str, output_path: Path) -> bytes:
    request = Request(url, headers=HEADERS)
    with urlopen(request, timeout=45) as response:
        final_url = response.geturl()
        if not allowed_official_url(final_url):
            raise ValueError(f"redirected to unapproved host: {final_url}")
        declared_size = int(response.headers.get("Content-Length") or 0)
        if declared_size > MAX_BYTES:
            raise ValueError(f"PDF exceeds {MAX_BYTES} bytes")
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError(f"PDF exceeds {MAX_BYTES} bytes")
    if not data.startswith(b"%PDF-"):
        raise ValueError("response is not a PDF")
    output_path.write_bytes(data)
    return data


def audit_row(row: dict[str, str], temp_dir: Path) -> AuditResult:
    url = row["document_url"]
    base = dict(
        course_code=row["course_code"],
        course_title=row["course_title"],
        department=row["department"],
        document_url=url,
        source_page_url=row["source_page_url"],
        source_name=row["source_name"],
    )
    if not allowed_official_url(url):
        return AuditResult(
            **base, audit_status="rejected", academic_year="", term="",
            course_code_found=False, page_count=0, pdf_sha256="", evidence="",
            rejection_reason="unapproved URL host",
        )

    temp_path = temp_dir / f"{hashlib.sha256(url.encode()).hexdigest()}.pdf"
    try:
        data = download_pdf(url, temp_path)
        reader = PdfReader(temp_path)
        text = "\n".join(
            page.extract_text() or "" for page in reader.pages[: min(5, len(reader.pages))]
        )
        combined = normalize_text(f"{unquote(url)} {text}")
        lowered = combined.lower()
        word_blob = re.sub(r"[^a-z0-9]+", " ", lowered)
        code_found = bool(course_code_pattern(row["course_code"]).search(combined))
        year, term, term_evidence = infer_term_and_year(unquote(url), text)
        hard_risk = next((item for item in HARD_REJECT_PATTERNS if item in word_blob), "")
        draft_risk = next((item for item in DRAFT_PATTERNS if item in word_blob), "")
        if not draft_risk and re.search(r"\bdraft\b", word_blob):
            draft_risk = "draft"
        outline_marker = bool(re.search(r"\b(course outline|syllabus)\b", word_blob))

        if hard_risk:
            status = "rejected"
            reason = f"non-outline document marker: {hard_risk}"
        elif not code_found:
            status = "manual_review"
            reason = "expected course code not found in filename or first five pages"
        elif not outline_marker:
            status = "manual_review"
            reason = "course outline or syllabus marker not found"
        elif not year or not term:
            status = "manual_review"
            reason = "academic year or term could not be verified"
        elif draft_risk:
            status = "manual_review"
            reason = f"draft marker: {draft_risk}"
        else:
            status = "approved"
            reason = ""

        evidence_parts = [term_evidence] if term_evidence else []
        if code_found:
            evidence_parts.append("matching course code")
        return AuditResult(
            **base,
            audit_status=status,
            academic_year=year,
            term=term,
            course_code_found=code_found,
            page_count=len(reader.pages),
            pdf_sha256=hashlib.sha256(data).hexdigest(),
            evidence="; ".join(evidence_parts),
            rejection_reason=reason,
        )
    except Exception as error:
        return AuditResult(
            **base, audit_status="manual_review", academic_year="", term="",
            course_code_found=False, page_count=0, pdf_sha256="", evidence="",
            rejection_reason=f"{type(error).__name__}: {error}",
        )
    finally:
        temp_path.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--candidates",
        type=Path,
        default=directory / "generated" / "outline_candidates.csv",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=directory / "generated" / "outline_audit_results.csv",
    )
    parser.add_argument(
        "--overrides",
        type=Path,
        default=directory / "generated" / "outline_audit_overrides.csv",
    )
    parser.add_argument(
        "--temp-dir",
        type=Path,
        default=directory.parent.parent / "tmp" / "pdfs" / "outline-audit",
    )
    parser.add_argument("--workers", type=int, default=8)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with args.candidates.open(encoding="utf-8-sig", newline="") as handle:
        candidates = [
            row for row in csv.DictReader(handle)
            if row["is_preferred"] == "True" and row["needs_review"] == "True"
        ]

    args.temp_dir.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda row: audit_row(row, args.temp_dir), candidates))
    results.sort(key=lambda row: row.course_code)

    if args.overrides.exists():
        with args.overrides.open(encoding="utf-8-sig", newline="") as handle:
            overrides = {
                row["course_code"]: row for row in csv.DictReader(handle)
            }
        for result in results:
            override = overrides.get(result.course_code)
            if not override:
                continue
            result.audit_status = override["audit_status"]
            result.academic_year = override["academic_year"]
            result.term = override["term"]
            result.evidence = override["evidence"]
            result.rejection_reason = override["rejection_reason"]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(asdict(results[0])))
        writer.writeheader()
        writer.writerows(asdict(row) for row in results)

    counts: dict[str, int] = {}
    for result in results:
        counts[result.audit_status] = counts.get(result.audit_status, 0) + 1
    print(f"Audited {len(results)} PDFs: {counts}")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
