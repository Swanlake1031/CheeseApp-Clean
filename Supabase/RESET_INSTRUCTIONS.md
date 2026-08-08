# Supabase Reset Guide

This process is destructive. Use it only for a new or explicitly disposable
environment. It drops all application data in the `public` schema and cannot
restore it.

## Preferred Local Reset

```sh
supabase db reset
```

This replays the full migration directory and the configured seed against the
local stack.

## Manual Throwaway-Project Reset

1. Confirm the target project is not production and that no data is needed.
2. Run `Supabase/rebuild_public_and_bootstrap.sql` once in SQL Editor.
3. Run every file under `Supabase/migrations/` in filename order through the
   latest migration.
4. Optionally run `Supabase/seed.sql` for development data.
5. Run database contract tests where the environment supports pgTAP.
6. Delete/reinstall the simulator app, sign in with a fresh test account, and
   validate active modules.

Do not use an old “latest migration” number. This repository evolves through
forward migrations, and stopping early can restore retired product kinds or
omit security/privacy contracts.

## Production Rule

Never use the reset script in production. Deploy reviewed forward migrations
only, after following each destructive migration's backup, rollback-limit, and
ordering notes.

