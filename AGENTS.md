# Cheese App Agent Guide

## Current Product Boundary

The active product surface is:

- Course discovery, course reviews, and professor ratings.
- Second-hand marketplace.
- Community forum.
- Shared auth, profiles, moderation, notifications, search, chat, and infrastructure.

Do not reintroduce retired Ride-Sharing, Carpooling, Team-Up, or Group-Finding flows. Generic group chat is still a supported shared capability.

Rentals/Housing is not present in the current app or schema contract. Migration 127 removed that module. Treat reintroduction as a new product/backend project requiring explicit approval and forward migrations; do not infer it from historical migrations or documentation.

## Important Paths

- iOS app: `CheeseApp/CheeseApp`
- iOS tests: `CheeseApp/CheeseAppTests`
- Supabase migrations: `Supabase/migrations`
- Supabase seed/reset docs: `Supabase`
- Share worker: `cheeseapp-share-worker`
- Architecture baseline: `ARCHITECTURE.md`
- Audit and handoff: `ARCHITECTURE_AUDIT.md`, `HANDOFF.md`
- Supporting architecture decisions: `docs`

## Verification Commands

Run these after product-surface or data-contract changes:

```sh
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD build
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD-tests build-for-testing
npm run check --prefix cheeseapp-share-worker
```

If simulator devices are available, also run the scheme tests on a concrete simulator destination.

## Database Rules

- Add new migrations. Do not rewrite old migration history for product cleanup.
- Destructive migrations must document deleted data, rollback limits, backup requirements, and production order.
- Apply `Supabase/migrations/085_remove_ride_and_team_modules.sql` before shipping app builds that no longer decode `ride` or `team` post types.

## Definition of Done

- App and test bundles compile.
- Share worker syntax check passes.
- Removed feature terms are searched across app, tests, worker, database, seeds, and docs.
- Remaining matches are classified as live code, historical migrations, expected documentation, or unrelated infrastructure.
- Secrets are not printed in reports or logs.
