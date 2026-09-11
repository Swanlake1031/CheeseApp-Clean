"""Strict teacher JSONL and V1 representation contract; never infer labels."""
import hashlib
import json
import math
import re
from datetime import datetime
from pathlib import Path

CONTRACT = {
    "embedding_model": "gemini-embedding-2",
    "embedding_version": "cheese-semantic-v1",
    "input_format_version": 1,
    "dimension": 768,
}
GROUP = re.compile(r"^[a-z][a-z0-9_]{1,79}$")
BUCKETS = {"local", "cross", "hard"}


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def probability(value):
    return finite_number(value) and 0 <= value <= 1


def canonical_input(row):
    # PostgreSQL BTRIM(text) removes ASCII spaces, not tabs/newlines.
    return ("task: sentence similarity | query: Title: "
            + row["title"].strip(" ") + "\nBody: " + row["body"].strip(" ")
            + "\nHashtags: #" + row["board_name"])


def input_hash(row):
    return hashlib.sha256(canonical_input(row).encode("utf-8")).hexdigest()


def validate_row(row):
    if not isinstance(row, dict):
        raise ValueError("Dataset row must be an object")
    for key in ("id", "text", "origin_campus", "scenario_group", "label_source",
                "title", "body", "board_name", "template_family"):
        if not isinstance(row.get(key), str):
            raise ValueError(f"{key} must be a string")
    for key in ("id", "text", "origin_campus", "label_source", "board_name"):
        if not row[key].strip():
            raise ValueError(f"{key} must not be empty")
    if not row["title"].strip(" ") and not row["body"].strip(" "):
        raise ValueError("Title and body cannot both be empty")
    # Avoid scoring one text while displaying/analyzing a different teacher text.
    expected_text = "\n".join(v for v in (row["title"], row["body"]) if v)
    if row["text"] != expected_text:
        raise ValueError("text must exactly equal nonempty title/body joined by newline")
    for key in ("scenario_group", "template_family"):
        if not GROUP.fullmatch(row[key]):
            raise ValueError(f"Invalid {key}")
    links = row.get("leakage_groups", [])
    if not isinstance(links, list) or not all(isinstance(v, str) and GROUP.fullmatch(v) for v in links):
        raise ValueError("Invalid leakage_groups")
    if type(row.get("label")) is not int or row["label"] not in (0, 1):
        raise ValueError("label must be integer 0 or 1")
    if not probability(row.get("teacher_confidence")):
        raise ValueError("Invalid teacher_confidence")
    if "teacher_probability" in row and not probability(row["teacher_probability"]):
        raise ValueError("Invalid teacher_probability")
    if row.get("bucket") not in BUCKETS:
        raise ValueError("bucket must be local, cross or hard")
    if row.get("dataset_kind") not in {"synthetic", "real_holdout"}:
        raise ValueError("dataset_kind must be synthetic or real_holdout")
    if row["dataset_kind"] == "real_holdout":
        if row.get("anonymized") is not True or not row["id"].startswith("anon-"):
            raise ValueError("Real holdout needs anonymized=true and anon- IDs")
    if any(k in row for k in ("user_id", "author_id", "email", "phone")):
        raise ValueError("Do not include personal identifiers in datasets")
    return row


def load_dataset(path):
    rows = []
    ids = set()
    texts = set()
    for line_no, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = validate_row(json.loads(line))
            if row["id"] in ids or row["text"] in texts:
                raise ValueError("Duplicate ID or exact text")
        except (ValueError, TypeError) as exc:
            raise ValueError(f"Invalid dataset line {line_no}: {exc}") from exc
        ids.add(row["id"])
        texts.add(row["text"])
        rows.append(row)
    if not rows:
        raise ValueError("Empty dataset")
    return rows


def validate_vector(values, dimension):
    if not isinstance(values, list) or len(values) != dimension:
        raise ValueError("Embedding dimension mismatch")
    if not all(finite_number(v) for v in values):
        raise ValueError("Embedding has non-finite values")
    if abs(math.sqrt(math.fsum(v * v for v in values)) - 1) > 0.0001:
        raise ValueError("Expected V1 L2-normalized embedding")
    return values


def cache_key(row):
    return f"{CONTRACT['embedding_version']}-{CONTRACT['embedding_model']}-1-{input_hash(row)}"


def load_embedding(row, cache):
    record = json.loads((Path(cache) / (cache_key(row) + ".json")).read_text())
    for field, expected in CONTRACT.items():
        if type(record.get(field)) is not type(expected) or record[field] != expected:
            raise ValueError(f"Incompatible embedding {field}")
    if record.get("input_hash") != input_hash(row):
        raise ValueError("Stale or undated embedding")
    try:
        if datetime.fromisoformat(record["generated_at"].replace("Z", "+00:00")).tzinfo is None:
            raise ValueError("Embedding timestamp needs timezone")
    except (KeyError, AttributeError, TypeError) as exc:
        raise ValueError("Invalid embedding timestamp") from exc
    return validate_vector(record.get("values"), CONTRACT["dimension"])
