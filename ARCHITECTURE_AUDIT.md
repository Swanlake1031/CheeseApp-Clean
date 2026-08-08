# Cheese App Architecture Audit

Date: 2026-08-08  
Audit source: `/Users/timonayf/Desktop/GF` on `recovery/2026-07-28-reconstructed`  
Clean-baseline workspace: `/Users/timonayf/Desktop/CheeseApp-Clean`

## Executive Summary

The current application is a feature-oriented SwiftUI app backed by Supabase. It does not need a framework rewrite. The strongest existing boundaries are the service-mediated database access, account-scoped singleton reset/generation guards, keyset pagination, feature-owned publishing workflows, canonical `PostInteractionStore`, private chat media contract, and centralized public-image cache.

No current P0 crash, corruption, or exposed secret was confirmed. The baseline app target builds, and the share worker syntax check passes before cleanup.

The highest-confidence structural issue is Home publication: fetches are assembled in the background, but the assembled result is still committed through many independent `@Published` properties. That is not an atomic visible snapshot and can trigger multiple feed-wide invalidations. The cleanup should replace those fields with one published content snapshot while retaining separate loading/mutation state.

The supplied brief named Rentals/Housing and Secondhand likes, but the actual app and forward migrations had removed those contracts. The product decision is now explicit: neither Rentals/Housing nor Secondhand likes are part of this baseline, and historical implementations must not be restored.

## Cleanup Outcome

The cleanup implemented A-01, A-03, A-04, A-05, A-06, A-07, A-11, A-12, and A-13. A-02 and A-15 are resolved as explicit product boundaries: do not restore Rentals/Housing or Secondhand likes. Broad work in A-08/A-09/A-10 remains deliberately deferred. The post-clean architecture is documented in `ARCHITECTURE.md`; operational handoff details are in `HANDOFF.md`.

## Audit Method

The audit inspected:

- the app entry point, root/tab navigation, deep links, notification routing, and swipe/drawer gestures;
- every feature directory, service, model, view model, and Xcode target membership;
- Home lifecycle, refresh assembly, recommendation ordering, detail routing, and interaction ownership;
- Forum, Secondhand, Courses, Search, Profile, Chat, System Messages, editing, and sharing flows;
- all `@StateObject`, `@ObservedObject`, `@Published`, `.task`, `.onAppear`, `.refreshable`, `Task`, `async let`, request-ID, account-generation, and pagination patterns;
- direct Supabase usage from Views (none found);
- image loading/cache implementations and `AsyncImage` use;
- live and retired product terms across app, tests, worker, schema history, seed, and docs;
- dead type/file candidates by repository-wide reference count, followed by direct reference checks;
- sensitive filenames and strict credential/private-key markers without printing credential values;
- the Xcode project, Swift package lock, build, worker check, and available simulator inventory.

The original repository was not edited, staged, committed, or pushed during the audit.

## Actual System Map

```text
CheeseAppApp
  ├─ AuthService.shared (session/profile identity)
  ├─ PostDeepLinkCoordinator (post deep links)
  ├─ AppNotificationRouter (push navigation intent)
  └─ MainTabView
      ├─ HomeView + HomeViewModel
      ├─ SearchView + SearchViewModel
      ├─ ChatListView + ChatService
      ├─ ProfileView + profile services
      └─ CreatePostView (full-screen composition)

Feature View
  → feature state / ObservableObject service
  → feature service or repository
  → Supabase RPC, reviewed view, Realtime, or Storage
  → PostgreSQL RLS / SECURITY DEFINER contract
```

### State ownership observed

