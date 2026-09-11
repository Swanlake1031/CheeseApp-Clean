# Model artifacts

The trained artifact is `cross-school-logistic-v1-teacher-v01.json`, using the
300-row teacher corpus and actual V1 embeddings. Threshold is 0.55. All 306
teacher/sanity SQL predictions match Python within 1e-12 (maximum 7.22e-16).
Numeric unit-test fixtures are never deployed.

Required fields are schema_version, model_name, version, embedding_model,
embedding_version, input_format_version, dimension, weights, bias, threshold,
threshold_version, trained_at, dataset_version and metrics. The parser validates
768 finite weights and the audited V1 representation. Exported artifacts include
development data provenance and `production_approved=false`.

Threshold selection and versioning are separate from the learned weights.
The database registry preserves the artifact and has separate runtime approval.
The user's explicit direct-release instruction authorizes activation; artifact
metadata remains `production_approved=false` because synthetic test results
do not establish real-world quality. See the current implementation status.
