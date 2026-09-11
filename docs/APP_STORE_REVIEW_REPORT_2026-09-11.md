# CheeseApp App Store submission-readiness audit

Audit date: 2026-09-11 (America/Toronto)
Target: `Swanlake1031/CheeseApp-Clean`, release **1.1.0 (55)**
Storefront plan: **Canada and the United States only**; **13+**; optional Gemini is unavailable in this release.

## Current conclusion

**CODEBASE READY — EXTERNAL MANUAL BLOCKERS REMAIN**

A fresh source audit found **P0 = 0** and **repo-fixable P1 = 0**. The remaining P1 items require production credentials, backups, service deployment, App Store Connect data, a working simulator/physical device, or operational evidence. Do not submit build 55 until the external P1 checklist below is closed.

This report keeps source changes, local verification, production verification, and App Store Connect state separate. A passing local test or archive does not by itself prove a deployed service or App Store record is correct.

## Fixed in the codebase

| Area | Severity before fix | Release behavior now | Regression coverage |
| --- | --- | --- | --- |
| Valid session during cold-start timeout | P1 | Auth validation has an 8-second deadline. A transient timeout or 5xx preserves an existing local session; only explicit credential-invalid states reset authentication. Late validation cannot overwrite the deadline result. | `AuthCredentialStoreTests` plus the iOS build-for-testing target. A real signed-in device network-transition test remains external. |
| Optional Gemini | P1 | The iOS release endpoint is blank; the Worker has a source gate (`GEMINI_PROVIDER_RELEASED = false`) plus operational gates. Disabled routes return 404 before auth, parsing, database access, or provider construction. Cron never claims or sends embedding work while disabled. | AI Worker: 62 passing tests. |
| Hidden `@奶酪AI` release surface | P1 | Global/profile/chat search, mention candidates, historical presentation and system-message paths exclude the retired AI identity. | iOS source tests and Worker release-gate tests. |
| Image safety | P1 | Image uploads require a separate media-safety acknowledgement and are reviewed by Cloudflare Workers AI before Storage write. Rejection or provider outage fails closed; text-only flows continue. This is independent of Gemini. | AI Worker media tests and Content Studio: 12 passing tests. |
| Account deletion and local remnants | P1 | Deletion clears authored posts, listings, comments, direct/group message bodies and copied metadata, social/recommendation state, notifications, media receipts and known Storage paths through retryable cleanup jobs. The iOS client clears drafts, account-scoped search, chat/social state and notification counters after deletion. | New SQL suites plus iOS account-isolation tests; database replay still needs an available DB runner. |
| Privacy / legal copy | P1 | Privacy manifest and in-app/public policy cover gender, social graph, marketplace history, selected images and the distinct Cloudflare safety review. Optional Gemini is clearly unavailable. | Manifest lint and public-page tests. |
| Retired surfaces / support contact | P1 | Public rules no longer advertise course, professor, outline, Radar, rentals, ride or WeChat flows. The app, public pages, Content Studio and security contact now use `support.cheeseteam@gmail.com`. | Retired-term scan plus Share Worker: 16 passing tests. |
| Apple credential revocation and nonce failures | P1 | The app stores the opaque Apple user identifier separately, checks the current linked account on launch and on Apple revocation notifications, clears only the matching local session on `revoked`/`notFound`, and surfaces secure-nonce failures instead of crashing. | Apple revocation policy/notification tests and full iOS suite. |
| Moderation removal media | P1 | Removing a post or suspending a user hides the public surface immediately, clears profile media references, and queues exact public Storage objects for retryable worker deletion. Suspended profiles and posts are excluded from public reads and suspended Studio admins lose access. | App Store safety DB regression coverage plus the existing media-cleanup worker contract. |
| Password recovery | P1 | “Forgot Password?” opens a validated reset-email form with loading, generic success, and user-safe error states. | Password-reset form policy regression plus full iOS suite. |

The old `wechat_id` app decoder was removed. Historical database columns and deletion tests remain only to erase legacy data safely; no active iOS surface reads or writes that field.

