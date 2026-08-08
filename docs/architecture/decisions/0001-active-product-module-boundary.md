# ADR-0001: Active Product Module Boundary

Status: Superseded by ADR-0005

Date: 2026-07-22

This ADR records the post-migration-085 boundary. Migration 127 later removed
Rent and Courses subsequently became an active standalone module. Use
`0005-clean-baseline-product-boundary.md` for the current boundary.

## Context

Ride-Sharing, Carpooling, Team-Up, and Group-Finding created the wrong product direction and leaked into Search, Profile, Create, Deep Links, Chat, the share worker, and Supabase migrations. The app is now focused on campus marketplace/community surfaces.

## Decision

The active product modules are:

- Rentals
- Secondhand marketplace
- Forum/community
- Profiles
- Search
- Direct messaging
- Generic group chat
- Authentication
- Moderation
- Notifications

Courses and professor ratings remain a target product direction, but they are not a full active module until they have explicit feature code and database schema.

Ride-Sharing, Carpooling, Team-Up, passenger demand, driver/passenger modes, and Group-Finding are removed modules. They must not be rebuilt by copying historical migration code.

## Alternatives Considered

- Keep Ride/Team hidden but available in code: rejected because hidden dead code kept polluting active paths.
- Keep Carpool route templates as future infrastructure: rejected for current architecture because there is no active product flow using them.
- Rewrite old migrations to erase history: rejected because migration history must remain immutable.

## Consequences

Positive:

- Active app paths are easier to understand.
- `PostKind` and share worker supported kinds are smaller.
- Search/Profile/Create/Deep Links no longer need retired module branches.

Negative:

- Live database must apply cleanup migration `085` before shipping app builds that no longer support removed post kinds.
- Historical migrations still contain removed module references and can confuse future agents if docs are ignored.

## Affected Modules

- `CheeseApp/CheeseApp/Core/Models/PostKind.swift`
- `CheeseApp/CheeseApp/Features/Create`
- `CheeseApp/CheeseApp/Features/Search`
- `CheeseApp/CheeseApp/Features/Profile`
- `CheeseApp/CheeseApp/Core/Services/PostDeepLinking.swift`
- `cheeseapp-share-worker`
- `Supabase/migrations/085_remove_ride_and_team_modules.sql`
- `docs`

## Migration Plan

1. Keep old migrations as historical records.
2. Apply `085_remove_ride_and_team_modules.sql` to live Supabase after remote history repair, dry-run, backup/counts, and review.
3. Keep documentation explicit that retired module names in migrations before `085` are historical only.

## Validation Plan

- Build iOS app and test bundle.
- Run share worker check.
- Scan active app/worker source for retired module terms.
- Confirm `posts.type` allows only `rent`, `secondhand`, and `forum` after `085`.
