# Cheese Content Studio API

This Worker is the authorization boundary for the standalone Content Studio.
It intentionally does not share the public share-worker process or its routes.

## Required secrets

Set these with `wrangler secret put` during deployment:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

`CONTENT_STUDIO_ORIGIN` is a non-secret Worker variable and must be the exact
Pages origin in production.

## Request model

1. The browser signs in through Supabase Auth using only the publishable key.
2. The browser sends its access token to this Worker.
3. The Worker validates that token through Supabase Auth and looks up the
   user in `content_studio_roles` using its server-only service credential.
4. For posts, the Worker forwards the **user's own token** to the existing
   authenticated publishing/editing/hiding/deleting RPCs. It never creates a
   post with service-role identity.

This preserves post ownership, current RLS/RPC validation, media staging,
notifications, and cleanup behavior already used by the iOS app.

## Validation

```sh
npm run check --prefix cheeseapp-content-studio-api
node --check cheeseapp-content-studio/public/app.js
```
