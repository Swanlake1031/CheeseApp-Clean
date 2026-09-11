# Dataset v1 and teacher import contract

**Primary dataset update:** use the user-supplied `data/teacher_v01.jsonl` for
the first experiment. See [teacher audit](TEACHER_DATA_AUDIT.md): 300 rows,
150/150 labels, 200 trusted candidates and 100 review-only examples. Its reviewed
connected split is 216/48/36 (trusted 144/32/24). The corpus described below is
the earlier assistant-authored tool-test dataset and is not mixed into that
experiment or represented as an independent holdout.

`recommendation/cross_school/data/synthetic_v1.jsonl` contains 300 assistant-
generated examples: 100 local, 100 transferable, 100 hard; 149 provisional
negative labels and 151 positive. There are 20 scenario groups and 60 template
families before linking shared families. The two 2C03 logistics families share
one template ID, so connected splitting has 19 independent components.

These are synthetic teacher judgments, **not human-reviewed ground truth**.
Confidence values (.95 strong, .85 clearer hard, .70 deliberately ambiguous)
are qualitative judgments, not measured correctness probabilities. Twenty
low-confidence rows go to review; defaults never train on them.

Default seed 20260909 creates 210/45/45 rows before confidence filtering.
Splits are independent of JSONL row order. All rows sharing a scenario OR a
template are connected before assigning groups. Group integrity takes
precedence over exact ratios. Never search seeds for better test accuracy.

Examples cover simplified/traditional Chinese, code switching, slang, short
questions, typo/abbreviation forms and longer descriptions across facilities,
lost property, specific classes, events, administration, coop, careers,
housing, loneliness, academics, tuition, food, transit, social life, clubs,
internships, study habits, exams, technology and exercise. Academic/housing
language here is ordinary forum text, not a revival of retired app modules.

## Teacher JSONL

Required fields include those from the request plus explicit V1 input fields:

```json
{"id":"teacher-v2-001","text":"今年coop是不是特别难","title":"今年coop是不是特别难","body":"","board_name":"校园生活","origin_campus":"synthetic-school-1","label":1,"teacher_confidence":0.9,"scenario_group":"coop_market","template_family":"coop_hiring_2026","label_source":"teacher-model-and-prompt-version","bucket":"cross","dataset_kind":"synthetic","notes":"Optional rationale; never a model input"}
```

`text` must equal nonempty title/body joined by newline. Do not silently infer
which words were a title versus body; it affects the V1 embedding. Supply the
actual board name for real samples. Synthetic origin IDs are deliberately
fictional and must never be inserted into database school-ID columns.

Optional `teacher_probability` in [0,1] supports the explicitly enabled soft-
label experiment. Without that flag the student sees only embedding and hard
label. Invalid/missing labels, confidence outside [0,1], duplicate IDs/text,
empty text and invalid scenario/template names are rejected.

The initial dataset is intentionally small and still contains author/style
correlations. Broad-topic splitting is conservative but does not mathematically
prove absence of all semantic leakage. Review the complete families before
using results to make model-complexity decisions.

## Real holdout

Use `dataset_kind=real_holdout`, `id=anon-...`, `anonymized=true`, and separately
reviewed labels. Store the dataset/cache/reports under the ignored `private/`
directory. Remove private information from text manually: a schema cannot prove
anonymization. Direct author/user/email/phone fields are rejected.

The training entry point refuses real_holdout rows. Evaluation checks for
development IDs, identical canonical input hashes and reused template families.
The model/threshold remain frozen; no threshold tuning from holdout results.
Sending real text to Gemini requires the explicit external-evaluation flag and
appropriate data-handling authorization. It is not done by this task.

`data/sanity_v1.jsonl` contains six requested deterministic examples. They are
smoke checks, not independent evidence of generalization, and must not be
silently folded into training.
