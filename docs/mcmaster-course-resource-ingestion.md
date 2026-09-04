# McMaster course outlines and professor coverage

Status: complete undergraduate catalog plus reviewed URL-backed outline imports.
Migrations 191 through 193 define and populate the external-link model;
migration 194 publishes the complete catalog. The collectors themselves never
write to production.

## Collection policy

For every course in the checked MyTimetable catalog:

1. Select the newest public Simple Syllabus term, retaining every section in
   that term.
2. Only when Simple Syllabus has no result, select an official McMaster
   department course page, PDF, or public MacDrive document URL.
3. Keep unresolved courses in an explicit missing report. Never manufacture a
   URL or silently map a similar-looking course code.

Course-code aliases require manual confirmation. For example, `COMMERCE 1E03`
and the older app code `COMMERCE 1EO3`, or `1GR0A` and `1GR0`, must not be
merged solely because they look similar.

## September 4, 2026 collection snapshot

The seven priority subjects have 138 of 228 catalog courses with a preferred
official URL (60.5%):

| Subject | Covered | Catalog | Coverage |
| --- | ---: | ---: | ---: |
| MATH | 32 | 42 | 76.2% |
| BIOLOGY | 19 | 34 | 55.9% |
| CHEM | 15 | 22 | 68.2% |
| COMMERCE | 46 | 62 | 74.2% |
| ECON | 6 | 29 | 20.7% |
| PSYCH | 10 | 21 | 47.6% |
| PHYSICS | 10 | 18 | 55.6% |

Across the broad Engineering/Engineering Technology subject set, 255 of 349
catalog courses have a preferred official URL (73.1%). Links whose PDF filename
clearly names a different course are excluded from automatic selection. The remaining report is
the queue for source-specific adapters; it is not interpreted as proof that no
outline exists.

The production import contains 393 URLs covering 381 courses: 115 Simple
Syllabus pages and 278 direct official PDFs. All links passed an official-host
and online availability check. For the 164 candidates originally marked
`needs_review=true`, the audit downloaded each PDF temporarily, checked its
content, and rendered uncertain first pages for visual review. That produced
152 approvals, seven rejections, and five unresolved rows. The temporary PDFs
and page renders were deleted after review.

The current published URL coverage is 381 courses. Migration 194 decouples
course availability from outline availability and publishes all 1,604 Fall 2026
undergraduate courses across 127 subjects. Therefore the remaining courses are
still searchable and reviewable even though their outline section is empty.

## URL-first database model

Do not copy every public PDF into Supabase Storage. Keep the official URL as the
canonical source, and reserve Storage for documents that the university does
not expose through a stable public URL or that the product is permitted to
archive.

The existing `course_outlines` table requires `storage_path`, byte size, and
SHA-256 metadata. Released app versions decode those fields as non-null, so
migration 191 deliberately leaves that contract untouched and adds a separate
`course_external_outlines` table:

```text
course_external_outlines
  id
  course_id
  academic_year
  term
  professor_name
  title
  source_kind          external_pdf | external_web
  source_url
  source_page_url      nullable
  source_name
  mime_type
  retrieved_at
  last_verified_at
  created_at
```

Only authenticated users may select this metadata, and database checks restrict
links to HTTPS McMaster or Simple Syllabus hosts. New clients merge these rows
with private `course_outlines`: direct PDFs are downloaded into an ephemeral
in-memory session for PDFKit, while Simple Syllabus documents open inside an
`SFSafariViewController`. Nothing from an external URL is persisted in the app
cache or copied into Supabase Storage.

Migration 191 first introduced 10 current Commerce/ECON links, four catalog
courses, and six verified course/instructor relationships. Migration 192
upserted the first 241 reviewed links, and migration 193 added the 152 links
approved by the content and visual audit. `COMMERCE 4EL3` and `COMMERCE 4SY3`
were rejected because they are project proposal forms rather than
student-facing course outlines.

The expanded catalog uses `get_course_catalog_v2`. The legacy
`get_course_catalog` RPC remains restricted to the four subject enum values
understood by released clients, preventing an older app binary from failing to
decode the newly added subjects. Current clients decode subject codes
dynamically and build the subject filter from the returned catalog, so adding a
new official subject no longer requires another hard-coded app enum case.

Migration 194 also records the exact Fall 2026 UGRD set in
`course_catalog_offerings` and adds Fall 2026 to the review term picker. Because
the existing review contract requires a professor, only courses with no known
professor association receive the neutral `Instructor not listed` fallback.
Verified course-professor mappings remain unchanged.

## Professor model

Department eligibility is not evidence that a professor taught a particular
course. Do not create the Cartesian product of every department professor and
every department course in `course_professors`.

Add a separate membership relation such as:

```text
professor_subjects
  professor_id
  subject_code
  active_teaching_candidate
  source_url
  retrieved_at
  verified_at
```

For a course's professor picker, show the union of verified historical
`course_professors` and active `professor_subjects` rows matching the course's
subject. A department candidate selected by a user is still not a verified
teaching assignment until it is supported by an offering, outline, or reviewed
submission. Retain emeritus/retired records for historical reviews but exclude
them from the default active picker.

## Generated review files

Run the collectors documented in
`scripts/mcmaster_course_data/README.md`. Review these generated artifacts
before any database import:

- `course_outline_index.csv`: preferred URL rows.
- `outline_candidates.csv`: all source candidates and provenance.
- `missing_courses.csv`: source-adapter/manual-review queue.
- `coverage_by_department.csv`: coverage summary.
- `department_professors.csv`: department candidates, separate from verified
  course teaching history.
