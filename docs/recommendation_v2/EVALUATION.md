# Evaluation protocol and current results

## Status

Actual V1 embeddings have been generated and evaluated. Threshold 0.55 was
selected from validation only. Trusted validation: `[[16,0],[3,13]]`; trusted
test: `[[12,0],[2,10]]`, accuracy 91.67%, recall 83.33%. All provisional test
labels: `[[18,0],[5,13]]`. Full metrics and every error are under
`reports/recommendation_v2/teacher-v01-baseline/`. This small synthetic teacher
holdout does not measure production error rates.

## What the pipeline reports after embeddings are available

- Training, validation and test metrics, separately.
- Trusted labels and all provisional labels in separately labeled results.
- Confusion matrix `[[TN,FP],[FN,TP]]`, accuracy, precision, recall, F1,
  `FPR=FP/(FP+TN)` and `FNR=FN/(FN+TP)`.
- ROC-AUC and average-precision PR summary only when both classes exist, with
  small-sample warnings; absent denominators become null, never misleading zero.
- Class-conditional probability quantiles, per-example predictions and confidence.
- Validation thresholds .50 through .95 in .05 increments, including accepted
  count; output is both JSON and Markdown.
- Every test FP/FN, twenty nearest-boundary examples, and scenario error counts.
- A reviewer checklist for proper nouns, slang, short text, code switching,
  course codes, housing, coop and vague context. The program does not declare
  semantic understanding merely because accuracy is high.

The selected operating point maximizes recall under the user-configurable
validation FPR bound and minimum recall, breaking ties toward lower FPR and a
higher threshold. A point accepting nothing cannot win. If no threshold meets
the constraints, export is refused; do not choose a new point from test data.
Rejected runs still report class probabilities, all three splits' metrics and
test errors at a predeclared 0.50 **diagnostic-only** reference. The report marks
this reference separately from a validation-selected threshold; it is never
exported or treated as an acceptable deployment policy.
Default .05 FPR/.10 minimum recall are explicit experiment parameters, **not**
approved production quality criteria.

The current primary dataset has only 16 trusted validation negatives and 12
trusted test negatives. Zero observed false positives at that scale is weak
evidence; Wilson upper confidence bounds are included. Real, independently
reviewed holdout performance and human label review are prerequisites for any
claim of deployment readiness. Do not automatically replace logistic regression
with an MLP because one tiny synthetic split is difficult.

## Real holdout invocation

```sh
/tmp/cheese-rec-v2-venv/bin/python -m recommendation.cross_school.evaluate --dataset recommendation/cross_school/private/holdout.jsonl --cache recommendation/cross_school/private/cache --model recommendation/cross_school/runs/experiment-1/model.json --output-dir recommendation/cross_school/private/evaluation-1
```

This command never fits weights or selects a threshold. The dataset must be
marked real_holdout/anonymized and must not overlap development IDs, input
hashes or template families. Manual privacy and semantic-duplicate review are
still required. Outputs must remain under the ignored private directory.

The user subsequently requested direct activation after regression rather than
the originally proposed staged shadow rollout. That product decision does not
change the statistical limitations above. See `IMPLEMENTATION_STATUS.md`.