## Verification completed on this working tree

- `npm run check && npm test` in `cheeseapp-ai-worker`: **62 passed, 0 failed**.
- `npm run check && npm test` in `cheeseapp-share-worker`: **16 passed, 0 failed**.
- `npm run check && node --test test/*.test.js` in `cheeseapp-content-studio-api`: **12 passed, 0 failed**.
- `npm run check` in `cheeseapp-content-studio`: **passed**.
- `xcodebuild ... build-for-testing` for the final iOS source: **passed**.
- Unsigned Release archive for 1.1.0 (55): **passed** production configuration and bundled privacy-manifest validation. It was deliberately built with code signing disabled, so it is not an upload artifact.
- Concrete iOS 26.3 simulator: **290 tests passed, 0 failed** with parallel testing disabled; the previous transparent-PNG failure is covered and now passes.
- `plutil -lint` for the app privacy manifest, `git diff --check`, and `python3 scripts/check-repository-secrets.py`: **passed**.
- GitHub Actions clean runner: Worker checks/tests and the complete Supabase migration replay plus security suites: **passed**. The prior iOS job exposed one Xcode 26 bitmap-fixture failure; the fixture and serialized-test workflow are fixed in this tree, and a clean run for this commit is required.
- Active-source retired-surface scan: no course/Radar/professor/outline/rental/WeChat release surface remains.

### Local environment limits observed

- The dedicated iOS 26.3 simulator now completes the full suite successfully when tests are serialized. The earlier CI clone-launch failure is addressed by the workflow’s `-parallel-testing-enabled NO`; a clean GitHub run after this push remains required.
- `scripts/verify-app-store-db.sh` cannot start local Supabase because Docker’s daemon socket is unavailable. The identical full replay and security suite has passed in GitHub Actions; the local problem is not a database assertion failure.
- Linked `supabase migration list` and `supabase db push --dry-run` now pass and identify seven pending migrations. An actual production push remains intentionally deferred until a verified database and Storage backup exists.
- A protected local logical-dump attempt cannot run through this machine’s unavailable Docker path, and the Storage CLI cannot complete a remote snapshot with the available credentials. No partial backup was retained. Use a Supabase Dashboard physical-backup restore point plus an authorized Storage export before the production push.

## External P1 release checklist

### 1. Deploy and verify the safe Worker changes

**Verified production state:** AI Worker version `ee8d36ad-e7d2-4629-9e82-ba468f8775ea` is deployed. `/health` reports `optionalAIAvailable:false` and `recommendationProviderEnabled:false`; both legacy optional-AI POST routes return 404. Share Worker version `f6b487ea-b4d5-4b70-be60-4ffbd960c67f` is deployed; `/privacy` and `/support` return 200 and show `support.cheeseteam@gmail.com`.

**Completed verification:**

```sh
curl -fsS https://ai.cheeseapp.org/health
# expects optionalAIAvailable:false and recommendationProviderEnabled:false
curl -sS -o /dev/null -w '%{http_code}\n' https://ai.cheeseapp.org/v1/comment-events
# expects 404
curl -sS -o /dev/null -w '%{http_code}\n' https://cheeseapp.org/privacy
curl -sS -o /dev/null -w '%{http_code}\n' https://cheeseapp.org/support
# both expect 200
```

**Canada/US effect:** identical service behavior for both storefronts; no China-specific route or disclosure is required for this release.

### 2. Protect data, migrate production, and retire incompatible clients

Seven linked migrations are pending: `20260911165358`, `20260911184137`, `20260911185013`, `20260911194713`, `20260911202000`, `20260911204500`, and `20260911213000`.

**Remaining action:**

1. Obtain a fresh protected logical database backup and Storage snapshots for `avatars`, `post-images`, `chat-images`, and `content-studio-drafts`; record restoration owner and location without committing secrets or dumps.
2. Restore/verify the production Supabase CLI database credential, run `supabase migration list --linked` and `supabase db push --dry-run`, then apply migrations in order.
3. Retire or force-upgrade all pre-media-boundary clients before migration `20260911185013`: they can otherwise attempt direct Storage uploads that the new RLS policy correctly rejects.
4. Deploy Content Studio API/web after the schema is live, then use a disposable production test account to verify approve/reject/outage image paths, account deletion queue drain, and no Gemini request.

