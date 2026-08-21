# Cheese Content Studio

An isolated, desktop-first internal web application for publishing and managing
Cheese forum and secondhand content. It is **not** bundled into the iOS app and
does not replace any public Cheese surface.

## Boundary

The browser only holds a normal Supabase user session and the public
Supabase configuration. Every Content Studio request goes to the separate
`cheeseapp-content-studio-api` Worker, which verifies the user and their
`content_studio_roles` entry before it forwards the caller's JWT to the
existing production RPCs.

That means the existing App remains the source of truth for:

- forum board, anonymous-post, media, visibility, mention, and notification rules;
- secondhand category, condition, image, lifecycle, and transaction rules;
- image finalization and cleanup via `prepare_post_media_operation`,
  `mark_post_media_uploaded`, and the publish/edit RPCs.

## Local configuration

Copy `public/config.example.js` to `public/config.js` and fill only:

- `supabaseUrl`
- `supabasePublishableKey`
- `apiBaseUrl`
- `oauthRedirectUrl` (the deployed HTTPS CMS URL)

`config.js` must never contain the service-role key. The frontend can be served
as a static site, for example:

```sh
python3 -m http.server 8788 --directory cheeseapp-content-studio/public
```

Use the paired API Worker locally at `http://localhost:8787` and set its
`CONTENT_STUDIO_ORIGIN=http://localhost:8788`.

## Deployment plan (not performed)

1. Apply migration `181_content_studio_access_and_drafts.sql`.
2. Add each authorized user UUID to `public.content_studio_roles` through a
   restricted operational SQL session; do not expose a role-management page in
   V1.
3. Deploy `cheeseapp-content-studio-api` as a distinct Cloudflare Worker and set
   its three Supabase values as Worker secrets.
4. Deploy `cheeseapp-content-studio` as the static-asset Worker on
   `studio.cheeseapp.org`. It forwards only `/api/*` requests to the separate
   API Worker through a Cloudflare service binding.
5. Set the API Worker's `CONTENT_STUDIO_ORIGIN` to that exact site origin.
6. In Supabase Auth URL Configuration, add the same site URL to **Redirect URLs**.
   CMS users can then use the Google identity already linked to their Cheese
   account; no separate CMS password is required.

The Pages deployment may include the URL and publishable key in `config.js`;
they are designed to be public. The Worker service-role key stays server-only.
