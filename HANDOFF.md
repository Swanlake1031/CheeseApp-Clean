# Cheese App Engineering Handoff

## Current State

This repository is the clean engineering baseline created from the recovery working tree on 2026-08-08. The iOS app is a SwiftUI/Supabase application with Courses, Forum, Secondhand, Search, Profile, direct/group Chat, System Messages, moderation, sharing, and push infrastructure.

Rentals/Housing is not present in the current client or database contract. Ride-Sharing, Carpooling, Team-Up, and Group-Finding are retired. Generic group chat is supported. Secondhand currently supports bookmarks but not likes because migration 140 rejects Marketplace likes; it has no comment system.

## What Was Cleaned

- Replaced Home's many independently published content fields with one coherent content snapshot.
- Preserved visible Home content during background refresh and retained old source sections when a source fetch fails.
- Removed obsolete progressive Home loaders.
- Changed Forum interaction hydration from one observable revision per post to one revision per response batch.
- Removed an N+1 block-relation request loop from group creation and consolidated the shared member-selection row.
- Removed the unreachable Forum bell notification stack; System Messages remains the notification inbox.
- Removed the replaced Favorite Posts service/screen and other confirmed unreferenced files, components, and DTOs.
- Removed embedded Supabase project configuration and strengthened ignore rules for local credentials/signing artifacts.
- Removed split root/per-tab navigation ownership; each persistent tab now owns one stack at the `MainTabView` boundary.
- Routed all post links/notifications to Home and all conversation/group/System Message notifications to Chat through an explicit tab policy with unit-test assertions.
- Excluded historical recovery artifacts, dependencies, build output, Xcode user state, prototypes, and an unrelated nested website repository from this baseline.
- Replaced the owner-post action-icon strip with one native `编辑` menu and kept destructive deletion confirmation.
- Added the recoverable “私密内容” surface by reusing the existing Profile activity view, filters, cards, pagination, edit, share, and delete flow.
- Unified Forum/Secondhand public visibility on `posts.is_private`; `hidden_at` and `hidden_reason` are descriptive metadata rather than competing booleans.
- Changed the Marketplace 30-day worker transition from `status = inactive` to auto-hide, preserving the original post and resetting a fresh 30-day cycle when restored.

See `ARCHITECTURE_AUDIT.md` for evidence and `ARCHITECTURE.md` for the resulting ownership model.

## Important Architectural Decisions

- Keep `AuthService` as the app-level identity/session owner.
- Keep `HomeViewModel` owned by `MainTabView`; do not reconstruct it on each Home appearance.
- Keep one published Home content snapshot. Loading/mutation state may remain separate.
- Use `PostInteractionStore` as the viewer-relative source for Forum likes and bookmarks across screens.
- Keep feature query state scoped to the screen/query unless multiple consumers genuinely need account-wide ownership.
- Preserve generation/request checks during account transitions; late results from the previous user must not publish.
- Use System Messages for notification history. Do not revive the deleted Forum bell cache/view model.
- Use `CachedRemoteImage` for public remote images and the authenticated chat media path for private attachments.
- Keep full, compact, and search card variants when their information density differs; share narrow semantic components instead of building a flag-heavy mega-card.
- Keep one `NavigationStack` per persistent tab, owned by `MainTabView`; global route input selects a tab and lets that stack present the destination.
- Add Supabase changes as new migrations. Do not rewrite history.
- Change post visibility only through `set_my_post_hidden`. Do not use deletion, a local hidden dictionary, or `expires_at` as a parallel visibility source.

## Known Remaining Technical Debt

- `ForumService`, `ChatService`, `AuthService`, `ForumDetailView`, `SearchView`, `ProfileSettingsViews`, `HomeView`, and `HomeViewModel` remain large. Split them only along ownership boundaries during relevant feature work.
- Forum/Secondhand presentation has multiple legitimate density variants, but some author, metric, and domain formatting remains duplicated.
- Several global services publish related fields separately. Convert to feature snapshots only when solving a concrete inconsistency or render problem; do not introduce a global Redux/TCA store.
- Simulator UI automation does not cover every manual gesture and signed-in backend path. On 2026-08-08, the available iOS 26.3 simulator failed before launching XCTest with CoreSimulator Mach error -308; the app and test bundles still compiled successfully.

## Areas That Should Not Be Casually Changed

