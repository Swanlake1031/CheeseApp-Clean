"""Deterministic, order-independent group splits with connected-family safety."""
import argparse
import hashlib
import json
from collections import Counter
from .schema import load_dataset


def grouped_split(rows, seed=20260909):
    # Conservatively join ALL rows sharing either a scenario or a template.
    # This prevents a teacher reusing a template under two scenario names from
    # leaking across splits. Metadata must describe real paraphrase families.
    parents = {r["id"]: r["id"] for r in rows}

    def root(key):
        while parents[key] != key:
            parents[key] = parents[parents[key]]
            key = parents[key]
        return key

    owners = {}
    for row in sorted(rows, key=lambda r: r["id"]):
        keys = [(field, row[field]) for field in ("scenario_group", "template_family")]
        keys += [("reviewed_link", group) for group in row.get("leakage_groups", [])]
        for key in keys:
            if key in owners:
                parents[root(row["id"])] = root(owners[key])
            owners[key] = row["id"]
    components = {}
    for row in rows:
        components.setdefault(root(row["id"]), []).append(row)
    groups = sorted(components.values(), key=lambda group: hashlib.sha256(
        (str(seed) + ":" + ",".join(sorted(r["id"] for r in group))).encode()
    ).hexdigest())
    if len(groups) < 7:
        raise ValueError("Need at least seven independent scenario/template components")
    n_train = max(1, round(len(groups) * .70))
    n_valid = max(1, round(len(groups) * .15))
    partitions = {
        "train": groups[:n_train],
        "validation": groups[n_train:n_train+n_valid],
        "test": groups[n_train+n_valid:],
    }
    return {name: sorted((r for g in groups for r in g), key=lambda r: r["id"])
            for name, groups in partitions.items()}


def training_rows(rows, confidence_threshold=.8):
    if not 0 <= confidence_threshold <= 1:
        raise ValueError("Invalid confidence threshold")
    if any(r["dataset_kind"] != "synthetic" for r in rows):
        raise ValueError("Real holdout must never enter training or threshold selection")
    return [r for r in rows if r["teacher_confidence"] >= confidence_threshold]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--seed", type=int, default=20260909)
    args = parser.parse_args()
    rows = load_dataset(args.dataset)
    result = {"rows": len(rows), "labels": dict(Counter(r["label"] for r in rows)),
              "buckets": dict(Counter(r["bucket"] for r in rows)),
              "splits": {k: {"rows": len(v), "ids": [r["id"] for r in v],
                              "labels": dict(Counter(r["label"] for r in v))}
                         for k, v in grouped_split(rows, args.seed).items()}}
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
