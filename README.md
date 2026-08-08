# Cheese App

Cheese is a SwiftUI campus community application backed by Supabase. This repository is the clean developer handoff baseline; it intentionally starts with fresh Git history while the historical repository remains the recovery source.

## Active Product Surface

- Course discovery, reviews, and professor ratings
- Community Forum with boards, anonymous posting rules, moderation, comments, and Forum likes
- Secondhand Marketplace with bookmarks, seller identity, availability/expiration, and owner deletion
- Search across active domains and profiles
- Profiles, follow/privacy controls, moderation, and activity
- Direct and generic group chat with private media
- System Messages, push routing, public share links, and backend lifecycle workers

Secondhand has no comment system and supports bookmarks, not likes. Rentals/Housing and retired Ride/Team/Carpool/Group-Finding flows are not active. These removed surfaces must not be restored from historical code or migrations.

## Repository Layout

```text
CheeseApp/                 iOS app, Xcode project, and tests
Supabase/                  append-only migrations, seed, and reset/bootstrap docs
cheeseapp-share-worker/    Cloudflare share/push/lifecycle worker
scripts/                   reviewed maintenance/import scripts
docs/                      supporting decisions, deployment, import, and smoke-test docs
```

The runtime flow is generally:

```text
SwiftUI View → feature state/ViewModel → service/repository → Supabase
```

Home content is committed as one coherent snapshot, and `PostInteractionStore` owns cross-screen Forum-like/bookmark state. See [ARCHITECTURE.md](ARCHITECTURE.md) for state ownership and data flow.

## Setup

Requirements:

- Xcode with a compatible iOS simulator runtime
- Node.js/npm for the worker
- Access to the intended Supabase development project
- Cloudflare/APNs access only when developing or deploying worker functionality

Configure these values locally; never commit their values:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- optional `SUPABASE_AUTH_REDIRECT_URL`

Add them to the CheeseApp Xcode scheme environment for local runs, or provide matching Xcode build settings so the Info.plist placeholders are expanded. Worker deployment configuration is listed in [HANDOFF.md](HANDOFF.md) and `cheeseapp-share-worker/README.md`.

Install worker dependencies when needed:

```sh
npm ci --prefix cheeseapp-share-worker
```

## Build and Test

```sh
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD build
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD-tests build-for-testing
npm run check --prefix cheeseapp-share-worker
npm test --prefix cheeseapp-share-worker
```

Run the Xcode scheme tests against a concrete simulator when available. Backend-dependent manual flows require a non-production account and correctly migrated development project.

## Database Safety

- Apply migrations in numeric order.
- Add new migrations; never rewrite applied migration history.
- Review destructive migration headers, backups, rollback limits, and production order.
- Keep privileged keys out of the app and repository.
- Do not reintroduce retired post kinds or Secondhand likes solely in client code.

## Handoff Documents

- [Architecture](ARCHITECTURE.md) — current layers, feature ownership, loading, navigation, and extension guide
- [Architecture Audit](ARCHITECTURE_AUDIT.md) — evidence, severities, fixes, deferrals, and deletion decisions
- [Engineering Handoff](HANDOFF.md) — setup, configuration names, backend dependencies, known debt, and next tasks
