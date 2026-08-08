# ADR-0005: Clean Baseline Product Boundary

Status: Accepted

Date: 2026-08-08

## Context

ADR-0001 captured the boundary after Ride/Team removal, when Rent remained and
Courses was only planned. Migration 127 later removed Rent, migrations 089–126
established Courses, and the iOS client now exposes Courses directly. The
handoff baseline needs one accurate boundary.

The handoff brief also describes Secondhand likes, but migration 140
destructively removed those likes and rejects new ones.

## Decision

Active product areas are:

- Course discovery, reviews, and professor ratings
- Secondhand Marketplace with bookmarks, availability, and owner deletion
- Forum/community with comments and Forum likes
- Search and profiles/social privacy
- Direct and generic group chat
- System Messages, moderation, push, sharing, and lifecycle infrastructure

Rentals/Housing, Ride-Sharing, Carpooling, Team-Up, passenger/driver flows, and
Group-Finding are not active. Generic group chat is not a retired Team-Up flow.

Secondhand comments and likes are not part of the current backend contract.
Bookmarks are supported.

## Consequences

- `PostKind` remains limited to `secondhand` and `forum`.
- Historical migrations keep retired names but active client/worker routes do
  not decode them.
- Restoring Rent or Secondhand likes requires an explicit product decision,
  new forward migrations, client/worker changes, and contract tests.
- Course records remain independent of the shared post hierarchy.

## Validation

- Build the app and tests.
- Run worker syntax/tests.
- Run database tests in a local Supabase stack.
- Classify retired terms as historical migrations, explicit removal tests, or
  current boundary documentation; there must be no live client/worker route.