| State | Actual owner | Notes |
| --- | --- | --- |
| Authenticated identity/session | `AuthService.shared` | Clear app owner; transition handlers synchronously reset account-scoped services. |
| Home content | `HomeViewModel` owned by `MainTabView` | Correct lifetime, but content is spread across many published fields. |
| Likes/bookmarks | `PostInteractionStore.shared` | Canonical viewer-relative interaction state; feature models supply fallbacks only. |
| Forum list query | `ForumChannelFeedModel` | Screen/query snapshot; `ForumService` owns external operations and a compatibility list cache. |
| Forum detail/comments | `ForumDetailView` local detail snapshot | Reloaded coherently; interactions come from `PostInteractionStore`. |
| Secondhand list | `SecondhandService.shared` | Account-scoped list/pagination owner; interaction store is canonical for favorite display. |
| Course catalog | `CourseDiscoveryViewModel` | Screen-owned, load-once unless forced. |
| Course reviews | `CourseReviewViewModel.snapshot` | One coherent course snapshot plus screen draft/filter state. |
| Search query/results | `SearchViewModel` | Debounced/cancellable, account-scoped, request guarded; currently declared inside the View file. |
| Profile identity | `AuthService.currentUser` | Profile view does not maintain a second user model. |
| Profile activity | `ProfileActivityService` per activity page | Query-specific pagination and privacy state. |
| Conversation lists | `ChatService.shared` | Account reset and generation guarded. |
| Room messages | room lifecycle controller/view model | Screen/session scoped with cancellation and stale-result guards. |
| System notifications | `SystemMessageService` / `SystemMessageViewModel` | Current notification inbox. |
| Public images | `RemoteImageCache.shared` | Bounded memory/disk cache, request coalescing, background downsampling. |
| Private chat images | chat media service/view state | Private bucket, signed transport URLs, ephemeral authenticated loading. |

## Findings

### P0

No P0 finding was confirmed in the audited working tree.

Strict scans found no committed private key material, service-role credential value, GitHub token, Stripe secret, certificate, provisioning profile, or `.env` file. Source files contain environment-variable names and PEM header strings used to parse externally supplied credentials; those are not embedded credential values. A Supabase publishable client key and project URL are hardcoded; publishable keys are not privileged secrets, but they should still be removed from the clean engineering baseline as configuration hygiene (A-07).

### P1

#### A-01 — Home refresh is fetched as a snapshot but not published atomically

- **Problem:** Home builds the next feed in local values, then assigns `recommendationSeed`, four content arrays, follow IDs, four resolved flags, two model dictionaries, and interaction state separately.
- **Root cause:** The earlier progressive loaders were converted to background snapshot fetchers, but the UI storage remained a set of independent `@Published` properties.
- **Affected files:** `Features/Home/ViewModels/HomeViewModel.swift`; `Features/Home/Views/HomeView.swift`.
- **Feature:** Home feed, Home return lifecycle, refresh, following feed.
- **Runtime/user impact:** One successful refresh can emit several object-change events and temporarily expose mixed old/new fields to computed sections. This increases feed-wide rendering and does not fully satisfy old-snapshot → one commit → new-snapshot semantics.
- **Recommended solution:** Publish one `HomeContentSnapshot` containing visible content, lookup maps, resolved flags, follow IDs, and recommendation seed. Keep loading flags separate so background refresh does not clear content.
- **Fix during cleanup:** **Yes.** This is contained, behavior-preserving, and directly addresses the reported lifecycle problem.

#### A-02 — Product documentation says Rentals/Housing is active, but the actual product contract removed it

- **Problem:** The requested/current product boundary names Rentals/Housing, while the current app has no Rent folder or route, `PostKind` has only Forum and Secondhand, Search has no Rent category, and migration 127 removes the Rent module.
- **Root cause:** Product documentation and agent guidance did not keep pace with the later forward migration and app removal.
- **Affected files:** `AGENTS.md`, the historical root `README.md`, `Core/Models/PostKind.swift`, `Features/Create/Views/CreatePostView.swift`, `Features/Search/Views/SearchView.swift`, `Supabase/migrations/127_remove_rent_module.sql`.
- **Feature:** Product boundary, Create, Search, Home, database release contract.
- **Runtime/user impact:** A developer can incorrectly assume housing exists and either advertise unavailable behavior or attempt to rebuild against a schema that intentionally removed it.
- **Recommended solution:** Record Rentals/Housing as outside the product boundary and prevent historical migrations or empty folders from being treated as live architecture.
- **Fix during cleanup:** **Yes, documentation/guardrails only.** The product decision is not to restore Rentals/Housing; no schema change is required.

