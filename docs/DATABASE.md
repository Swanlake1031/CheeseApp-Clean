# Cheese App Database

This document describes the current product-facing database shape after retiring
Ride/Carpooling, Team-Up, Rent, and all device/IP geolocation features.

## Current Product Modules

The shared `posts` table now supports these user-facing post types:

| `posts.type` | Module |
|---|---|
| `secondhand` | Second-hand marketplace |
| `forum` | Community forum |

Courses and professor ratings use their own course, professor, outline, term,
review, and aggregate contracts; they are not represented as post types.

## Core Tables

| Table | Purpose |
|---|---|
| `profiles` | Public user profile data linked to Supabase Auth users |
| `posts` | Shared post identity, owner, title, description, status, visibility, metrics, and search vector |
| `post_images` | Ordered images attached to posts |
| `favorites` | Saved posts |
| `likes` | Forum post likes; migration 140 rejects Secondhand likes |
| `comments` | Forum comments and replies |
| `conversations` / `messages` | Direct messages |
| `chat_groups` / `chat_group_members` / `group_messages` | Generic group chat |
| `user_reports` | User and content reports |
| `user_follows` / `user_blocks` | Social graph and privacy controls |
| `user_push_tokens` / `push_notification_jobs` | Push notification registration and queue |

## Module Detail Tables

| Table | Key Relationship | Notes |
|---|---|---|
| `secondhand_posts` | `id` references `posts(id)` | Marketplace price, category, condition, stock/sold and expiry fields |
| `forum_posts` | `id` references `posts(id)` | Required board relationship, comment flags, pinned/locked state, metrics |

The app reads module data mainly through:

| View / RPC | Purpose |
|---|---|
| `secondhand_posts_view` | Marketplace list/detail payload |
| `forum_posts_view` | Forum list/detail payload |
| `search_posts(p_query, p_category, p_limit)` | Unified search for `market` and `forum` categories |
| `get_user_conversations(...)` | Direct-message inbox |
| `get_user_chat_groups(...)` | Generic group-chat inbox |

## Retired Modules

Migration `085_remove_ride_and_team_modules.sql` removes the live DB surface for:

| Removed Area | Removed Schema |
|---|---|
| Legacy ride posts | `ride_posts`, `ride_participants`, `ride_posts_view`, ride hot/creation/recurrence/estimate functions |
| New carpool framework | `carpool_hubs`, `carpool_corridors`, `carpool_route_templates`, `carpool_trip_instances`, `carpool_bookings`, `carpool_reviews`, route favorites/reports, carpool enum types and helpers |
| Team-Up posts | `team_posts`, `team_members`, `team_posts_view`, `team_posts_manage_view`, team creation/hot/activity-group functions |
| Team-Up chat binding | `chat_groups.source_type`, `source_post_id`, `source_sort_at`, plus Team-Up sourced chat groups |
| Profile-only carpool stats | `profiles.carpool_role`, `carpool_rating_avg`, `carpool_trip_count`, `school_email`, `school_email_verified` |

Old migration files remain in history because Supabase migrations are append-only.
Migration `127` removes Rent, and migration `128` removes device/IP location,
coordinate columns, geo/distance RPCs, location-bearing marketplace contracts,
and PostGIS. Back up before applying either destructive migration.

## Migration Notes

Use Supabase CLI migration workflows where possible:

```bash
supabase db push
```

For a messy throwaway database, `Supabase/rebuild_public_and_bootstrap.sql` can reset `public`, then migrations can be applied in order. Do not run that reset script against production.

## Seed Data

`Supabase/seed.sql` only seeds current modules: profiles, courses, second-hand,
forum, comments, and direct chat.
