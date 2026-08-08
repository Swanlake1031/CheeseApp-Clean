# ADR-0002: Base Post With Feature Detail Tables

Status: Accepted

Date: 2026-07-22

## Context

Cheese App has multiple post-like product modules. They share common behavior such as authorship, images, likes, favorites, reports, comments, search, share links, and chat references, but each module also has different fields.

## Decision

Keep the database model as:

- One shared `posts` table for common post fields.
- One feature detail table per active post type, such as `rent_posts`, `secondhand_posts`, and `forum_posts`.
- Read views such as `rent_posts_view`, `secondhand_posts_view`, and `forum_posts_view`.
- A Swift `PostKind` enum for active post identity.

Do not model future post types only as JSON metadata inside a generic table.

## Alternatives Considered

- One table with many nullable columns: rejected because feature-specific fields leak across modules.
- JSON-only detail data: rejected because validation, search, indexing, and Swift decoding become weaker.
- Fully separate tables without a shared base post: rejected because likes, favorites, images, reports, search, and chat references need a shared post identity.

## Consequences

Positive:

- Shared systems can reference one `posts.id`.
- Feature tables keep module-specific fields separate.
- Database constraints and indexes remain possible.

Negative:

- Adding a new post type currently still touches many app, SQL, and worker files.
- The app needs a better module descriptor/adaptor layer so shared surfaces do not switch on every concrete post type.

## Affected Modules

- Supabase `posts`, `rent_posts`, `secondhand_posts`, `forum_posts`
- Supabase `*_posts_view`
- `PostKind`
- Search, Home, Profile, Deep Links, Share Worker, Chat post-share cards

## Migration Plan

1. Keep existing base/detail schema for the three active modules.
2. Introduce feature-owned repositories for all create/update/delete paths.
3. Add module descriptors or provider protocols before adding a fourth post type.
4. Add a schema/app/worker supported-kind contract test.

## Validation Plan

- Confirm Swift `PostKind`, database `posts.type` constraint, and worker `SUPPORTED_KINDS` agree.
- Decode sample rows from all active `*_posts_view` views.
- Verify Search/Profile/Home/Deep Links can route every supported kind.