#### A-03 — Root navigation ownership is split across an outer stack and per-tab stacks

- **Problem:** `CheeseAppApp` wraps authenticated content in a `NavigationStack` for deep links, while Home, Search, Chat, Profile, create, and several sheets create their own stacks. Custom swipe-back enabling is applied at multiple levels.
- **Root cause:** Deep-link routing was added at the app root after tabs had already established independent navigation histories.
- **Affected files:** `CheeseAppApp.swift`, `MainTabView.swift`, `HomeView.swift`, `ProfileView.swift`, `View+Extensions.swift`, and feature roots.
- **Feature:** Global navigation, deep links, tabs, back gestures.
- **Runtime/user impact:** Ownership is hard to reason about; future destinations can land on the wrong stack, and gesture policy must inspect nested controllers. Current primary paths compile and are guarded, but expansion is risky.
- **Recommended solution:** Make `MainTabView` the owner of one stack per persistent tab. Global post routes select Home and publish into the Home stack; chat notification routes select Chat. Remove the authenticated outer stack and feature-root stacks.
- **Fix during cleanup:** **Yes (2026-08-08 follow-up).** A pure route-to-tab policy and assertions were added. The app and test bundle compile; signed-in device execution remains necessary because the available CoreSimulator failed before launching XCTest with Mach error -308.

#### A-15 — Requested Secondhand likes conflict with the shipped database contract

- **Problem:** The requested product description says Secondhand supports likes and bookmarks, but the current UI disables Secondhand likes and migration 140 deletes existing Marketplace likes and installs a trigger that rejects new ones.
- **Root cause:** Product expectations changed after the destructive “Secondhand disallows likes” migration, or the handoff brief was written from an older contract.
- **Affected files:** `Features/Home/Views/HomeView.swift`, `Features/Home/ViewModels/HomeViewModel.swift`, `Features/Secondhand/Services/SecondhandService.swift`, `Supabase/migrations/140_secondhand_disallows_likes.sql`.
- **Feature:** Secondhand/Home interactions.
- **Runtime/user impact:** Bookmarks work, but a client that re-enables likes would fail against the current backend and could display permanently inconsistent counters.
- **Recommended solution:** Keep Secondhand likes outside the product boundary, retain bookmarks, and prevent the old like implementation from being restored from migration history.
- **Fix during cleanup:** **Yes, documentation/guardrails only.** No backend or UI behavior is changed; migration 140 remains authoritative.

### P2

#### A-04 — Forum page loads publish interaction revisions once per post

- **Problem:** `ForumService.seedInteractionStates` loops over results and invokes the single-item interaction merge for every post.
- **Root cause:** The interaction store later gained a batch API, but Forum kept the older loop.
- **Affected files:** `Features/Forum/Services/ForumService.swift`, `Core/Services/PostReactionService.swift`.
- **Feature:** Forum list/search/detail and any mounted observer of post interactions.
- **Runtime/user impact:** A 24-item page can increment `revision` and invalidate observers up to 24 times even though one API response produced one logical state update.
- **Recommended solution:** Build `[PostInteractionStore.Update]` and call the batch merge once.
- **Fix during cleanup:** **Yes.** Low risk and directly measurable by revision behavior.

#### A-05 — Group creation has duplicated candidate UI and one path performs serial N+1 block checks

