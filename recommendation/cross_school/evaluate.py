"""Frozen-model evaluation; never fits a model or retunes a holdout threshold."""
import argparse
import json
from collections import defaultdict
from pathlib import Path
import numpy as np
from sklearn.metrics import average_precision_score, roc_auc_score
from .classifier import load_model, predict
from .schema import input_hash, load_dataset, load_embedding
from .threshold import metrics


def evaluation(rows, scores, threshold):
    labels = [r["label"] for r in rows]
    result = metrics(labels, scores, threshold)
    # Values with two classes are computable, but small n is explicitly flagged.
    two_classes = len(set(labels)) == 2
    result.update(roc_auc=float(roc_auc_score(labels, scores)) if two_classes else None,
                  pr_auc_average_precision=float(average_precision_score(labels, scores)) if two_classes else None,
                  small_sample_warning=min(labels.count(0), labels.count(1)) < 30,
                  probability_by_class={str(y): {
                      "n": labels.count(y),
                      "quantiles_0_25_50_75_100": np.quantile(
                          [q for label, q in zip(labels, scores) if label == y],
                          [0, .25, .5, .75, 1]).tolist()
                  } for y in (0, 1) if y in labels})
    return result


def error_analysis(rows, scores, threshold):
    lines = ["# Cross-school error analysis", "",
             "Synthetic performance is NOT production validation. Inspect provisional labels before attributing errors to the classifier.", ""]
    enriched = [{**row, "q": q, "prediction": int(q >= threshold)} for row, q in zip(rows, scores)]
    for title, selected in (
        ("False positives", [r for r in enriched if r["label"] == 0 and r["prediction"] == 1]),
        ("False negatives", [r for r in enriched if r["label"] == 1 and r["prediction"] == 0]),
        ("Nearest boundary cases", sorted(enriched, key=lambda r: abs(r["q"]-threshold))[:20]),
    ):
        lines += [f"## {title}", ""]
        lines += [f"- `{r['id']}` / {r['scenario_group']}: q={r['q']:.6f}, y={r['label']}, confidence={r['teacher_confidence']}: {json.dumps(r['text'], ensure_ascii=False)}" for r in selected] or ["None."]
        lines += [""]
    grouped = defaultdict(list)
    for row in enriched:
        grouped[row["scenario_group"]].append(row)
    lines += ["## Scenario correlations", "", "| Scenario | N | FP | FN |", "| --- | ---: | ---: | ---: |"]
    for group, values in sorted(grouped.items()):
        lines += [f"| {group} | {len(values)} | {sum(r['label']==0 and r['prediction']==1 for r in values)} | {sum(r['label']==1 and r['prediction']==0 for r in values)} |"]
    lines += ["", "## Human interpretation required", "",
              "Review campus proper nouns, slang, short posts, code switching, course codes, housing, coop, and vague pronouns/context. Scenario counts are associations, not causal evidence. Mark each false positive/negative with these attributes; compare matched counterfactual wording before concluding semantic transferability versus lexical shortcuts. No automated claim of semantic understanding is made.", ""]
    return "\n".join(lines)


def ensure_untouched_holdout(rows, model):
    if any(r["dataset_kind"] != "real_holdout" for r in rows):
        raise ValueError("Holdout evaluation accepts only real_holdout data")
    provenance = model.get("data_provenance", {})
    if not provenance.get("input_hashes"):
        raise ValueError("Artifact lacks leakage provenance")
    seen_ids = set(provenance.get("ids", []))
    seen_hashes = set(provenance["input_hashes"])
    seen_templates = set(provenance.get("template_families", []))
    if any(r["id"] in seen_ids or input_hash(r) in seen_hashes
           or r["template_family"] in seen_templates for r in rows):
        raise ValueError("Holdout overlaps development data")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dataset", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--output-dir", required=True)
    args = p.parse_args()
    model, rows = load_model(args.model), load_dataset(args.dataset)
    ensure_untouched_holdout(rows, model)
    scores = [predict(model, load_embedding(r, args.cache)) for r in rows]
    # Holdout reports can contain text. Only permit the git-ignored private tree.
    out = Path(args.output_dir).resolve()
    private = Path(__file__).resolve().parent / "private"
    if not out.is_relative_to(private):
        raise ValueError("Real holdout output must be inside cross_school/private/")
    out.mkdir(parents=True, exist_ok=False)
    (out / "holdout_metrics.json").write_text(json.dumps(evaluation(rows, scores, model["threshold"]), indent=2, allow_nan=False))
    (out / "cross_school_error_analysis.md").write_text(error_analysis(rows, scores, model["threshold"]), encoding="utf-8")


if __name__ == "__main__":
    main()
