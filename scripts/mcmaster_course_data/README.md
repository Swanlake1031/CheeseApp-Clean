# McMaster course-resource collection

This directory contains the URL-first collection and migration-generation tools
for official McMaster course resources. The collectors do not upload to
Supabase and do not download PDF files.

`courses_fall_2026_all.csv` is the complete MyTimetable undergraduate snapshot:
1,604 unique courses across 127 subject codes. Course publication is independent
of outline availability, so every row can be discovered and reviewed even when
no PDF has been found yet.

## Source priority

For each catalog course:

1. Use the newest public McMaster Simple Syllabus document, retaining all
   sections in that newest term.
2. If no public Simple Syllabus document exists, use an official McMaster
   department page or official PDF URL.
3. If neither source produces a URL, place the course in `missing_courses.csv`
   for the next source-specific adapter or manual review.

The primary subject codes are `MATH`, `BIOLOGY`, `CHEM`, `COMMERCE`, `ECON`,
`PSYCH`, and `PHYSICS`. By default the current Engineering and Engineering
Technology subject codes in the Fall 2026 MyTimetable catalog are also included.

## Run

Fast run using the checked local Simple Syllabus result:

```sh
python3 scripts/mcmaster_course_data/collect_course_resources.py
```

If an earlier DeGroote crawl manifest is available, reuse its official URLs and
only request Commerce course pages that are still absent:

```sh
python3 scripts/mcmaster_course_data/collect_course_resources.py \
  --commerce-manifest /path/to/degroote_commerce_outlines/outlines.csv
```

Refresh every published Simple Syllabus term from 2022 onward before applying
official-site fallbacks:

```sh
python3 scripts/mcmaster_course_data/collect_course_resources.py \
  --refresh-simple \
  --simple-min-year 2022
```

Limit the run to the seven primary subject codes:

```sh
python3 scripts/mcmaster_course_data/collect_course_resources.py --primary-only
```

## Outputs

Generated files are written under `generated/`:

* `outline_candidates.csv` contains all discovered URLs and provenance.
* `course_outline_index.csv` contains the preferred URL set for every course.
* `missing_courses.csv` contains remaining gaps.
* `coverage_by_department.csv` summarizes coverage and source selection.

`needs_review=true` means the URL was found through a generic archive-page
association or its academic term could not be verified from official text.

Collect department-level professor candidates separately:

```sh
python3 scripts/mcmaster_course_data/collect_department_professors.py
```

This creates `generated/department_professors.csv`. Retired and emeritus people
are retained for auditability but have `active_teaching_candidate=false`.
Successful source results are also kept in
`generated/department_professors.cache.json`. If one directory is temporarily
rate-limited or unavailable, the next run retains that source's last successful
records instead of silently erasing them from the combined CSV.

Audit candidates that were held for review by temporarily downloading the PDFs,
extracting the first five pages, and applying any recorded visual-review
overrides:

```sh
python3 scripts/mcmaster_course_data/audit_candidate_outlines.py
```

The final decision trail is written to `generated/outline_audit_results.csv`;
manual decisions live in `generated/outline_audit_overrides.csv`. Temporary PDF
files are removed by the auditor and are never part of the production import.

## Database boundary

The generated CSV is review input, not a production import. Migration 191 keeps
the original private-Storage `course_outlines` contract intact and adds
`course_external_outlines` for official URLs. Do not put an external URL into
`storage_path`.

Generate an idempotent SQL migration only after reviewing the CSVs and verifying
the selected URLs:

```sh
python3 scripts/mcmaster_course_data/generate_external_outline_migration.py \
  --audit-results scripts/mcmaster_course_data/generated/outline_audit_results.csv \
  --output Supabase/migrations/NNN_external_course_outline_import.sql
```

The generator includes only preferred rows with `needs_review=false`, validates
the official HTTPS host allowlist, and refuses to continue if the candidate CSV
does not exactly match the reviewed index.

Generate the full undergraduate catalog migration separately from the outline
import:

```sh
python3 scripts/mcmaster_course_data/generate_full_course_catalog_migration.py \
  scripts/mcmaster_course_data/courses_fall_2026_all.csv \
  Supabase/migrations/NNN_import_full_undergraduate_catalog.sql
```

The catalog generator validates uniqueness, titles, departments, and year
levels. It never deletes existing courses. It records current offerings and
adds the neutral `Instructor not listed` option only to courses that otherwise
have no professor association, allowing the existing review form to work while
verified professor data is collected.

Likewise, a professor's department membership and verified teaching history are
different relationships. A future import should use a department/subject
membership relation for the broad professor picker while preserving
`course_professors` for verified course teaching associations.