- **Problem:** Inbox group creation and “convert current chat to group” each implement loading, selection, default naming, creation, error state, and a member row. The inbox path additionally calls `fetchBlockRelation` once per candidate.
- **Root cause:** The contextual group flow was added separately instead of reusing the canonical member row and the visibility contract already enforced by `get_mutual_follow_profiles`/`profile_public_view`.
- **Affected files:** `Features/Chat/Views/ChatRoomGroupCreationViews.swift`, `Features/Chat/Views/Components/ChatGroupCreationViews.swift`, `ChatFollowSearchViews.swift`, `ChatService.swift`, migration 102.
- **Feature:** Generic group chat.
- **Runtime/user impact:** Candidate presentation can drift, one path bypasses the image cache through `AsyncImage`, and the inbox can issue up to 200 serial relationship requests.
- **Recommended solution:** Reuse the canonical `MutualFollowSelectionRow` and trust the reviewed mutual-profile query's block visibility instead of client N+1 checks. Keep the two sheets because their minimum-member/context behavior genuinely differs.
- **Fix during cleanup:** **Yes.** Consolidate the meaningful shared component and remove redundant calls without building a generic mega-sheet.

#### A-06 — Obsolete Forum bell notification stack coexists with System Messages but has no runtime route

- **Problem:** A full Forum notification preview service, cache/view model, sheet, account transition wiring, and tests remain compiled, but no runtime view opens or observes the sheet/view model. System Messages is the active inbox.
- **Root cause:** The system inbox replaced the Forum-specific bell without removing the previous implementation.
- **Affected files:** `Features/Forum/Views/ForumNotificationViews.swift`, notification sections of `ForumService.swift`, `CheeseAppApp.swift`, `ProfileSocialServiceTests.swift`, Xcode project.
- **Feature:** Notifications/Forum.
- **Runtime/user impact:** Roughly 500 lines of inaccessible state and direct query logic create a false second notification architecture and unnecessary account wiring.
- **Recommended solution:** Delete the unreachable UI/view model, its service-only preview APIs/models, and its obsolete test.
- **Fix during cleanup:** **Yes.** Reference search confirms no runtime consumer.

#### A-07 — Backend project configuration is hardcoded into app and worker source

- **Problem:** The iOS config and `wrangler.toml` contain a concrete Supabase project URL and publishable key.
- **Root cause:** Development convenience defaults became committed runtime defaults.
- **Affected files:** `Core/Config/SupabaseClient.swift`, `cheeseapp-share-worker/wrangler.toml`, setup documentation.
- **Feature:** Infrastructure/security hygiene.
- **Runtime/user impact:** The key is publishable rather than privileged, but a fork/build can silently talk to the wrong backend and repository policy cannot prove all environment selection is intentional.
- **Recommended solution:** Require Scheme/environment or Info.plist configuration for the app; inject worker values using local/deployment variables or secrets. Keep safe test-only placeholders so unit tests do not require production configuration.
- **Fix during cleanup:** **Yes.** No backend schema or API contract change is required.

#### A-08 — Large files still combine unrelated change reasons

- **Problem:** `ForumService` (~1,925 lines), `ChatService` (~1,632), `AuthService` (~1,544), `ForumDetailView` (~1,417), `SearchView` (~1,331), `ProfileSettingsViews` (~1,025), `HomeView` (~1,013), and `HomeViewModel` (~997) are concentrated ownership points.
- **Root cause:** Rapid feature evolution accumulated view components, view models, transport DTOs, and orchestration in the first available file.
- **Affected files:** Listed above.
- **Feature:** Cross-cutting maintainability.
- **Runtime/user impact:** Not a bug by itself, but review scope and accidental coupling are high. `SearchView.swift`, for example, contains the View, ViewModel, models, layouts, and cards.
- **Recommended solution:** Split only along proven ownership boundaries when those areas are next modified (for example Search state vs Search presentation; Forum publishing vs comments vs list queries).
- **Fix during cleanup:** **Partially.** Removing confirmed dead Forum notification and Home loader blocks reduces concentration. Broader splits are deferred to avoid noisy movement.

#### A-09 — Same-domain cards have multiple presentation implementations

