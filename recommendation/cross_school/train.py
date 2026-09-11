"""Offline logistic student. Export only after validation selects an operating point."""
import argparse
import hashlib
import json
import platform
import warnings
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import scipy
import sklearn
from sklearn.exceptions import ConvergenceWarning
from sklearn.linear_model import LogisticRegression
from threadpoolctl import threadpool_limits

from .classifier import validate_model
from .dataset import grouped_split, training_rows
from .evaluate import error_analysis, evaluation
from .schema import CONTRACT, input_hash, load_dataset, load_embedding
from .threshold import select_threshold, sweep


def fit_student(vectors, labels, *, seed=20260909, regularization=1.0,
                class_weight="none", max_iterations=2000, soft_targets=None):
    if not np.isfinite(regularization) or regularization <= 0:
        raise ValueError("regularization must be positive inverse-C")
    if max_iterations < 1 or class_weight not in {"none", "balanced"}:
        raise ValueError("Invalid optimizer configuration")
    x, y = np.asarray(vectors, dtype=np.float64), np.asarray(labels)
    if x.ndim != 2 or len(x) != len(y) or not np.isfinite(x).all():
        raise ValueError("Invalid training matrix")
    if set(y) != {0, 1}:
        raise ValueError("Training needs both classes")
    weights = np.ones(len(y), dtype=np.float64)
    if class_weight == "balanced":
        weights = np.array([len(y)/(2*np.count_nonzero(y == label)) for label in y])
    if soft_targets is not None:
        t = np.asarray(soft_targets, dtype=np.float64)
        if t.shape != y.shape or not np.isfinite(t).all() or np.any((t < 0) | (t > 1)):
            raise ValueError("Invalid soft targets")
        # Two weighted copies implement exactly t*loss(y=1)+(1-t)*loss(y=0).
        x, y, weights = (np.concatenate([x, x]),
                         np.concatenate([np.zeros(len(y)), np.ones(len(y))]),
                         np.concatenate([weights*(1-t), weights*t]))
    model = LogisticRegression(C=1/regularization, solver="lbfgs", fit_intercept=True,
                               max_iter=max_iterations, random_state=seed, tol=1e-9)
    with threadpool_limits(limits=1), warnings.catch_warnings():
        warnings.simplefilter("error", ConvergenceWarning)
        model.fit(x, y, sample_weight=weights)
    return model


