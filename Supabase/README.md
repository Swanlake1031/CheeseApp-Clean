# Supabase Schema Workflow

This directory is the source of truth for the Cheese backend contract.

## Layout

- `migrations/` — append-only ordered schema changes
- `tests/database/` — pgTAP database contract tests
- `functions/` — Supabase Edge Functions
- `config.toml` — local Supabase CLI configuration
- `rebuild_public_and_bootstrap.sql` — destructive public-schema reset helper
- `seed.sql` — optional development/test data

## Current Product Contract

The shared post types are `secondhand` and `forum`. Migration 20260906203031
removes courses, reviews, professors, outlines, and their dedicated PDF bucket.
Migration 085 removes Ride/Team/Carpool contracts,
migration 127 removes Rent, and migration 128 removes geolocation contracts.
Migration 140 rejects Secondhand likes; bookmarks remain supported.

Earlier migrations retain retired terms because migration history is
immutable. They are not evidence that those features remain active.

## Local Workflow

Use Supabase CLI against a local/throwaway project:

```sh
supabase start
supabase db reset --local --version 195
supabase storage rm --local --experimental --recursive --yes ss:///course-outlines
supabase migration up --local
supabase test db
```

The two-phase reset is required because immutable historical migrations create
the retired course bucket. Remove it through the Storage API before applying
the retirement migration; direct SQL deletion of Storage objects is forbidden.
Never run a reset against production.

If a throwaway remote schema must be rebuilt manually, follow
`RESET_INSTRUCTIONS.md`. Apply every migration in filename order through the
latest file; never stop at a historical milestone copied from old notes.

## Change Rules

- Add a new numbered migration; do not edit an applied migration.
- Include RLS/grant behavior and a database test for contract changes.
- Destructive migrations must document deleted data, backup needs, rollback
  limits, and production order in the migration header.
- Do not expose `service_role`, APNs, dispatch, or other privileged credentials
  to the iOS app or repository.
- Validate client decoding, share-worker behavior, and migrations together when
  a post type or public view changes.

## Deployment

Review the complete pending migration range, backups, and destructive headers,
then use the normal Supabase migration workflow (for example `supabase db push`)
against the intended project. Confirm the target project before any command.

The share/push/lifecycle worker also depends on reviewed database RPCs and
privileged deployment secrets. See `../cheeseapp-share-worker/README.md` and
`../HANDOFF.md`.
