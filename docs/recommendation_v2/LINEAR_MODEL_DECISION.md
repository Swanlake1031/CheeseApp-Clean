# First real-embedding experiment: retain logistic regression

Dataset: teacher-v0.1, seed 20260909; frozen V1 Gemini Embedding 2, normalized
768-dimensional float32 vectors. All 300 primary examples and six fixed sanity
examples are cached. No labels, split assignments or hyperparameters changed
after observing predictions. First run used `--report-only`.

## Evidence and decision

At validation-selected threshold **0.55**, confidence-qualified validation is
`[[16,0],[3,13]]` and test is `[[12,0],[2,10]]` (rows true local/cross; columns
predicted local/cross). Test precision is 1.0, recall .8333, F1 .9091 and accuracy
.9167. All provisional test labels produce `[[18,0],[5,13]]`, recall .7222.
Validation at .50 instead produced two false positives; .60 sharply reduced
validation recall to .3125. The .55 operating point was chosen from validation,
not these test results.

This is enough evidence of technical plausibility to **retain the linear model
and implement disabled runtime integration**, not evidence for production
filtering. With only 12 trusted test negatives, zero observed false positives
still has a Wilson 95% upper bound of .2425. ROC-AUC and average precision are
computable but highly uncertain on these small, synthetic grouped holdouts.
No MLP, changed embeddings, ranking weights or lexical rule classifier is warranted.

All six predeclared sanity examples are on the expected side of .55: local
scores .406759/.360759/.390199; cross scores .590774/.666303/.601471.
They are sanity checks, not an independent production-quality benchmark.

## Review of every observed error

Across all provisional splits there are **2 FP and 37 FN**: train 2/23,
validation 0/9, test 0/5. Confidence-qualified subsets have no FP and 18 FN
(13/3/2). Low-confidence examples were not fitted or used to select threshold.
Every error was read in full before this decision; the following groups account
for all 39 errors without changing their labels.

| Split / IDs | Review |
| --- | --- |
| Train FP: cs_105, cs_106 | Loneliness and off-campus belonging; confidence .58/.61. Both have plausible transferable meaning, so these may reflect teacher-label ambiguity. Retain original labels and count them as provisional FP. |
| Train FN: cs_005, cs_008, cs_011, cs_012 | General comparative building/access questions remain below threshold: learned facility-local associations appear stronger than the cross-school phrasing. |
| Train FN: cs_017, cs_020, cs_024 | General lost-property practices are suppressed alongside local lost-and-found content. |
| Train FN: cs_036, cs_060, cs_072, cs_079 | Lab workload, pharmacy use, internship anxiety and networking: transferable experiences with local-service or short-context wording. cs_072 is particularly close (.549833). |
| Train FN: cs_151, cs_216 | Transit-pass comparison and coping with exams; plausible transferable context missed. |
| Train FN: cs_233, cs_236, cs_240 | General gym routines/timing; repeated local-service association. |
| Train FN: cs_246, cs_248, cs_252 | Weather/closure comparisons; cs_252 is ambiguous and strongly local-looking (.383076). |
| Train FN: cs_281, cs_283, cs_287, cs_296 | General waitlists, registrar response and IT support; institutional-service wording suppresses transferability. |
| Validation FN: cs_127, cs_132, cs_204 | Fees/OSAP and study-method experiences; two are low-confidence. |
| Validation FN: cs_221, cs_222, cs_227, cs_228 | General library/quiet-floor questions; strongest repeated held-out failure category. |
| Validation FN: cs_263, cs_264 | Work/class scheduling concerns; both low-confidence. |
| Test FN: cs_047, cs_048 | Club-fair and attending events alone; both low-confidence, q .539378/.522670. |
| Test FN: cs_270, cs_271, cs_276 | Student health/access questions. The first two are trusted FN, all near the boundary. This is a genuine coverage weakness, not a reason to retune on test. |

## Required error attributes and shortcut assessment

| Attribute | Observed evidence / limitation |
| --- | --- |
| Campus proper nouns | Neither FP requires a named campus. No FP is a specific building/lost-item example in this corpus. This does not prove robustness on unseen campus entities. |
| Slang | Internship/exam/networking shorthand occurs in FN (cs_072, cs_079, cs_216). No causal slang error rate was estimated. |
| Short posts | Both FP and several FN omit broader scope/context; examples include cs_105, cs_106, cs_047 and cs_048. Length alone does not explain direction. |
| Code switching | Many FN mix English service terms with Chinese. Their prevalence in the whole corpus prevents attributing errors to code switching alone. |
| Course codes | No observed FP/FN hinges on a specific course code. The fixed 2C03 local sanity example passes. Unseen-code generalization is unproven. |
| Housing | No error in the housing scenario at the selected threshold; it is a training scenario, not independent held-out housing evidence. Off-campus belonging FP cs_106 remains relevant. |
| Coop | cs_072 is a low-confidence near-boundary FN. The explicit cross-school coop sanity example passes. |
| Vague pronouns/context | Generic first-person belonging yields both provisional FP; general service questions yield many FN. The label convention itself may encode scope-word shortcuts. |

The model is not merely accepting campus-name-free text: named/unnamed service
questions can be rejected despite explicit general wording. Conversely, this
does not establish semantic understanding. Teacher style, mixed label conventions
and the single body/constant-board mapping remain confounds. Matched wording
counterfactuals and independently reviewed real posts are the next quality tests.

No production rollout is approved. Runtime/shadow infrastructure, if added,
must remain disabled until its own parity/security tests pass; real-data review
is additionally required before filtering user feeds.
