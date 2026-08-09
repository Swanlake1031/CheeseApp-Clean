# Cheese App Architecture

This document describes the code that exists in the clean baseline. It is a practical map, not a proposal for a framework migration.

## Application Layers

```text
SwiftUI View
    ↓ user intent / lifecycle event
Feature ViewModel or feature-owned ObservableObject
    ↓ async operation
Feature service / repository
    ↓ reviewed query, RPC, Realtime, or Storage call
Supabase and PostgreSQL policy/function contract
```

- `CheeseAppApp` is the application entry point. It restores authentication, installs account-transition handlers, accepts URLs/universal links, and routes push-notification intents.
- `MainTabView` owns the persistent tab shell and long-lived tab state. Home, Search, Chat, and Profile are lazily mounted; Create is presented as a full-screen flow.
- `Core` contains authentication, Supabase configuration, shared network/storage behavior, image loading, formatting, and cross-feature interaction state.
- `Features` contains domain-specific models, services, view models, and views.
- `Shared` contains UI and domain pieces with genuine cross-feature use. It is not a dumping ground for feature-specific code.
- `Supabase/migrations` is the append-only backend contract. Existing migrations are historical evidence and must not be rewritten.
- `cheeseapp-share-worker` owns public share pages, universal-link metadata, queued push delivery, media cleanup, and Secondhand lifecycle jobs.

Views do not directly query Supabase in the current baseline. Feature services and repositories own external operations; a View may own presentation-specific tasks and state.

## Feature Structure

| Area | Primary state/orchestration | External operations | Main presentation |
| --- | --- | --- | --- |
| Home | `HomeViewModel` | `HomeFeedService`, Forum/Secondhand services, interaction services | `HomeView` and `ContentCardView` |
| Forum | `ForumChannelFeedModel`; detail-local state | `ForumService` | Forum list, card, detail, create/edit views |
| Secondhand | `SecondhandService` plus screen-local filters | `SecondhandService`, post favorite service | list/detail/create/edit views |
| Courses | `CourseDiscoveryViewModel`, `CourseReviewViewModel` | course catalog/review services | `CourseSummaryCard`, discovery/detail/review views |
| Search | `SearchViewModel` | `SearchService` and feature services | `SearchView` and domain-specific result rows |
| Profile | `AuthService.currentUser`; query-scoped activity/social services | profile, social, and activity services | profile/settings/activity/user-post views |
| Chat | `ChatService`; room lifecycle controllers | chat repositories, Realtime, private media services | conversation/group/room views |
| Notifications | `SystemMessageService` and `SystemMessageViewModel` | system-message queries and push router | System Messages inside Chat |

Rentals/Housing is not an active feature and must not be restored. The empty directory structure is not a product surface, `PostKind` has only `forum` and `secondhand`, and migration 127 removes the old Rent contract. Ride-Sharing, Carpooling, Team-Up, and Group-Finding are also retired. Generic group chat remains active.

## Data Flow

### Read path

1. A persistent feature owner receives `.task`, refresh, pagination, or a navigation request.
2. It coalesces or guards the request where applicable and captures the account/request generation.
3. Services perform async Supabase/RPC/Storage work and map database rows into domain values.
4. The owner verifies cancellation and account/request identity.
5. It publishes the new state on the main actor.

### Mutation path

1. The View sends intent to its feature owner or service.
2. Small reversible interactions may update `PostInteractionStore` optimistically.
3. The service persists the change.
4. Success reconciles canonical interaction state; failure rolls it back and surfaces an error.
5. Creation/deletion events use `PostFeatureEvents` to invalidate only consumers that need cross-feature awareness.

Account changes are special: `AuthService` synchronously begins an account transition, clears viewer-relative state, then activates each account-scoped service for the new user. Generation checks prevent late work from the previous account from publishing.

## State Ownership

### Authenticated user

`AuthService.shared` owns the session, current profile, bootstrap state, and profile-completion requirement. Feature code should not preserve an independent editable copy after a successful profile update.

### Home feed

`MainTabView` owns one `HomeViewModel` for the lifetime of the authenticated tab shell. `HomeViewModel` publishes one `HomeContentSnapshot` containing visible card collections, lookup models, follow IDs, resolved flags, and recommendation seed. A refresh retains the old snapshot, fetches Home sources concurrently, keeps the old portion for any failed source, hydrates interactions in one batch, and replaces content once.

`loadIfNeeded` uses a five-minute freshness window and coalesces an in-flight refresh. Returning to Home within that window does not act like a new launch. Pull-to-refresh calls the explicit refresh path. Loading flags are separate so a background refresh does not remove usable content.

### Likes and bookmarks

`PostInteractionStore.shared` is the canonical viewer-relative state for Forum likes and cross-feature bookmarks. Home, Forum detail/cards, Profile activity, and other consumers read it by post ID; embedded model values are fallbacks for first paint. Batch responses must use `merge(_ updates:)` so one response produces one revision.

The current backend rejects likes for Secondhand posts (migration 140). Secondhand bookmarks are supported. Secondhand likes are outside the product boundary and must not be restored.

### Forum posts

`ForumChannelFeedModel` owns a screen/query result and pagination state. `ForumService` owns post/comment/board operations and maps reviewed database views to `ForumPostItem`. Forum detail owns its loaded post/comments for the screen while interaction values remain canonical in `PostInteractionStore`.

### Secondhand listings

`SecondhandService.shared` owns list snapshots, pagination, item mapping, availability, and external operations. Detail screens may hold a loaded item value; favorite state is reconciled through `PostInteractionStore`. Secondhand intentionally has no comment system.