**Verification:** linked migration list has no pending entries; a test account can upload an approved image, cannot publish rejected/unavailable image, and its deletion creates then drains only feature-owned media cleanup jobs.

### 3. Create the App Store distribution signing asset

The locally signed archive is valid but uses an **Apple Development** certificate. A manual App Store export correctly fails because its provisioning profile lacks **Associated Domains**, **Push Notifications**, and **Sign in with Apple**.

**Remaining action:** in Apple Developer, create or repair an App Store distribution provisioning profile for `com.timonayf.cheeseapp` under team `59RCF5754W`, enabling those three capabilities and using an Apple Distribution certificate. Archive and export build 55 with that profile.

**Verification:** `xcodebuild -exportArchive` with method `app-store-connect` and `signingCertificate` `Apple Distribution` produces an IPA without a provisioning-profile error. Then upload that IPA/archive to App Store Connect.

### 4. Make the support channel real

The code and deployed public pages now use `support.cheeseteam@gmail.com`.

**Remaining action:** send and receive a test at `support.cheeseteam@gmail.com`, then set the same address in App Store Connect review contact and support metadata.

**Verification:** an inbound test receives a human reply; the deployed `/support` page and in-app mail link resolve to that exact address.

### 5. Complete App Store Connect for build 55

Known App Store Connect facts (read directly on 2026-09-11): app `6758976557`, version 1.1.0 is **Prepare for Submission**, and build 55 is not yet uploaded/selected. App Privacy is blank, the Privacy Policy URL is blank, copyright is unset, and availability is still **174 countries/regions** (Mainland China is the only shown unavailable storefront). It is not currently limited to the United States and Canada.

**Remaining action in App Store Connect:**

1. Change availability from the current 174-country scope to **United States and Canada only**, then confirm the resulting removal of the other storefronts. Apple states the change takes effect within 24 hours.
2. Upload/select the validated signed build 55, add required screenshots, copyright, pricing, review contact and a working review account/demo instructions.
3. Set Privacy Policy URL to `https://cheeseapp.org/privacy` and Support URL to `https://cheeseapp.org/support` only after both return 200 in production.
4. Complete App Privacy labels from the final archive and actual service behavior: account identifiers/contact info, user content/messages/photos, search history, product interaction, diagnostics, gender-sensitive information, social graph contacts, and marketplace purchase history. Mark tracking false. Reconcile the embedded Google Sign-In privacy manifest as part of this entry.
5. Keep the age rating at **13+**. Correct the content-rating questionnaire using actual behavior; do not claim advertising if the app does not serve ads.
6. Confirm encryption/export compliance and the exact final review metadata shown by App Store Connect.

**Verification:** Version 1.1.0 shows a selected build, US + Canada only, published privacy data, accessible URLs, all required screenshots/contact fields, and no unresolved validation warning.

### 6. Verify identity-provider and moderation operations

**Remaining action:** complete a production deletion test for password, Google and Apple sign-in. The app disconnects a matching local Google SDK session. The iOS client now handles local Apple credential revocation notifications and launch checks; a server-side Apple token-revocation path still requires production Apple credentials if Apple’s test case requires it. Establish a staffed report/appeal response path and document the owner/SLO for UGC reports.

**Verification:** each test account can delete itself in app; no original content remains in active Cheese systems; provider and moderation evidence matches the published policy.

## Audit basis

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app)
- [Apple TN3194: account deletions and revoking Sign in with Apple tokens](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple?changes=__5_6&language=objc)
- [App Store Connect privacy guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Apple privacy manifests](https://developer.apple.com/documentation/BundleResources/describing-data-use-in-privacy-manifests)
- [Cloudflare Workers AI data usage](https://developers.cloudflare.com/workers-ai/platform/data-usage/)
