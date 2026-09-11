# Cross-school error analysis

The actual generated report is
[teacher-v01 baseline](recommendation_v2/teacher-v01-baseline/cross_school_error_analysis.md).
The complete manual review of all 39 provisional train/validation/test errors
is in [LINEAR_MODEL_DECISION.md](../docs/recommendation_v2/LINEAR_MODEL_DECISION.md).

At validation-selected threshold 0.55, the trusted 24-example test split has
0 false positives and 2 false negatives. The all-label 36-example test split
has 0 false positives and 5 false negatives. These are synthetic teacher labels,
not a real production holdout. Zero observed FP is not proof of zero risk.
