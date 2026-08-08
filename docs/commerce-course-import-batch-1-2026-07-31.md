# Commerce course import — batch 1

Date: 2026-07-31
Original scope: local batch-1 verification
Current status: superseded by the verified full-catalog production rollout through migration 126

> Historical note: this report records the first incremental verification gate.
> The later full-catalog run successfully executed the targeted iOS tests (16/16)
> and deployed all 87 verified Commerce courses. See
> `docs/commerce-course-full-import-2026-07-31.md` for the final production state.

## Outcome

The first Commerce batch contains eight courses. It reuses the existing Courses domain (`courses`, `professors`, `course_professors`, `course_outlines`, `course_reviews`) and its existing catalog, outline, review, edit, delete, ownership, validation, and refresh RPCs. No Commerce-only model, review table, service, or UI path was introduced.

Seven courses use a Winter 2026 outline. `COMMERCE 2AB3` uses Fall 2025 because the supplied source set has no Winter 2026 outline for that course. Terms, course codes, campus/institution, sections, and instructors were verified from the content inside each PDF; filesystem modification and upload dates were not used for selection.

The selected PDFs are only 327–535 KB. They were therefore preserved byte-for-byte instead of being recompressed, and each private Storage object path is bound to its SHA-256 value.

## Selected courses and outlines

| Course | Normalized title | Selected term | Source file | Professors connected | Selection notes |
| --- | --- | --- | --- | --- | --- |
| COMMERCE 1AA3 | Introductory Financial Accounting | Winter 2026 | `1AA3/1AA3 - Winter 2026 - C01 - E. Islam.pdf` | Ebadul Islam; Linyang Yu | The full-catalog reconciliation corrects the initial shorter title forward-only in migration 124. The PDF itself covers sections 1 and 2 and names both instructors. |
| COMMERCE 1BA3 | Organizational Behaviour | Winter 2026 | `1BA3/1BA3 - Winter 2026 - C01, C02, C03, C04 - T. McAteer.pdf` | Teal McAteer | A Summer 2026 source also exists, but the approved selection order explicitly prefers Winter 2026. |
| COMMERCE 1DA3 | Business Data Analytics | Winter 2026 | `1DA3/1DA3 - Winter 2026 - C01, C04, C05 - B. Bakhtiari.pdf` | Behrouz Bakhtiari; Maryam Mashayekhi; Mingyao Song; Hamedhossein Afshari | The PDF content covers all listed sections and all four instructors, despite the abbreviated filename. |
| COMMERCE 1MA3 | Introduction to Marketing | Winter 2026 | `1MA3/1MA3 - Winter 2026 - C. Ling, S. Kim.pdf` | Chris Ling; Sanghwa Kim | Standard multi-section outline. |
| COMMERCE 2AB3 | Managerial Accounting I | Fall 2025 | `2AB3/2AB3 - Fall 2025 - C01-C03 - A. Mokhtar.pdf` | Ala Mokhtar; A. S. Merali | The full-catalog reconciliation corrects the initial shorter title forward-only in migration 124. This is the closest available term after confirming that no Winter 2026 source exists. |
| COMMERCE 2BC3 | Human Resource Management and Labour Relations | Winter 2026 | `2BC3/2BC3 - Winter 2026 - C01 - A. Boey.pdf` | Anita Boey; Sean O’Brady | The canonical PDF is the C01 outline. Migration 124 also connects Sean O’Brady from the separate C02–C05 Winter 2026 outline. |
| COMMERCE 2FA3 | Introduction to Finance | Winter 2026 | `2FA3/2FA3 - Winter 2026 - J. Tome.pdf` | Jason Tome | Standard Winter 2026 outline. |
| COMMERCE 2KA3 | Information Systems in Management | Winter 2026 | `2KA3/2KA3 - Winter 2026 - C01, C03, C05 - C. Ekmekcioglu.pdf` | Cansu Ekmekcioglu; Rae Elgamal | The PDF itself covers all sections and both instructors. |

Source root: `/Users/timonayf/degroote-scraper/degroote_commerce_outlines/`

## Skipped or deferred

- `COMMERCE 1GR0` was deliberately skipped. Its filename suggests Fall 2025, but the PDF internally describes the full `2025–26` academic year. The current outline schema expects one academic year and one term, so assigning it to Fall would misrepresent the source. This needs an explicit full-year-course policy before import.
- The remaining source PDFs were intentionally deferred. The source contains approximately 316 PDFs, and importing them now would violate the requested incremental rollout.
- No duplicate course or outline records were merged in this batch because none of the eight normalized course codes existed after local reset. The migration still uses idempotent conflict handling and deterministic IDs, and it rejects a pre-existing course-code identity that would not match the immutable Storage path.