- **Problem:** Forum content is rendered by `ForumPostCardView`, Home's `ContentCardView` path, profile activity rows, and user-post cards; Secondhand has list, compact Home, search, profile, and favorite/detail rows. The implementations do not all consume the same presentation model.
- **Root cause:** Each screen optimized its own density before domain presentation contracts were named.
- **Affected files:** `ForumPostCardView.swift`, `ContentCardView.swift`, `HomeView.swift`, `SecondhandListView.swift`, `ProfileActivityView.swift`, `UserPostsView.swift`, `SearchView.swift`.
- **Feature:** Home, Forum, Secondhand, Profile, Search.
- **Runtime/user impact:** Formatting and metric behavior can drift. Interaction values are protected by the canonical store, but visual/business presentation still has multiple owners.
- **Recommended solution:** Keep full, compact, and search variants distinct, but share narrow domain subcomponents/presentation values (author header, price/condition summary, interaction bar) as future UI work touches them.
- **Fix during cleanup:** **No broad card rewrite.** Layout-preserving cleanup only. Courses already use one `CourseSummaryCard` path; Home currently links to Courses rather than rendering a duplicate course card.

#### A-10 — Global feature services publish multiple related list fields independently

- **Problem:** Forum, Secondhand, Chat, System Messages, and some Profile services each expose content, loading, pagination, error, and account fields as separate publishers.
- **Root cause:** Observable services grew incrementally around SwiftUI screens.
- **Affected files:** feature service/view-model files with multiple `@Published` fields.
- **Feature:** Forum, Secondhand, Chat, Profile, Notifications.
- **Runtime/user impact:** Related transitions can cause multiple invalidations. Unlike Home, current refresh paths generally retain existing content and use request/account guards, so no correctness failure was confirmed.
- **Recommended solution:** Adopt snapshot state per feature when a concrete inconsistency or render problem is being fixed; do not create a global store.
- **Fix during cleanup:** **Deferred except Home.** Home is the confirmed hot path; broad conversion would be destabilizing.

### P3

#### A-11 — Obsolete progressive Home loaders remain compiled after snapshot refresh replacement

- **Problem:** `loadHomeFeaturedPosts`, `loadFeaturedPosts`, `loadFollowingPosts`, and `loadForumPosts` mutate UI fields progressively but are no longer referenced.
- **Root cause:** The newer `fetch*Snapshot` methods were added without deleting the old implementation.
- **Affected files:** `Features/Home/ViewModels/HomeViewModel.swift`.
- **Feature:** Home.
- **Runtime/user impact:** No current runtime call, but they suggest two valid refresh architectures and make future regressions likely.
- **Recommended solution:** Delete the obsolete methods after the snapshot conversion.
- **Fix during cleanup:** **Yes.** Repository-wide reference check confirms they are private and unused.

#### A-12 — Confirmed unreachable components/services remain in the target

- **Problem:** Standalone or self-preview-only code includes `SectionHeaderView`, `CustomButton`, the old Forum comment row file, the legacy Favorite Posts screen/service, `ProfileMenuItem`, unused edit DTOs, and an unused `PostImageRow`.
- **Root cause:** Replacements were added while old target members remained.
- **Affected files:** Home/Shared/Forum/Profile/Secondhand files and the Xcode project.
- **Feature:** General cleanup.
- **Runtime/user impact:** False architectural options, extra compile surface, and misleading discoverability.
- **Recommended solution:** Remove only symbols/files with confirmed zero runtime/test references and update target membership.
- **Fix during cleanup:** **Yes.** Preserve preview/test-only code when it documents a still-supported component; delete only confirmed replacements.

#### A-13 — Historical/recovery artifacts are mixed with deployable source

- **Problem:** The original root contains a schema backup, recovery pointer, tracked Xcode user state, whitepaper output/tools, an old HTML prototype, dependencies, `.DS_Store`, and an unrelated nested website Git repository.
- **Root cause:** Recovery and design work occurred in the same directory as the app.
- **Affected files:** Original repository root and ignored/local folders.
- **Feature:** Repository hygiene.
- **Runtime/user impact:** A handoff clone can exceed 1 GB and obscure the deployable surfaces.
- **Recommended solution:** The clean repository should include the iOS app, Supabase, share worker source/tests, relevant scripts/docs, and no recovery export, nested repo, dependencies, or Xcode user data.
- **Fix during cleanup:** **Yes, only in the new repository.** The original recovery source remains untouched.

