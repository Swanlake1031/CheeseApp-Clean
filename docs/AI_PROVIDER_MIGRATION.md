# AI provider boundary for the 13+ launch release

Last reviewed: 2026-09-11 (America/Toronto)

## Launch contract

CheeseApp remains a 13+ product.  Gemini is retained in source, schema and
tests so that a later provider migration is possible, but **no Gemini request
is permitted in the launch release**.

Two independent latches enforce that contract:

1. `ReleaseCapabilities.optionalGemini` is `false` in the iOS app.  It hides
   the optional description-generation UI and the `@奶酪AI` candidate, and it
   prevents comment-event or secondhand-generation requests even if a future
   view reaches the service directly.
2. `GEMINI_PROVIDER_RELEASED` is `false` in
   `cheeseapp-ai-worker/src/config.ts`.  It must be changed in source *and*
   the operational flags must be enabled before a provider can run.  The
   launch `Production.xcconfig` also expands `CHEESE_AI_TRIGGER_URL` to an
   empty value, and `scripts/validate-ios-release.py` rejects an archive that
   restores it.

With the source latch closed, `POST /v1/comment-events` and
`POST /v1/secondhand/generate-description` return `404` before authentication,
request parsing, database access, provider construction or network activity.
The scheduled optional-AI handler returns before creating a repository or
provider.  Recommendation maintenance can still refresh SQL-only state but
does not claim embedding jobs or construct the Gemini embedding provider.

## Preserved integration points

| Surface | Current implementation | Launch behavior | Future replacement boundary |
| --- | --- | --- | --- |
| `@奶酪AI` replies | `CheeseAIInteractionHandler` + `CheeseAIProvider`; Gemini implementation in `ai/geminiProvider.ts` | UI hidden; legacy route is 404; cron does no work | Implement the same `CheeseAIProvider` interface for the chosen generation model. |
| Listing description helper | `SecondhandDescriptionHandler` + `SecondhandDescriptionProvider` | UI hidden; service fails locally before staging images; legacy route is 404 | Implement `generateSecondhandDescription` behind the existing provider interface. |
| Forum embeddings | `RecommendationProcessor` + `RecommendationEmbeddingProvider`; Gemini implementation in `recommendation/embeddingProvider.ts` | Database maintenance runs; no jobs are claimed, no provider is built and no post text is sent | Replace the embedding provider only after selecting a model and an explicit migration plan. |
| Recommendation SQL | `post_embedding_jobs`, `post_embeddings`, `user_interest_profiles`, `rank_forum_recommendations_v1`, sessions and metrics | Continues to rank eligible posts when embeddings are absent; signals, metrics, sessions and refresh remain active | Keep the existing ranker/session contract unless a separately reviewed product change is intended. |
| Image safety | `/v1/media/upload` in `moderation.ts`, Cloudflare Workers AI model `@cf/mistralai/mistral-small-3.1-24b-instruct` | Independent from Gemini; explicit media-safety acknowledgement is required; any outage or ambiguous verdict fails closed before Storage upload | This is not a Gemini fallback. Review the model license and image-safety quality independently before changing it. |
| Content Studio | Publishes media through the same independent media-safety endpoint | No Gemini consent endpoint or browser control is exposed | Keep its dedicated acknowledgement separate from any future optional-generation consent. |

## Storage and schema assumptions

The current recommendation schema intentionally fixes vectors at **768
dimensions**, L2-normalizes values before storage, and records the model,
embedding version, input format version and content hash with each job/result.
`recommendation_configuration` currently names `gemini-embedding-2` and
`cheese-semantic-v1`; these values are part of existing row validation and are
not safe to change in place.

A future provider migration must either produce compatible 768-dimensional
normalized vectors with a reviewed versioning strategy, or introduce an
additive migration for new dimensions/version rows and re-embedding.  It must
not reinterpret existing vectors.  The existing queue keeps retry, lease,
supersession and completion checks; only an enabled provider is allowed to
claim jobs.

Cloudflare Workers AI currently lists Qwen embedding and generation options,
but no Qwen integration is part of this release.  Before enabling one, review
its then-current license, data use, supported dimensions, regional processing,
age suitability, capacity and failure behavior.

## Required checks before reopening optional AI

1. Add a provider implementation behind the existing interfaces; do not wire a
   model directly into UI code or scheduled handlers.
2. Add an explicit source release latch and operational configuration review;
   never rely on a dashboard variable alone.
3. Decide whether the selected embedding model is compatible with 768-dimension
   storage.  If not, add and test a forward-only schema/data migration.
4. Re-run AI-worker unit tests for disabled routes, cron, retries, embedding
   claims and provider failures; add provider-specific request/response tests.
5. Re-run database ranking/session tests with missing, stale and new embeddings
   and verify that a feed remains nonempty when semantic scoring is unavailable.
6. Re-audit iOS and Content Studio so optional AI controls are visible only
   after consent, feature copy and App Store metadata match the enabled
   behavior, and production health exposes no model/key details.
7. Perform a real production canary with a non-sensitive test account before
   advertising the restored feature.
