"""Validation-only operating point selection; no 'best threshold' guess."""
import math
from .schema import probability


def metrics(labels, scores, threshold):
    if not labels or len(labels) != len(scores) or not probability(threshold):
        raise ValueError("Invalid metric inputs")
    if any(type(y) is not int or y not in (0, 1) for y in labels):
        raise ValueError("Invalid binary label")
    if not all(probability(q) for q in scores):
        raise ValueError("Invalid probability")
    tp = sum(y == 1 and q >= threshold for y, q in zip(labels, scores))
    fp = sum(y == 0 and q >= threshold for y, q in zip(labels, scores))
    tn = sum(y == 0 and q < threshold for y, q in zip(labels, scores))
    fn = sum(y == 1 and q < threshold for y, q in zip(labels, scores))
    divide = lambda a, b: a / b if b else None
    return {"threshold": threshold, "confusion_matrix": [[tn, fp], [fn, tp]],
            "n": len(labels), "accuracy": (tp+tn)/len(labels),
            "precision": divide(tp, tp+fp), "recall": divide(tp, tp+fn),
            "f1": divide(2*tp, 2*tp+fp+fn), "fpr": divide(fp, fp+tn),
            "fnr": divide(fn, fn+tp), "accepted": tp+fp,
            "fpr_wilson_upper_95": wilson_upper(fp, fp+tn)}


def wilson_upper(successes, n):
    if not n:
        return None
    z = 1.959963984540054
    p = successes / n
    return (p + z*z/(2*n) + z*math.sqrt(p*(1-p)/n + z*z/(4*n*n))) / (1+z*z/n)


def sweep(labels, scores):
    return [metrics(labels, scores, i/100) for i in range(50, 100, 5)]


def select_threshold(table, max_fpr=.05, min_recall=.1):
    if not probability(max_fpr) or not probability(min_recall):
        raise ValueError("Invalid selection constraint")
    candidates = [m for m in table if m["fpr"] is not None and m["fpr"] <= max_fpr
                  and m["recall"] is not None and m["recall"] >= min_recall
                  and m["accepted"] > 0]
    # Maximize recall under explicit empirical FPR bound; break ties conservatively.
    return max(candidates, key=lambda m: (m["recall"], -m["fpr"], m["threshold"])) if candidates else None