#### A-14 — Existing README and architecture docs describe superseded modules

- **Problem:** The historical README says Rent is active and Courses is not independent, both contradicted by current source/migrations.
- **Root cause:** Documentation was not updated after migrations 89–150 and later app removals.
- **Affected files:** root README and older architecture/audit reports.
- **Feature:** Developer onboarding.
- **Runtime/user impact:** New developers start with the wrong system model.
- **Recommended solution:** Replace the clean-repo README and add architecture/handoff docs based on the post-cleanup source; keep forward migration history intact.
- **Fix during cleanup:** **Yes.** Historical audit reports are not copied into the clean baseline.

## Prioritized Cleanup Plan

### P0

- None.

### P1

1. Convert Home visible content to one published snapshot and delete progressive loaders.
2. Record Rentals/Housing as outside the product boundary; do not invent a replacement module.
3. Record Secondhand likes as outside the product boundary; do not reverse migration 140.
4. Consolidate persistent navigation to one stack per tab and route global intents through an explicit tab policy.

### P2

1. Batch Forum interaction seeding.
2. Consolidate group-member rows and remove serial N+1 block checks.
3. Delete the unreachable Forum bell architecture.
4. Remove hardcoded backend project configuration.
5. Reduce large-file concentration only where dead blocks can be removed without movement.

### P3

1. Remove confirmed dead files/symbols and Xcode user state from the new repository.
2. Exclude recovery exports, nested repos, dependencies, generated output, and obsolete prototypes.
3. Replace stale developer documentation.

## KEEP

- Service/repository-mediated Supabase access; Views contain no raw database calls.
- `AuthService` account-transition composition and per-service generation guards.
- `PostInteractionStore` as the canonical like/bookmark state, with domain models as fallbacks.
- Feature-owned Forum and Secondhand publishing workflows and durable media cleanup contracts.
- Private chat media, signed URLs, exact scope/path identity, and no public fallback.
- Keyset pagination and indexed search contracts.
- Course review RPC snapshot and professor UUID identity.
- `HomeViewModel` lifetime owned by `MainTabView`, request de-duplication, five-minute cache policy, and old-content retention on refresh failure.
- Centralized `RemoteImageCache` for public images, bounded cache sizes, coalescing, and background downsampling.
- Generic group chat; do not confuse it with retired Team-Up/Group-Finding.
- Forward-only migration history, including historical retired-feature names.

## FIX

- Home atomic content publication.
- Forum batch interaction updates.
- Group-member component/candidate loading duplication.
- Unreachable Forum bell notification stack.
- Hardcoded backend project configuration.
- Root/per-tab navigation ownership and explicit global route targeting.
- Confirmed dead files/symbols and repository artifacts.
- Current architecture, handoff, and setup documentation.

## DEFER

- Broad service snapshot conversion outside Home.
- Large-scale file/folder movement.
- Full cross-feature card redesign.
- Splitting large services without accompanying feature work and tests.
- Production migration/deployment changes.

## DELETE

- Unreferenced progressive Home loaders.
- Unreachable Forum bell UI/view model/service preview logic and its obsolete test.
- Confirmed dead shared/Home/Forum/Profile components and DTOs.
- The legacy Favorite Posts screen/service superseded by Profile Activity.
- Xcode user data and local/generated artifacts from the new repository.
- Recovery backup/pointer, old whitepaper output/tools, obsolete prototype, dependency directories, and unrelated nested website repository from the new baseline only.

## Pre-Cleanup Verification Evidence

- iOS app target build: **PASS** using a generic iOS Simulator destination and isolated DerivedData.
- Share worker syntax check: **PASS**.
- Available concrete simulator: `CheeseApp-H2-Tests-2` (iOS 26.3), shutdown at audit time.
- Direct Supabase access in feature View files: **0 matches**.
- Secondhand comment UI/infrastructure in the iOS feature: **0 matches**.
- Original Git remote: `https://github.com/Swanlake1031/GF_RANDOM_LUNCH.git`; not changed or pushed.
