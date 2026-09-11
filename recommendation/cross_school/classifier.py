"""Auditable offline artifact/reference inference. Not connected to serving."""
import json
import math
import re
from datetime import datetime
from pathlib import Path
from .schema import CONTRACT, finite_number, probability, validate_vector


def sigmoid(z):
    if not finite_number(z):
        raise ValueError("Non-finite logit")
    if z >= 0:
        return 1 / (1 + math.exp(-z))
    exp_z = math.exp(z)
    return exp_z / (1 + exp_z)


def validate_model(model):
    if not isinstance(model, dict) or type(model.get("schema_version")) is not int or model["schema_version"] != 1:
        raise ValueError("Unsupported artifact schema")
    if model.get("model_name") != "cross-school-logistic":
        raise ValueError("Unsupported classifier")
    if not isinstance(model.get("version"), str) or not re.fullmatch(
            r"v[1-9][0-9]*(?:-[a-z0-9-]+)?", model["version"]):
        raise ValueError("Invalid model version")
    for key, value in CONTRACT.items():
        if type(model.get(key)) is not type(value) or model[key] != value:
            raise ValueError(f"Incompatible model {key}")
    if (not isinstance(model.get("weights"), list)
            or len(model["weights"]) != model["dimension"]
            or not all(finite_number(w) for w in model["weights"])
            or not finite_number(model.get("bias"))):
        raise ValueError("Invalid parameters")
    if not probability(model.get("threshold")):
        raise ValueError("Invalid threshold")
    if not isinstance(model.get("threshold_version"), str) or not model["threshold_version"]:
        raise ValueError("Missing threshold version")
    if not isinstance(model.get("dataset_version"), str) or not model["dataset_version"]:
        raise ValueError("Missing dataset version")
    if not isinstance(model.get("metrics"), dict):
        raise ValueError("Missing evaluation metadata")
    try:
        if datetime.fromisoformat(model["trained_at"].replace("Z", "+00:00")).tzinfo is None:
            raise ValueError("Timestamp needs timezone")
    except (KeyError, AttributeError, TypeError) as exc:
        raise ValueError("Invalid trained_at") from exc
    return model


def load_model(path):
    return validate_model(json.loads(Path(path).read_text()))


def predict(model, embedding):
    validate_model(model)
    validate_vector(embedding, model["dimension"])
    return sigmoid(math.fsum(w*x for w, x in zip(model["weights"], embedding)) + model["bias"])


def gate(origin_campus, viewer_campus, score, threshold, *, compatible=True):
    # Same campus bypasses even malformed threshold/model/score.
    if origin_campus and viewer_campus and origin_campus == viewer_campus:
        return True
    return bool(origin_campus and viewer_campus and compatible
                and probability(score) and probability(threshold) and score >= threshold)