def train_experiment(rows, vectors_by_id, *, seed=20260909, confidence_threshold=.8,
                     regularization=1.0, class_weight="none", max_iterations=2000,
                     max_fpr=.05, min_recall=.1, soft_labels=False):
    # Split BEFORE confidence filtering; review examples keep their held-out family.
    training_rows(rows, confidence_threshold)  # Also rejects any real holdout.
    split = grouped_split(rows, seed)
    trusted = {k: training_rows(v, confidence_threshold) for k, v in split.items()}
    if any(set(r["label"] for r in v) != {0, 1} for v in trusted.values()):
        raise ValueError("Every confidence-filtered split needs both classes; review grouping")
    train = trusted["train"]
    if soft_labels and any("teacher_probability" not in r for r in train):
        raise ValueError("Soft-label experiment requires teacher_probability on every training row")
    model = fit_student([vectors_by_id[r["id"]] for r in train], [r["label"] for r in train],
                        seed=seed, regularization=regularization, class_weight=class_weight,
                        max_iterations=max_iterations,
                        soft_targets=[r["teacher_probability"] for r in train] if soft_labels else None)
    score = lambda group: model.predict_proba([vectors_by_id[r["id"]] for r in group])[:, 1].tolist()
    valid = trusted["validation"]
    table = sweep([r["label"] for r in valid], score(valid))
    chosen = select_threshold(table, max_fpr=max_fpr, min_recall=min_recall)
    manifest = {name: {"all_ids": [r["id"] for r in group],
                        "trusted_ids": [r["id"] for r in trusted[name]],
                        "review_ids": [r["id"] for r in group if r["teacher_confidence"] < confidence_threshold]}
                for name, group in split.items()}
    report = {"status": "candidate_offline_only" if chosen else "no_acceptable_threshold",
              "seed": seed, "confidence_threshold": confidence_threshold,
              "max_fpr": max_fpr, "min_recall": min_recall, "threshold_sweep": table,
              "selected_validation_point": chosen, "split": manifest,
              "limitations": ["Synthetic performance is NOT production validation.",
                              "The FPR limit is an experiment constraint, not a production acceptance policy.",
                              "Teacher labels/confidences are provisional, not human-reviewed."]}
    report["predictions"] = {name: [{"id": r["id"], "label": r["label"], "q": q,
                                     "teacher_confidence": r["teacher_confidence"],
                                     "scenario_group": r["scenario_group"]}
                                    for r, q in zip(group, score(group))]
                             for name, group in split.items()}
    # A rejected experiment still needs diagnostics. This fixed reference is NOT
    # a selected operating point, and must never permit artifact export.
    threshold = chosen["threshold"] if chosen else .5
    report["evaluation_threshold"] = threshold
    report["evaluation_threshold_role"] = ("validation_selected" if chosen
                                            else "fixed_diagnostic_only_not_for_deployment")
    report["trusted_metrics"] = {name: evaluation(group, score(group), threshold)
                                 for name, group in trusted.items()}
    report["all_provisional_metrics"] = {name: evaluation(group, score(group), threshold)
                                         for name, group in split.items()}
    analysis = error_analysis(split["test"], score(split["test"]), threshold)
    if chosen is None:
        analysis = analysis.replace(
            "# Cross-school error analysis\n",
            "# Cross-school error analysis — rejected experiment\n\n"
            "No validation threshold met the explicit FPR/recall constraints. "
            "No artifact was exported. The following test errors use the predeclared "
            "0.50 diagnostic threshold only; it is NOT a deployment recommendation. "
            "Do not retune from these test results.\n", 1)
        return None, report, analysis
    params = {"weights": model.coef_[0].tolist(), "bias": float(model.intercept_[0]),
              "threshold": threshold}
    return params, report, analysis


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dataset", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--output-model", required=True)
    p.add_argument("--report-dir", required=True)
    p.add_argument("--seed", type=int, default=20260909)
    p.add_argument("--confidence-threshold", type=float, default=.8)
    p.add_argument("--regularization", type=float, default=1.)
    p.add_argument("--class-weight", choices=["none", "balanced"], default="none")
    p.add_argument("--max-iterations", type=int, default=2000)
    p.add_argument("--max-fpr", type=float, default=.05)
    p.add_argument("--min-recall", type=float, default=.1)
    p.add_argument("--soft-labels", action="store_true")
    p.add_argument("--version", default="v1-synthetic")
    p.add_argument("--dataset-version", required=True)
    p.add_argument("--report-only", action="store_true",
                   help="Evaluate first; defer artifact export until human error review")
    args = p.parse_args()
    output, report_dir = Path(args.output_model), Path(args.report_dir)
    if output.exists() or report_dir.exists():
        raise ValueError("Use fresh output paths; experiments must not overwrite previous evidence")
    rows = load_dataset(args.dataset)
    vectors = {r["id"]: load_embedding(r, args.cache) for r in rows}
    params, report, analysis = train_experiment(
        rows, vectors, seed=args.seed, confidence_threshold=args.confidence_threshold,
        regularization=args.regularization, class_weight=args.class_weight,
        max_iterations=args.max_iterations, max_fpr=args.max_fpr,
        min_recall=args.min_recall, soft_labels=args.soft_labels)
    canonical_dataset = json.dumps(sorted(rows, key=lambda r: r["id"]),
                                   sort_keys=True, ensure_ascii=False).encode()
    report["dataset_sha256"] = hashlib.sha256(canonical_dataset).hexdigest()
    report["embedding_values_sha256"] = hashlib.sha256(json.dumps(
        sorted(vectors.items()), separators=(",", ":"), allow_nan=False).encode()).hexdigest()
    report["runtime"] = {"python": platform.python_version(), "numpy": np.__version__,
                         "scipy": scipy.__version__, "scikit_learn": sklearn.__version__}
    report["optimizer"] = {"solver": "lbfgs", "inverse_C": args.regularization,
                           "class_weight": args.class_weight, "max_iterations": args.max_iterations,
                           "soft_labels": args.soft_labels}
    report_dir.mkdir(parents=True, exist_ok=False)
    (report_dir / "evaluation.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    (report_dir / "threshold_sweep.json").write_text(json.dumps(report["threshold_sweep"], indent=2, allow_nan=False))
    columns = ("threshold", "precision", "recall", "f1", "fpr", "fnr", "accepted")
    table_md = ["# Validation threshold sweep", "", "| " + " | ".join(columns) + " |",
                "| " + " | ".join("---" for _ in columns) + " |"]
    for point in report["threshold_sweep"]:
        table_md.append("| " + " | ".join(str(point[c]) for c in columns) + " |")
    (report_dir / "threshold_sweep.md").write_text("\n".join(table_md) + "\n")
    (report_dir / "cross_school_error_analysis.md").write_text(analysis, encoding="utf-8")
    if params is None:
        print("No acceptable validation threshold; reports written, no model exported.")
        return
    if args.report_only:
        print(json.dumps({"status": "reports_ready_for_review", "threshold": params["threshold"],
                          "artifact_exported": False, "production_approved": False}))
        return
    artifact = {"schema_version": 1, "model_name": "cross-school-logistic",
                "version": args.version, **CONTRACT, **params,
                "threshold_version": args.version + "-validation-policy-1",
                "trained_at": datetime.now(timezone.utc).isoformat(),
                "dataset_version": args.dataset_version, "metrics": report["trusted_metrics"],
                "production_approved": False, "data_provenance": {
                    "dataset_sha256": report["dataset_sha256"],
                    "embedding_values_sha256": report["embedding_values_sha256"],
                    "ids": sorted(r["id"] for r in rows),
                    "input_hashes": sorted(input_hash(r) for r in rows),
                    "template_families": sorted(set(r["template_family"] for r in rows)),
                }}
    validate_model(artifact)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(artifact, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"status": report["status"], "threshold": params["threshold"],
                      "production_approved": False}))


if __name__ == "__main__":
    main()
