# Cross-school logistic experiment

Status: trained artifact and SQL serving integration are implemented. Read
[current release status](../../docs/recommendation_v2/IMPLEMENTATION_STATUS.md),
[the historical audit](../../docs/recommendation_v2/V1_AUDIT.md),
[architecture](../../docs/recommendation_v2/ARCHITECTURE.md), and
[training commands](../../docs/recommendation_v2/TRAINING.md).
The [phase status report](../../docs/recommendation_v2/IMPLEMENTATION_STATUS.md)
distinguishes backend activation from installation of the new App build.

Primary dataset: `data/teacher_v01.jsonl`, imported from the user's 300-row
teacher CSV without relabeling. `data/synthetic_v1.jsonl` is a separate earlier
assistant-created tool-test corpus; do not combine them for this experiment.

Reproduce the teacher CSV mapping into a **new** output file:

```sh
python3 -m recommendation.cross_school.import_teacher_csv --input /path/to/cheese_cross_school_300_teacher.csv --output /tmp/teacher-import.jsonl --text-field body --board-name 校园生活 --group-links recommendation/cross_school/data/teacher_v01_group_links.json
```

The CSV is read only. Labels, confidences, probabilities and source hash are
preserved. The explicit mapping uses all source text as Body with no Title and
a constant synthetic board. Canonical input is exactly the V1 SQL format;
the TypeScript CLI imports the actual V1 provider. Student features never contain
teacher reasoning, labels, campus metadata or grouping fields.

Offline verification, from repository root:

```sh
/tmp/cheese-rec-v2-venv/bin/python -m unittest discover -s recommendation/cross_school/tests -p 'test_*.py' -v
cheeseapp-ai-worker/node_modules/.bin/tsc -p recommendation/cross_school/tsconfig.json
cd cheeseapp-ai-worker
node --import tsx --test ../recommendation/cross_school/tests/*.test.ts
```

The optional semantic sanity test is explicitly skipped until
`CROSS_SCHOOL_SANITY_MODEL` and `CROSS_SCHOOL_SANITY_CACHE` point to a trained
artifact and compatible cached embeddings for `data/sanity_v1.jsonl`. This is
not a passing semantic test before those assets exist.

All 300 teacher embeddings plus six sanity embeddings are generated and cached.
The real artifact is `artifacts/cross-school-logistic-v1-teacher-v01.json`.
Regenerating uncached vectors requires a local GEMINI_API_KEY; existing cache
tests and SQL serving do not. Keep keys out of the repository and chat. Real holdout inputs and
outputs must remain anonymized and under ignored `private/` paths.
