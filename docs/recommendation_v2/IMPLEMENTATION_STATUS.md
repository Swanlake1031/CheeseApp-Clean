# Recommendation V2 — release summary

> Historical release snapshot. For the current flow, refresh/pagination behavior,
> version identity and deployment boundary, read [CURRENT_RECOMMENDATION_SYSTEM.md](../CURRENT_RECOMMENDATION_SYSTEM.md).

2026-09-09 America/Toronto (2026-09-10 UTC). Repository: Swanlake1031/CheeseApp-Clean.

**Backend deployed and activated. New App integration compiles and passes all
249 simulator tests (including the forum-tab follow-up). The new App binary has not been uploaded to TestFlight /
App Store or installed on the user's phone.** Existing binaries lack the V2
contract header and do not receive the complete V2 filtering behavior.

## A. Existing V1

The original semantic ranking lives in PostgreSQL migration 190, with embedding
and signal infrastructure in 188/189. Before this release its rollout was 0%;
the user-visible recommendation used the legacy client path. V1_AUDIT.md records
that historical snapshot. Its historical pending-status notes are superseded here.

## B. Preserved behavior

No V1 feature weights, post/user embeddings, signal strengths, freshness formula,
ignore penalty, Top 80 selection, three-pass shaping, 60-item cap or 20-item
pagination were redesigned. New eligibility is inserted before candidate ranking.
V1 remains the name of the internal ranker/config algorithm; V2 composition is
identified by the active classifier and gate configuration.

## C. V2 algorithm

Reuse the exact V1 768-dimensional L2-normalized Gemini embedding.
Compute q = sigmoid(dot(w, embedding) + b), independently of the V1 ranking score.
Known same-school posts bypass only this classifier gate, not normal visibility,
active/public, block, hide or author eligibility. Foreign-school posts require a
current valid q >= 0.55. Missing school/score, invalid vector or stale revision
fails closed for foreign posts. Apply unchanged V1 ranking to survivors:

- Semantic similarity: 0.40.
- Engagement: 0.20.
- Freshness: 0.15.
- Discussion quality: 0.10.
- Author affinity: 0.05.
- Exploration: 0.10.
- Existing repeated-ignore penalty remains subtracted.

Shape Top 80 candidates into up to 60 diverse items, with stable 20-minute
sessions and pages of at most 20. q is never added to the ranking score.

## D. Model

Artifact: recommendation/cross_school/artifacts/cross-school-logistic-v1-teacher-v01.json.
Model version v1-teacher-v01, 768 weights plus one bias. Representation:
gemini-embedding-2 / cheese-semantic-v1 / input format 1. No serving-time
generative API call: scoring reuses the stored embedding and caches the result.

## E. Dataset

The supplied 300-row teacher CSV is preserved, with 150 local / 150 cross labels.
Confidence-qualified subsets: train 144, validation 32, test 24; all-label splits:
216 / 48 / 36. Scenario/template and reviewed cross-scenario grouping prevents
declared leakage. Earlier assistant-generated data is not merged into training.

## F. Training

Real embeddings for all 300 rows plus six predeclared sanity examples are cached.
Regularized logistic regression was trained, every observed error reviewed, then
the artifact exported. No label or threshold was retuned on test results.

## G. Evaluation

Trusted validation confusion matrix [[16,0],[3,13]]; trusted test [[12,0],[2,10]].
Trusted test accuracy 91.67%, recall 83.33%, F1 90.91%. All-label test
[[18,0],[5,13]]. These small synthetic teacher samples do not establish production
accuracy. Runtime approval reflects the user's explicit instruction to deploy
directly after regression, not an invented real-world validation result.

## H. Threshold

0.55, selected on validation only; policy v1-teacher-v01-validation-policy-1.
At .50 validation FPR was .125; .55 had observed FPR 0 and recall .8125;
.60 reduced recall to .3125. Zero accepted examples cannot win selection.

## I. Error analysis

