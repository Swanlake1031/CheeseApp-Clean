"""Lossless label import from the supplied teacher CSV; no relabeling."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
from .schema import load_dataset, validate_row

FIELDS = {"id", "text", "origin_campus", "label", "teacher_confidence",
          "teacher_p_cross", "scenario_group", "scenario_family", "difficulty_bucket",
          "label_source", "recommended_use", "notes"}
BUCKET_MAP = {"strong_local": "local", "strong_cross": "cross", "hard_ambiguous": "hard"}


def import_rows(path, *, board_name, text_field, group_links=None):
    if not board_name.strip() or text_field not in {"title", "body"}:
        raise ValueError("Explicit --board-name and --text-field title/body are required")
    source_hash = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    with Path(path).open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if set(reader.fieldnames or []) != FIELDS or len(reader.fieldnames or []) != len(FIELDS):
            raise ValueError("Teacher CSV schema differs; review field mappings before import")
        rows = []
        for source in reader:
            if set(source) != FIELDS or any(not isinstance(v, str) for v in source.values()):
                raise ValueError("Teacher CSV row has missing or extra fields")
            if source["label"] not in {"0", "1"}:
                raise ValueError("Invalid hard label")
            if source["difficulty_bucket"] not in BUCKET_MAP:
                raise ValueError("Unknown difficulty bucket")
            row = {"id": source["id"], "text": source["text"],
                   "title": source["text"] if text_field == "title" else "",
                   "body": source["text"] if text_field == "body" else "",
                   "board_name": board_name, "origin_campus": source["origin_campus"],
                   "label": int(source["label"]),
                   "teacher_confidence": float(source["teacher_confidence"]),
                   "teacher_probability": float(source["teacher_p_cross"]),
                   "scenario_group": source["scenario_group"],
                   "template_family": source["scenario_family"],
                   "bucket": BUCKET_MAP[source["difficulty_bucket"]],
                   "dataset_kind": "synthetic", "label_source": source["label_source"],
                   "recommended_use": source["recommended_use"], "notes": source["notes"],
                   "source_sha256": source_hash,
                   "input_mapping": f"text_to_{text_field}_constant_board_v1"}
            validate_row(row)
            rows.append(row)
    if not rows or len({r["id"] for r in rows}) != len(rows) or len({r["text"] for r in rows}) != len(rows):
        raise ValueError("Empty or duplicate source data")
    if group_links:
        known_ids = {r["id"] for r in rows}
        for group, ids in group_links.items():
            if not isinstance(ids, list) or not ids or not set(ids) <= known_ids:
                raise ValueError("Group links reference missing IDs")
            for row in rows:
                if row["id"] in ids:
                    row.setdefault("leakage_groups", []).append(group)
                    validate_row(row)
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--board-name", required=True)
    p.add_argument("--text-field", choices=["title", "body"], required=True)
    p.add_argument("--group-links", help="Reviewed cross-scenario family links JSON; never relabels")
    args = p.parse_args()
    links = json.loads(Path(args.group_links).read_text()) if args.group_links else None
    rows = import_rows(args.input, board_name=args.board_name, text_field=args.text_field, group_links=links)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("x", encoding="utf-8") as handle:
        handle.write("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
    load_dataset(out)
    print(json.dumps({"rows": len(rows), "source_sha256": rows[0]["source_sha256"],
                      "trusted": sum(r["teacher_confidence"] >= .8 for r in rows)}))


if __name__ == "__main__":
    main()