## Data and architecture

- Courses use normalized `COMMERCE nXXn` codes, normalized titles, subject `COMMERCE`, and the correct first- or second-year value.
- Sixteen verified course-professor mappings are present after the full-catalog reconciliation. Professor identities use deterministic UUIDs and do not use display names as a uniqueness key.
- Each course has exactly one selected outline in the existing private `course-outlines` bucket.
- Outline object paths are immutable: `<course UUID>/<year>/<term>/<sha256>.pdf`.
- The source PDFs identify McMaster University and the DeGroote School of Business. The current single-school Course schema has no independent campus/faculty columns; `subject = COMMERCE` is the existing discovery faculty/category boundary. No speculative multi-school schema was added.
- The existing iOS catalog and filtering path is reused. A unit test covers Commerce code search with whitespace normalization, title search, professor search, subject filtering, and year filtering.

## Review and comment behavior verified

Local database tests prove that an authenticated user can:

- discover all eight courses and their professor options;
- discover the selected private outline metadata and access registered Storage objects;
- submit one review with overall, fun, usefulness, easiness, professor rating, written review text, academic term, and selected professor;
- immediately see the new review in a refreshed snapshot;
- edit ratings, text, and professor without creating a duplicate review;
- delete their own review;
- view another user's review without gaining ownership.

They also prove that another user cannot delete the review, direct table mutation is unavailable to clients, and anonymous users cannot execute the catalog/review RPCs or read private outline objects.

The existing Course domain stores the written course comment in `course_reviews.review_text`. It does not currently have Course-review anonymity, review likes, reporting, or paginated review snapshots. Those capabilities were not duplicated or invented for Commerce. If they are added later, they should be implemented once in the shared Courses domain. Current Commerce behavior therefore matches the existing production Course feature exactly, including its current non-paginated snapshot limitation.

## Verification performed

- PDF text extraction: verified internal academic term, course code, title, McMaster/DeGroote identity, sections, and instructors for all eight selected files.
- PDF visual QA: rendered and inspected the first page of all eight selected files.
- Local `supabase db reset`: passed through migrations 001–123 and `Supabase/seed.sql`.
- Local Storage seed: passed; all eight new immutable objects were present.
- Local pgTAP: 21 files, 417 tests, all passed. Batch 1 contributes 31 tests.
- Local Storage byte verification: one Winter 2026 object and the Fall 2025 object were downloaded and matched their expected SHA-256 values.
- Local database lint: exited successfully. It reported only pre-existing PostGIS analyzer findings and the existing unused-variable warning in `create_forum_comment_with_mentions`; migration 123 added no function/lint warning.
- App target build for generic iOS Simulator: passed.
- Share worker syntax check: passed.
- `git diff --check`: passed.
- Test bundle build: passed after deleting only the two `/tmp` DerivedData directories created by this verification run. Available disk space recovered from approximately 237 MB to 29 GB before the clean rebuild.
- iOS tests actually executed: no assertions executed. Two targeted attempts were made for `CourseDiscoveryFilterTests`, `CourseReviewTests`, and `CourseOutlineTests`. The first test host exited before establishing its connection. After the existing Simulator was manually booted to a terminal-ready state, the second attempt failed while launching Xcode's test clone with `Invalid device state` and `(ipc/mig) server died`; the Simulator then shut down. These are CoreSimulator/test-runner environment failures, not passing or failing assertions.

## Original rollout status and next step

Nothing was deployed to production and nothing was pushed to GitHub. Migration 123 and the eight Storage assets exist only in the local worktree/local Supabase verification environment.

Before any linked-environment rollout:

1. Repair or replace the unstable local Simulator runtime and actually execute the targeted Course tests; do not treat the successful Test bundle build as executed tests.
2. Review this eight-course batch in the app.
3. Upload the eight immutable PDFs to the existing private `course-outlines` bucket without replacing objects.
4. Apply migration 123.
5. Verify authenticated outline download and anonymous denial.
6. Only after this batch is accepted, select another small Commerce batch using the same content-based term verification process.

The statements in this section describe the batch-1 checkpoint at the time it was
written. They are no longer the current environment state: migrations 123–126 and
all 87 verified Commerce outlines were subsequently rolled out to production after
the full validation recorded in the full-import report. GitHub still was not pushed.
