# Supplied teacher dataset audit

Source: user-supplied `cheese_cross_school_300_teacher.csv` and `README(1).md`,
received 2026-09-09. Source CSV SHA-256:
`050e71736c8769943dd2e288ee3f5eae8159d6edd32ebf4a940f21c6b84bdb4c`.

This is the **primary initial experiment dataset**. The earlier assistant-created
`synthetic_v1.jsonl` is retained as a separate tool-test corpus. Do not merge the
two and then call one an independent holdout: they contain overlapping ideas.

## Verified counts

- 300 records; 300 unique IDs and exact texts; no missing hard labels.
- 150 label 0 and 150 label 1.
- 100 strong local, 100 strong cross, 100 hard/ambiguous.
- 25 scenario groups, each containing 12 rows.
- 300 distinct scenario_family values: each family ID currently names one row.
  Splitting by family alone would be effectively row-level splitting. The
  importer preserves these values; the splitter also locks whole scenario groups.
- 200 rows have confidence ≥.80. All 100 hard rows have confidence below .80.
  Confidence and teacher_p_cross are finite and within [0,1].
- Label source is `GPT-5.6-Sol teacher` as supplied, not independently verified.

## Explicit input mapping

The CSV provides text but no original title/body/board. The reproducible import
explicitly uses `--text-field body --board-name 校园生活`: the entire text remains
unchanged in Body, Title is empty, and one constant synthetic board name is
used for all rows. This makes no claim that these were real posts in that board.
It does use the actual V1 input formatter and embedding provider. Record this
mapping in every row; a future title/body sensitivity experiment must be a
separate version, not a silent preprocessing change.

`teacher_p_cross` maps to `teacher_probability`, `scenario_family` to
`template_family`, and difficulty_bucket maps to local/cross/hard. Source labels,
confidence, probability, origin text, recommendation and rationale are preserved.
Teacher rationale never enters embeddings or student features. No supplied
file was edited. Only the derived JSONL was added to the repository.

## Label-quality issues to review before interpreting model errors

These are questions for human review, **not automatic relabeling**:

- `cs_097`–`cs_100` label general loneliness/belonging/club-integration complaints
  as local with .93–.98 confidence. The product examples treat similar general
  student experiences as transferable. The class may depend too much on
  first-person wording versus explicit “大家/你们学校” wording.
- `cs_088` (prepaying four months' rent) and `cs_090` (same general rental concern)
  are opposite labels. Presence of “离学校走路十分钟” may not remove transferable
  value from a question about rental practices. Review without inventing legal
  advice or making a law-based label.
- `cs_205` (four midterms in three days) versus `cs_210` (two exams per day) could
  teach a “我们/大学” lexical distinction rather than scope of the underlying issue.
- `cs_136` and `cs_139` compare campus food budgets with different labels. Decide
  whether seeking a particular vendor versus general budgeting is unambiguous.
- `cs_081` and `cs_077` differ in scope words around career-centre usefulness;
  the former is correctly at least marked low-confidence and stays out of default
  training. Review other near-boundary pairs with the same rule.
- School strings are offline provenance, not canonical serving IDs. Some
  campus-specific entities appear with another school's origin label (the
  source cycles eleven school names). Do not use these rows to validate real
  origin-school assignment or authorization. Origin is not a student feature.

## Leakage / evaluation limitations

Whole-scenario splitting prevents obvious within-group paraphrase leakage.
Review found three cross-scenario links: library opening hours, first-internship
response/market concerns, and commuter belonging. These are recorded in
`data/teacher_v01_group_links.json` and added as leakage_groups metadata without
changing source labels or the original scenario_family. The splitter transitively
locks those connected groups, leaving 20 independent components. Default seed
20260909 yields 216/48/36 rows and 144/32/24 confidence-filtered rows for
train/validation/test, plus 72/16/12 review-only rows. Exact 210/45/45 is secondary
to family integrity. No model results were used to choose these links or splits.
Further human review is still needed for less obvious relationships.
Synthetic accuracy may be optimistic even with grouped
splits because the same teacher/style creates all labels.

No labels were changed after this audit. No quality metric, confusion matrix or
production threshold is asserted before actual embeddings and training exist.