- Account transition ordering in `CheeseAppApp` / `AuthService`.
- `PostKind` decoding and removed product kinds without coordinated migrations and worker changes.
- Migration 085 (Ride/Team removal), migration 127 (Rent removal), or migration 140 (Secondhand likes) by editing old files.
- RLS, SECURITY DEFINER functions, storage visibility, or private chat media handling.
- The one-stack-per-tab boundary, route-to-tab policy, or swipe gesture behavior without device regression tests.
- Home refresh publication back to per-source progressive assignment.
- The distinction between System Messages and push routing.
- Migrations 152–154 hidden-post lifecycle and Search follow-up: public feeds depend on `status` plus `is_private`; `expires_at` is only the worker deadline, and restoring must retain the same post ID.
- Rentals/Housing and Secondhand likes/comments are explicitly outside the product boundary; do not revive historical implementations.

## Build the App

Requirements: a current Xcode with the iOS 26 simulator/runtime used by the project, and access to the configured Supabase development project.

1. Configure the environment values below in the CheeseApp Xcode scheme, or provide matching build settings so `Info.plist` receives them.
2. Open `CheeseApp/CheeseApp.xcodeproj` and select the `CheeseApp` scheme.
3. Resolve Swift packages and run on a simulator/device.

Command-line validation:

```sh
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD build
xcodebuild -project CheeseApp/CheeseApp.xcodeproj -scheme CheeseApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/CheeseAppDD-tests build-for-testing
npm run check --prefix cheeseapp-share-worker
npm test --prefix cheeseapp-share-worker
```

Use a concrete simulator destination for `xcodebuild ... test` when one is installed.

## Required Local Configuration

Do not commit values. The iOS app reads environment values first and the built Info.plist second.

| Name | Required | Consumer | Purpose |
| --- | --- | --- | --- |
| `SUPABASE_URL` | Yes | iOS, worker | Supabase project endpoint |
| `SUPABASE_PUBLISHABLE_KEY` | Yes for iOS; worker fallback only | iOS, worker | Public client authentication key |
| `SUPABASE_AUTH_REDIRECT_URL` | No | iOS | Auth callback; defaults to `cheeseapp://auth/callback` |
| `SUPABASE_SERVICE_ROLE_KEY` | Production worker | worker secret | Server-side share/push/lifecycle operations; never expose to iOS |
| `APNS_AUTH_KEY` | Push worker | worker secret | Full Apple APNs private key |
| `APNS_KEY_ID` | Push worker | worker variable/secret | APNs key identifier |
| `APPLE_TEAM_ID` | Push worker | worker variable/secret | Apple developer team identifier |
| `APP_BUNDLE_ID` | Optional | worker | Explicit APNs topic override |
| `APP_DOWNLOAD_URL` | Optional | worker | Share-page download target |
| `WECHAT_OPEN_APP_ID` | Optional | worker | WeChat open-app integration |
| `WECHAT_JS_SDK_CONFIG_URL` | Optional | worker | WeChat signature endpoint |

Tests use a non-production placeholder only when loaded under XCTest; production/development launches fail fast when required iOS configuration is missing.

For iOS development, copy `CheeseApp/Configuration/Local.xcconfig.example` to the Git-ignored `Local.xcconfig` and supply the public client values. If an existing local worker `wrangler.toml` already contains those public values, run `scripts/configure-ios-local.sh --from-worker /path/to/wrangler.toml`. The Xcode app target imports this file through `Shared.xcconfig`; no scheme editing is required. Keep the documented `$()` URL escaping because raw `//` starts an xcconfig comment.

For Cloudflare, configure `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` as deployment variables and privileged values with `wrangler secret put` or Secrets Store. See `cheeseapp-share-worker/README.md`.

## Important Backend Dependencies

- Supabase Auth, PostgREST, Realtime, Storage, RLS, database functions, and reviewed public views.
- Ordered migrations through the latest file in `Supabase/migrations`.
- Migrations 152–154 are required for the private-content UI, 30-day auto-hide contract, and matching Search schema; deploy them before shipping the matching iOS/worker build.
- Cloudflare Worker routes for `cheeseapp.org`, cron lifecycle jobs, and universal-link/AASA delivery.
- APNs credentials and queued push database contracts.
- Course import files and manifests under `docs` / `scripts` where applicable.

Before using a new database, follow the Supabase reset/bootstrap documentation; do not point a development build at production casually.

## Suggested Next Engineering Tasks

1. Add signed-in UI/integration coverage for Home → Detail → Back, refresh preservation, Search result return, and post interaction reconciliation.
2. Add signed-in device coverage for post links/pushes, Chat pushes, per-tab history, and Home drawer/swipe gesture coexistence.
3. Split Search or Forum service boundaries when those features next receive substantive work.
4. Incrementally share narrow author/metric presentation components across Forum, Home, Search, and Profile.