Marketplace expiry is a scheduling deadline, not an independent presentation state. The worker calls `process_secondhand_availability_lifecycle`; at 30 days the database changes the canonical post visibility to hidden while preserving the active post row, images, metadata, and interactions. Restoring that same post starts a new availability cycle and sets a fresh `expires_at` deadline.

### Course ratings

`CourseDiscoveryViewModel` owns catalog discovery and `CourseReviewViewModel` owns a coherent course-review snapshot, filters, and mutations. `CourseSummaryCard` is the canonical reusable summary card. Home links to Courses; it does not maintain a second rating-card implementation.

### Profile data

`AuthService.currentUser` owns the signed-in profile identity. `ProfileSocialService` is the canonical owner for follow mutations and cached relationship summaries; Search and Chat follow-search keep only result projections and reconcile them from `ProfileSocialEvents`. `ProfileActivityService` and `UserPostsService` own scoped activity/profile-post queries, caching, visibility mutations, and pagination. “我的发布” and “私密内容” use the same `ProfileActivityView`/`ProfileActivityService` flow, distinguished only by the server-side `visible` or `hidden` query parameter. The legacy Favorite Posts service/screen was removed; profile activity is the active path.

### Post visibility lifecycle

For Forum and Secondhand posts, durable visibility has one owner: `posts.is_private`.

- `is_private = false`: eligible for public feeds, search, recommendations, following, and public profiles when `status = active`.
- `is_private = true`: hidden from public surfaces and readable by the author through “私密内容”.
- `hidden_at` and `hidden_reason` (`user` or `auto_expired`) describe why/when a post was hidden; they are metadata, not additional visibility switches.
- `status = deleted` remains the non-recoverable deletion path. Hiding never deletes media or creates a replacement post ID.

Visibility changes go through `set_my_post_hidden`. The service emits one `PostFeatureEvents` invalidation after the RPC succeeds so mounted Home, Forum, Secondhand, Search, and Profile query owners refresh from the same database truth. Do not add a ViewModel-only hidden dictionary or reintroduce `expires_at` filtering as a second source of public visibility.

### Chat and notifications

`ChatService.shared` owns conversation/group previews and account-scoped unread state. Room controllers own message timelines and cancellation. Private chat media uses authenticated/signed loading rather than the public image cache. `SystemMessageService` is the only current notification inbox; the unreachable Forum-specific bell architecture was removed.

## Loading Model

Use these meanings consistently:

- **Initial load:** no valid content has been resolved. A skeleton, progress view, or empty/error state may replace the body.
- **Background refresh:** valid content remains visible while a replacement snapshot is fetched. Failure preserves the old content.
- **Pagination:** append one guarded page; do not reset the current page. Prefer keyset/cursor contracts already used by the feature.
- **Mutation:** disable or mark only the affected control/item. Optimistic mutations must roll back on failure.

Lifecycle `.task` handlers must be idempotent. Repeated tab appearances should use `loadIfNeeded`, freshness policy, or an in-flight guard rather than unconditional reload. Long-running screen tasks must honor cancellation and account/request generations before publishing.

## Navigation

- The app root chooses bootstrap, authenticated, or authentication UI.
- `MainTabView` owns exactly one `NavigationStack` for each persistent tab: Home, Search, Chat, and Profile.
- Feature roots such as `HomeView` and `ProfileView` declare destinations but do not create a second root stack.
- Create Post and profile onboarding are full-screen covers.
- URL/universal-link input goes through `PostDeepLinkCoordinator`; push intent goes through `AppNotificationRouter`.
- Post routes select Home and are presented by the Home stack. Conversation, group, and System Message routes select Chat and are resolved by the Chat stack.
- Reselecting a tab resets only that tab's stack identity. Switching tabs preserves the other mounted stacks and their histories.
- Swipe-back behavior is installed once at each persistent tab stack through the shared navigation extension. The Home drawer keeps its separate leading-edge gesture.

Do not add an authenticated-content `NavigationStack` above `MainTabView`, or add another root stack inside a persistent feature root. A new global route must declare its target tab in `AppTabNavigationPolicy` and be presented by that tab's stack.

## Shared Components and Infrastructure

- `PostInteractionStore`: cross-screen Forum-like/bookmark state.
- `ContentCardView`: Home/shared feed card shell.
- `CourseSummaryCard`: canonical course summary presentation.
- `MutualFollowSelectionRow`: group-member selection row used by both group creation contexts.
- `CachedRemoteImage` / `RemoteImageCache`: public remote images with bounded memory/disk caching, coalescing, and background decoding/downsampling.
- Avatar and interaction components under `Shared/Components`: reuse when semantics match; keep full/compact/search layouts separate when density genuinely differs.
- Chat media loaders: private content path; do not replace with `AsyncImage` or the public disk cache.

## Persistence and Backend Contracts

- Supabase Auth persists the session through the SDK.
- PostgreSQL, RLS, reviewed public views, and RPCs are the source of durable domain data.
- Local `UserDefaults` is for device preferences/read markers, not canonical domain records.
- Public images use a bounded cache; private signed chat content must remain ephemeral/authenticated.
- Apply migrations in order. Add a new migration for any contract change; never edit an applied migration.

## Adding a New Feature

1. Put domain-specific files under `Features/<Feature>/Models`, `Services`, `ViewModels`, and `Views` as needed. Do not create empty layers.
2. Choose one owner for each query/result and document its lifetime: screen, tab, account, or application.
3. Put Supabase/RPC/Storage operations in a service or repository, not in the View.
4. Assemble async results before publishing; use request/account guards and cancellation checks.
5. Reuse a Shared component only when the domain meaning matches. Promote a component after a second real consumer appears.
6. Add database changes as forward migrations with RLS, rollback/production-order notes, and tests.
7. Add target membership, tests, and relevant documentation; run the commands in `AGENTS.md`.
