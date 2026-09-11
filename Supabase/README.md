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

For the App Store regression fixture, run from the repository root:

```sh
scripts/verify-app-store-db.sh
```

This creates a separate local project and replays every migration without
rewriting history. Migration 133 requires an active official profile, so the
script first applies through 132 and inserts a synthetic local official account.
It then applies through 195, removes the historical empty `course-outlines`
bucket through the Storage API, applies the remaining migrations and current
seed, and checks the selected security/contract suites. It never resets a linked
production database or copies production backups. Local CLI output stays in a
private temporary log. The local Supabase image's `supautils` preload crashes on
auth-schema privilege probes; only that preload is disabled in the test owner
connection. Tests still exercise actual `SET ROLE`, grants and RLS.

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
