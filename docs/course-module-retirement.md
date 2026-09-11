# Course module retirement — 2026-09-06

The user requested removal of the entire in-app course-rating module and all
associated course data, PDFs, outlines and historical reviews.

The app no longer has the Courses tab, discovery/detail/review/PDF screens,
course services or models, or course-rating links in Home/Profile drawers.
Course import scripts, datasets, local PDF files and obsolete module tests are
removed. Home card models and ranking tests cover Forum and Secondhand only.

Migration `20260906203031_remove_course_ratings_module.sql` removes the eight
course-domain tables, five RPCs, and outline access policy.
The 100 stored PDFs and their bucket must first be removed through the Storage API. The migration
refuses to proceed while any course PDF objects remain and uses no CASCADE.
The pre-removal production inventory was 1,651 courses, 523 professors,
100 private outlines/PDFs, 393 external outlines and 2 historical reviews.

Recovery after commit requires an existing database backup/PITR; Storage object
recovery requires an independent PDF backup. No new retained copy of reviews
or PDFs is created. Earlier Git commits/migrations remain historical records;
this removal does not rewrite repository history or alter provider retention.
Released app binaries must be replaced with this build to remove their UI.

Production execution completed on 2026-09-06. Read-only verification returned
zero course-domain tables, zero course RPCs, zero course PDF objects, and zero
course buckets. Shared profile/post/forum/marketplace tables remained present.
The four local database retirement checks passed, along with app compilation,
test-bundle compilation, and the share-worker syntax check.
Simulator execution was attempted on CheeseApp-H2-Tests-2 (iOS 26.3), but
CoreSimulator failed to launch the test host with NSMachErrorDomain -308
(`ipc/mig server died`) before any test cases ran. Runtime tests are therefore
not claimed as passing; the app and test bundles compile successfully.

The Supabase security advisor was checked after removal. Its remaining notices
concern existing shared views, functions, and Auth configuration outside this
removal; the course removal adds no new exposed objects. Existing view notices
can be reviewed using the [Supabase view guidance](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view).

Remaining course-related terms are classified as follows:

- Earlier SQL migrations: immutable historical schema/import records.
- Architecture audit and superseded ADRs: historical descriptions, superseded
  by this decision and the current AGENTS.md/ARCHITECTURE.md contract.
- Forum examples, academic conduct rules and MSAF posts: ordinary community
  discussion, not course-rating functionality or course-review records.
- Cheese Radar: an independent external seat-registration link, outside the
  removed rating module; its service and entry point remain available.
- `outline` in SwiftUI styles: visual borders, unrelated to course documents.