All provisional splits have 2 FP / 37 FN. Both FP are low-confidence belonging /
loneliness examples. General library, health and institutional-service posts
account for important FN limitations. Full generated results are in
reports/recommendation_v2/teacher-v01-baseline/, with complete review in
LINEAR_MODEL_DECISION.md. Zero FP among only 12 trusted test negatives is weak
statistical evidence (Wilson upper bound approximately .2425).

## J. Implementation

Forum-tab follow-up (2026-09-10): HomeView's `.forum` branch explicitly calls
`HomeViewModel.forumTabCards(selectedBoardID:)`, consuming the server-ranked
`forumCards` from `fetchRecommendationForumPreview`. It does not consume the old
mixed-content `recommendedCards` preview. Featured placement and board filters
retain existing behavior without reordering organic V2 results. A partial-load
failure now retains the cached recommendation session together with its cards,
preventing a successful refresh of another section from randomly reranking the
cached V2 forum list. Following and secondhand data paths are unchanged.

Migration 20260910024900 adds immutable origins/models, cached scores, scoring
hooks, protected configuration, optional shadow diagnostics, session invalidation
and the pre-ranking gate. HomeFeedService sends contract header 2, validates
featured posts with the same server rule and retries stale sessions once.
HomeViewModel no longer silently falls back to an unfiltered query on RPC error.
Only an explicit server-off result selects legacy fetching.

Fixed during regression: an already-recorded invalid embedding could starve
later batch-backfill rows. Cached failures are now terminal for that exact
model/input/vector revision; a changed vector becomes eligible for rescoring.

## K. Verification

- V2 database suite: 71 passed.
- Original V1 database suite: 28 passed.
- Actual Python/SQL parity: 306 predictions and threshold decisions agree,
  maximum absolute probability error 7.22e-16.
- Offline Python suite: 32 passed, including six actual-embedding sanity cases.
- App Debug build and build-for-testing: passed.
- Full simulator suite after forum-tab integration: 249 passed, 0 failed, 0 skipped.
- Share Worker syntax check: passed; git diff whitespace check: passed.

The local image has the known supautils EXECUTE-denial crash
(https://github.com/supabase/supautils/issues/214), reproduced with an unrelated
SELECT 1 function. Regression connections omit that extension only for the
connection and still switch to real authenticated/anon roles. No production
extension, privilege or permanent local configuration was weakened.

Test result:
`/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.10_00-40-34--0400.xcresult`.

## L. Deployment

Only the V2 migration was pending in the production dry-run and was applied.
The activation transaction registered the exact artifact, backfilled scores,
required complete active-public-post coverage, and enabled V2 at 100% for
supported clients. Scoring on; classifier shadow off; threshold 0.55. The
underlying V1 ranking rollout is 100%. Existing V1 shadow settings were preserved.

Independent production verification: migration recorded; 21 active public forum
posts, 21 scores, 0 stored scoring failures, 0 missing origins/embeddings and 0
dimension mismatches. Three posts have q >= .55 for foreign-campus eligibility;
same-campus posts are not restricted to those three. A rollback-only live smoke
request created a V2 session, returned 20 page items and found 0 ineligible items.
No smoke session or temporary result was retained.

## M. Rollback and known  

Set cross_school_configuration.gate_enabled=false to restore V1 eligibility.
Policy revision updates automatically and the new client refreshes stale sessions.
To restore the exact pre-release legacy path, also set the original ranking
rollout to 0. See ROLLBACK.md. Never delete embeddings/posts for operational rollback.

Deployment did not add security-advisor errors. Two pre-existing SECURITY DEFINER
view findings remain: forum_posts_view and profile_public_view. They were not
changed in this scoped release. No claim is made that those prior findings were fixed.

## N. Handoff

Backend V2 is active. Build/run the updated App to use the full contract; this
task did not publish an App Store/TestFlight binary or push the unrelated dirty
worktree. No retired course/rating, housing, ride or team features were introduced.
No API keys are saved in reports or source. No additional model redesign,
data collection or staged shadow rollout was added.
