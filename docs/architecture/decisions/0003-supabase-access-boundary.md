# ADR-0003: Supabase Access Boundary

Status: Accepted, partially implemented

Date: 2026-07-22

## Context

The app currently mixes Supabase access across services, view models, and SwiftUI views. This works for a small codebase, but it makes schema changes risky because UI files can contain persistence, rollback, and RPC behavior.

## Decision

Future database access must go through a feature service or repository boundary.

Views should not contain raw Supabase table, RPC, storage, or realtime queries. Exceptions are temporary legacy paths being actively migrated or infrastructure lifecycle code that has no business-rule content.

`SupabaseManager` remains a thin client wrapper. It must not become a query god object.

## Alternatives Considered

- Allow views to query Supabase directly: rejected because it creates hidden coupling and makes backend changes harder to test.
- Move all queries into `SupabaseManager`: rejected because that would create a central god service.
- Add a large generic repository for all post types: rejected because feature-specific logic would still mix together.

## Consequences

Positive:

- Feature behavior becomes easier to test.
- Schema changes have fewer UI touch points.
- New modules have a clear place for database code.

Negative:

- Existing direct-view queries must be migrated gradually.
- Some files will need small adapter layers before they become cleaner.

## Affected Modules

- `Features/Secondhand/Views/CreateSecondhandView.swift`
- `Features/Forum/Views/CreateForumView.swift`
- `Features/Search/Views/SearchView.swift`
- `Features/Profile/Views/ProfileView.swift`
- `Features/Profile/Views/UserPostsView.swift`
- `Features/Home/Views/HomeView.swift`
- Feature services and repositories

## Migration Plan

1. Move Secondhand create persistence into `SecondhandService` or a repository.
2. Move Forum create persistence into `ForumService` or a repository.
3. Extract `SearchService` for post/profile search and follow actions.
4. Extract profile settings, follow, and favorite repositories from `ProfileView`.
5. Add lightweight checks that flag new raw Supabase access from views.

## Validation Plan

- Run a direct Supabase access scan for feature views.
- Add focused unit tests for create/search/profile repositories where possible.
- Build app and test bundle after each extraction.
