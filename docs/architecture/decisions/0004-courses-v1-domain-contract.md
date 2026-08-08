# ADR-0004: Courses V1 Domain Contract

Status: Implemented; product-boundary wording superseded by ADR-0005

Date: 2026-07-24

## Context

Courses and professor ratings are a planned product direction, but the current
repository has no active Courses feature or database contract. Historical
Team-Up migrations contain course-shaped text fields, but those tables and
flows are retired and must not be reused.

The first Courses release needs a stable catalog identity, course details,
official outline references, and student reviews without expanding `PostKind`,
`HomeFeedService`, or the shared `posts` base/detail model.

## V1 Product Scope

Courses V1 includes:

- Course search within a school.
- Course detail with subject, catalog number, title, description, and units.
- Academic term and offering metadata where authoritative data is available.
- Official Course Outline links.
- Student course reviews with text and bounded rating dimensions.
- A prominent Home entry and a Courses section in Search.
- Typed course deep links.

Courses V1 does not include:

- AI course Q&A, comparison, or personalized recommendations.
- A standalone professor review product.
- Student uploads of Course Outline files.
- Registration, timetable planning, prerequisites evaluation, or degree audit.
- Reusing Forum posts as course records or reviews.

## Domain Identity

The existing `schools` table remains the institution identity owner.

New canonical entities:

- `course_subjects`: one subject/department code within a school.
- `courses`: a stable catalog course within a subject.
- `academic_terms`: a school-specific academic period.
- `professors`: a school-scoped instructor identity.
- `course_offerings`: a course taught in a term, optionally with section and
  delivery metadata.
- `course_instructors`: the many-to-many relation between offerings and
  professors.
- `course_outlines`: versioned metadata for an official outline URL.
- `course_reviews`: a student review of a course, optionally contextualized by
  an offering and instructor.

Canonical uniqueness:

- Subject: `(school_id, normalized_code)`.
- Course: `(school_id, subject_id, normalized_catalog_number)`.
- Academic term: `(school_id, normalized_code)`.
- Professor: official source identifier when available; otherwise a
  school-scoped normalized name plus an alias table before automatic merging.
- Offering: `(course_id, academic_term_id, normalized_section)` when section is
  known. An import source identifier may provide the stronger unique key.

Display names and source text are not primary identities.

## Field Ownership

`courses` owns stable catalog facts:

- title
- description
- units
- subject and catalog number
- active/inactive status
- official source and source revision

`course_offerings` owns term-specific facts:

- academic term
- section
- delivery mode
- campus
- attendance requirement, when officially documented
- exam modality, when officially documented

Assessment components belong to an offering or outline, not the stable course.
V1 may store a small structured JSON assessment summary only when it is copied
from an attributed outline. A normalized assessment table should wait until
the product needs component-level filtering or comparison.

## Review Contract

Every review must reference `course_id`.

`course_offering_id` and `professor_id` are optional context. If an offering is
present, the database must verify that it belongs to the same course. A
professor must be linked to that offering before instructor-specific ratings
are accepted.

V1 rating dimensions:

- overall
- difficulty
- workload
- usefulness
- interest
- grading fairness

Each dimension uses one documented bounded scale. Review text is optional only
when at least one rating is supplied.

One active review per `(author_id, course_id, course_offering_id)` is allowed.
Create/update must use one database operation or transactional RPC. Courses
must not copy the current `posts` base/detail compensating-write pattern.

Reviews are user-owned and subject to moderation, blocking visibility, and
author-only update/delete RLS. Official course facts are not user-editable.

## Outline Contract

V1 stores outline metadata:

- `course_id`
- optional `course_offering_id`
- official external URL
- source name
- source revision or fetched timestamp
- optional checksum
- publication status

The preferred V1 source is an attributed official URL. Student file upload is
out of scope. If authorized file storage is added later, it requires a focused
document upload boundary with MIME, size, access, checksum, and orphan cleanup
rules. `ImageUploadService` must not be reused for documents.

## iOS Boundary

The initial dependency direction is:

```text
Courses Views
  -> Courses feature state / ViewModel
      -> CourseService
          -> Supabase
```

Do not add a repository until there is a confirmed second data source,
offline cache, or persistence seam that `CourseService` cannot own cleanly.

Recommended feature directory:

```text
Features/Courses/
  Models/
  Services/CourseService.swift
  ViewModels/CourseSearchViewModel.swift
  ViewModels/CourseDetailViewModel.swift
  Views/CourseSearchView.swift
  Views/CourseDetailView.swift
  Views/CourseReviewForm.swift
```

## Shared-Surface Integration

- `Course` does not enter `PostKind`; it is a catalog entity, not a `posts`
  record.
- Search composes independent post/profile/course result sections. Courses do
  not enter `search_posts`.
- Home renders a Courses entry or section backed by `CourseService`; course
  queries do not enter `HomeFeedService`.
- The app-level deep-link route gains a typed course case while
  `PostDeepLinkRoute` remains post-only.
- V1 uses a prominent Home entry rather than a fifth tab. Tab promotion is a
  later product decision based on usage.

## Data Import Boundary

Official facts are written by a reviewed admin import path, never by the iOS
client. Every imported row records source identity and revision/fetch time.

No automated scraping or bulk import is approved by this ADR. The first source
must be reviewed for stability, attribution, and permitted use before data is
loaded. Manual seed data may be used only in local development and tests.

## Migration Boundary

The first Courses schema migration is `089`.

Migration `089` must be additive and include:

- canonical tables and foreign keys
- uniqueness and rating-range constraints
- indexes for school, subject, catalog number, term, and review aggregation
- RLS for public/authenticated reads as explicitly approved
- author-only review mutations
- no service-role or client-side administrative write path

Search RPCs and review aggregate functions may be added in a later migration
when their exact query contracts are covered by tests.

## Validation Gates

Before Courses write paths merge:

1. Migrations `001...089` replay on a clean local Supabase stack.
2. Schema contract tests verify foreign keys, uniqueness, ranges, and RLS.
3. Course decoding and stale-search-result tests pass.
4. Review create/update/delete tests prove authorization and idempotency.
5. Existing Rent, Secondhand, Forum, Search, Home, and deep-link tests remain
   green.

## Consequences

Positive:

- Courses remains independent from post creation and social-feed complexity.
- Course, term, professor, and offering identities can evolve without string
  matching in Swift.
- V1 can ship useful browsing and review behavior before AI or full timetable
  modeling.

Negative:

- An official catalog source and import owner are still required.
- Offering and professor completeness will vary until authoritative data is
  available.
- Search and deep links gain a new top-level result type, but `PostKind`
  remains stable.
