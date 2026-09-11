# Cheese Share Worker

Cloudflare Worker for Cheese public post sharing, universal-link verification, and web fallback pages.

It now also processes queued real push notifications for:

- direct messages
- group messages
- forum post comments
- forum post likes

## What It Handles

- `https://cheeseapp.org/apple-app-site-association`
- `https://cheeseapp.org/.well-known/apple-app-site-association`
- `https://cheeseapp.org/posts/{kind}/{postId}`
- `https://www.cheeseapp.org/*` -> `https://cheeseapp.org/*`

It now also fetches real post metadata from Supabase for:

- `secondhand_posts_view`
- `forum_posts_view`

Supported post kinds:

- `secondhand`
- `forum`

It also generates fallback OG preview images for posts without a native image:

- `https://cheeseapp.org/og/{kind}/{postId}.svg`

## Local Commands

```bash
npm install
npm run dev
npm run check
```

## Local-First Workflow

Edit the Worker locally in this folder, not in the Cloudflare code editor.

Typical flow:

```bash
cd /path/to/CheeseApp-Clean/cheeseapp-share-worker
npm install
npm run check
npm run deploy
```

Why:

- local files are easier to split, review, and version
- `wrangler deploy` pushes the local project to the same Cloudflare Worker
- you do not need to keep manually copy-pasting giant files into the browser editor

If you still want to use the Cloudflare editor occasionally, treat it as emergency hotfix only.

## Deploy

```bash
npm install
npm run deploy
```

Then add a Cloudflare Worker secret.

Configure the non-privileged deployment variables in Cloudflare or your local
`.dev.vars` (which must not be committed):

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`

If you use a per-Worker secret/variable, set:

```bash
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx wrangler secret put APNS_AUTH_KEY
```

Use your Supabase service-role key and the full Apple `.p8` auth key there. Do not commit credential values to `wrangler.toml` or source files.

If you use Cloudflare **Secrets Store** instead of per-Worker secrets, bind the secret with:

- Binding / Variable name: `SUPABASE_SERVICE_ROLE_KEY`
- Secret name: your stored secret entry

This Worker supports both:

- direct Worker secrets (`env.SUPABASE_SERVICE_ROLE_KEY`)
- Secrets Store bindings (`await env.SUPABASE_SERVICE_ROLE_KEY.get()`)

For APNs you also need these vars/secrets:

- `APPLE_TEAM_ID`
- `APNS_KEY_ID`
- `APNS_AUTH_KEY`
- optional `APP_BUNDLE_ID`

Then attach the Worker to:

- `cheeseapp.org/*`
- `www.cheeseapp.org/*`

The Worker also has a 1-minute cron trigger to drain the push queue.

## DNS

Add these Cloudflare DNS records and keep them proxied:

- `A  @    192.0.2.1`
- `CNAME www -> cheeseapp.org`

## Notes

- The current landing pages use real Supabase-backed titles/descriptions where public data is available.
- They avoid forcing desktop browsers into `cheeseapp://...`, which caused blank/error pages.
- Second-hand and forum posts can surface real preview images from their first image.
- Because Cheese post visibility is now `authenticated`-gated in Supabase RLS, real share metadata requires the Worker to read with `SUPABASE_SERVICE_ROLE_KEY` instead of the publishable anon key.
