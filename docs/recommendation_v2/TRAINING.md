# Training and reproducibility

Run commands from the repository root unless shown otherwise. No serving
deployment is performed by these commands.

```sh
python3 -m venv /tmp/cheese-rec-v2-venv
/tmp/cheese-rec-v2-venv/bin/pip install -r recommendation/cross_school/requirements.txt
python3 -m recommendation.cross_school.dataset --dataset recommendation/cross_school/data/teacher_v01.jsonl
```

Preview exact embedding requirements without a key or provider calls:

```sh
cd cheeseapp-ai-worker
node --import tsx ../recommendation/cross_school/embed_dataset.ts --dataset ../recommendation/cross_school/data/teacher_v01.jsonl --cache ../recommendation/cross_school/cache --dry-run
```

Configure `GEMINI_API_KEY` securely in the local environment, never in tracked
files or chat. Remove `--dry-run` to generate/cache the 300 unique inputs. The
CLI caps provider requests at 300 by default and refuses oversized runs before
making calls. It imports the existing V1 Gemini provider, uses its exact
normalization, then rounds values to pgvector float32 storage precision. Cache
validation checks input hash, model/version/format, dimension, time and finite
unit-vector values. Rerunning uses valid cached entries and does not regenerate
them. Interrupted/corrupt entries must pass validation before reuse.

Requests are spaced at least 1000 ms apart by default
(`--request-interval-ms`). Retryable quota/network/5xx errors receive at most
three attempts per input (`--max-attempts-per-input`), with bounded exponential
backoff and any provider retry delay. Recognized daily quotas stop immediately;
waits above 60 seconds also stop this bounded run. All attempts count against
`--max-requests`. Completed vectors remain cached after any interruption.
Quota logs contain allowlisted quota names and retry delay, never raw provider
messages, request headers, credentials or project identifiers. The production
V1 provider/model/preprocessing are unchanged.

Back at the repository root:

```sh
/tmp/cheese-rec-v2-venv/bin/python -m recommendation.cross_school.train --dataset recommendation/cross_school/data/teacher_v01.jsonl --dataset-version teacher-v0.1 --cache recommendation/cross_school/cache --output-model recommendation/cross_school/runs/experiment-1/model.json --report-dir recommendation/cross_school/runs/experiment-1/reports --seed 20260909 --confidence-threshold 0.80 --regularization 1.0 --class-weight none --max-iterations 2000 --max-fpr 0.05 --min-recall 0.10 --report-only
```

The first run deliberately uses `--report-only`: inspect FP/FN and document
linear adequacy before artifact export. A subsequent export must use identical
dataset/cache/configuration, omit that flag and use fresh output paths. Compare
metrics and fingerprints against the reviewed experiment. Do not tune against
test labels between review and export.

Threshold selection uses only confidence-filtered validation data. The FPR and
minimum recall flags are experiment constraints, not approved product policy.
No acceptable operating point means no deployable artifact is exported.
Validation/test metrics are reported separately, both trusted-label and full
provisional-label views. Low-confidence cases remain identifiable in manifests.
Test probabilities cannot influence threshold selection.

The seed, split IDs, dataset SHA-256, embedding-values SHA-256, optimizer settings and dependency versions
are recorded. Rows are sorted before fitting and native math threads are limited
to one. Repeated runs with identical inputs/dependencies should produce identical
weights/metrics (timestamps differ). Platform BLAS differences can still affect
last-bit floating point results. No input standardization, PCA, new embeddings
or Transformer training is introduced.

`--soft-labels` is optional and requires teacher_probability for every included
training row. The default is hard labels. Use new output paths for each run:
the CLI refuses to overwrite existing evidence.

## Current execution status

All 300 teacher embeddings and six sanity embeddings are cached. Training,
validation-only threshold selection (0.55), full error review and artifact
export are complete. See `LINEAR_MODEL_DECISION.md` and the generated reports in
`reports/recommendation_v2/teacher-v01-baseline/`. Unit-test numeric fixtures
are software verification only; semantic results use the actual V1 embeddings.
