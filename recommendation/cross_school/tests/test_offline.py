import copy
import json
import math
import os
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import numpy as np

from recommendation.cross_school.classifier import gate, load_model, predict, sigmoid, validate_model
from recommendation.cross_school.dataset import grouped_split, training_rows
from recommendation.cross_school.evaluate import ensure_untouched_holdout, evaluation, error_analysis
from recommendation.cross_school.schema import CONTRACT, canonical_input, cache_key, input_hash, load_dataset, load_embedding, validate_row
from recommendation.cross_school.threshold import metrics, select_threshold, sweep
from recommendation.cross_school.train import fit_student, train_experiment, main as train_main
from recommendation.cross_school.import_teacher_csv import import_rows, FIELDS

ROOT = Path(__file__).resolve().parents[1]


def model_fixture():
    return {"schema_version": 1, "model_name": "cross-school-logistic",
            "version": "v1-math-fixture", **CONTRACT,
            "weights": [2., -1.] + [0.] * (CONTRACT["dimension"]-2), "bias": -.5,
            "threshold": .8, "threshold_version": "math-policy-1",
            "trained_at": "2026-09-09T00:00:00+00:00", "dataset_version": "math-only-not-semantic",
            "metrics": {}, "production_approved": False}


class OfflineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = load_dataset(ROOT / "data/synthetic_v1.jsonl")

    def test_dataset_balance_and_composition(self):
        self.assertEqual(len(self.rows), 300)
        self.assertEqual({b: sum(r["bucket"] == b for r in self.rows) for b in ("local", "cross", "hard")},
                         {"local": 100, "cross": 100, "hard": 100})
        self.assertEqual(sum(r["label"] == 1 for r in self.rows), 151)

    def test_user_teacher_dataset_integrity(self):
        rows = load_dataset(ROOT / "data/teacher_v01.jsonl")
        self.assertEqual(len(rows), 300)
        self.assertEqual(sum(r["label"] for r in rows), 150)
        self.assertEqual(len(training_rows(rows)), 200)
        self.assertEqual(len({r["scenario_group"] for r in rows}), 25)
        self.assertTrue(all(r["title"] == "" and r["body"] == r["text"] for r in rows))
        split = grouped_split(rows)
        names = [{r["scenario_group"] for r in v} for v in split.values()]
        self.assertFalse(names[0] & names[1] | names[0] & names[2] | names[1] & names[2])
        self.assertEqual(sum(len(v) for v in split.values()), 300)
        assigned = {r["id"]: name for name, group in split.items() for r in group}
        links = json.loads((ROOT / "data/teacher_v01_group_links.json").read_text())
        for ids in links.values():
            self.assertEqual(len({assigned[row_id] for row_id in ids}), 1)

    def test_teacher_csv_preserves_labels_probability_and_quotes(self):
        import csv
        source = {"id": "quoted-1", "text": '中文, "quoted"\n正文', "origin_campus": "McMaster",
                  "label": "0", "teacher_confidence": "0.71", "teacher_p_cross": "0.4",
                  "scenario_group": "campus_building", "scenario_family": "campus_building_local_1",
                  "difficulty_bucket": "hard_ambiguous", "label_source": "teacher",
                  "recommended_use": "hard_review_holdout", "notes": "do not embed me"}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "teacher.csv"
            with path.open("w", newline="", encoding="utf-8-sig") as handle:
                writer = csv.DictWriter(handle, fieldnames=sorted(FIELDS))
                writer.writeheader()
                writer.writerow(source)
            row = import_rows(path, board_name="校园生活", text_field="body")[0]
        self.assertEqual(row["body"], source["text"])
        self.assertEqual(row["label"], 0)
        self.assertEqual(row["teacher_probability"], .4)
        self.assertNotIn(source["notes"], canonical_input(row))

    def test_invalid_rows_rejected(self):
        for key, value in [("label", True), ("label", None), ("label", 3),
                           ("teacher_confidence", math.nan), ("teacher_confidence", 1.1),
                           ("scenario_group", ""), ("text", "unrelated"),
                           ("teacher_probability", -1)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate_row({**self.rows[0], key: value})

    def test_teacher_csv_rejects_duplicate_header_and_ragged_rows(self):
        import csv
        headers = sorted(FIELDS)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "invalid.csv"
            for header, row in ((headers + [headers[0]], None),
                                (headers, ["x"] * (len(headers) + 1)),
                                (headers, ["x"] * (len(headers) - 1))):
                with path.open("w", newline="", encoding="utf-8") as handle:
                    writer = csv.writer(handle)
                    writer.writerow(header)
                    if row:
                        writer.writerow(row)
                with self.assertRaises(ValueError):
                    import_rows(path, board_name="校园生活", text_field="body")

    def test_duplicate_ids_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "duplicate.jsonl"
            path.write_text((json.dumps(self.rows[0])+"\n")*2)
            with self.assertRaises(ValueError):
                load_dataset(path)

    def test_order_independent_deterministic_split(self):
        a = grouped_split(self.rows)
        self.assertEqual(a, grouped_split(list(reversed(self.rows))))
        self.assertEqual({k: len(v) for k, v in a.items()}, {"train": 210, "validation": 45, "test": 45})
        self.assertNotEqual(a, grouped_split(self.rows, 7))

    def test_scenario_and_template_disjoint(self):
        split = grouped_split(self.rows)
        for field in ("id", "scenario_group", "template_family"):
            sets = [{r[field] for r in rows} for rows in split.values()]
            for i in range(3):
                for j in range(i):
                    self.assertFalse(sets[i] & sets[j])

    def test_reused_template_unites_two_scenarios(self):
        split = grouped_split(self.rows)
        assigned = {r["scenario_group"]: name for name, rows in split.items() for r in rows}
        self.assertEqual(assigned["specific_course"], assigned["exam_stress"])

    def test_low_confidence_is_review_only(self):
        self.assertEqual(len(training_rows(self.rows)), 280)
        self.assertEqual(len(training_rows(self.rows, .7)), 300)
        self.assertTrue(all(r["teacher_confidence"] >= .8 for r in training_rows(self.rows)))

    def test_real_holdout_never_trains(self):
        with self.assertRaises(ValueError):
            training_rows([{**self.rows[0], "dataset_kind": "real_holdout"}])

    def test_private_identifiers_rejected(self):
        with self.assertRaises(ValueError):
            validate_row({**self.rows[0], "user_id": "production-person"})

    def test_sql_equivalent_btrim_preserves_tabs(self):
        row = {"title": "  PG\t ", "body": " \n中文\t ", "board_name": "校园生活"}
        self.assertEqual(canonical_input(row), "task: sentence similarity | query: Title: PG\t\nBody: \n中文\t\nHashtags: #校园生活")
        self.assertEqual(len(input_hash(row)), 64)
        self.assertEqual(input_hash(row), input_hash({**row, "label": 1, "notes": "never a feature"}))

    def test_cache_rejects_wrong_version_dimension_and_hash(self):
        row = self.rows[0]
        record = {**CONTRACT, "input_hash": input_hash(row), "generated_at": "2026-09-09T00:00:00Z",
                  "values": [1.] + [0.] * 767}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / (cache_key(row)+".json")
            path.write_text(json.dumps(record))
            self.assertEqual(load_embedding(row, tmp), record["values"])
            for key, value in [("embedding_model", "other"), ("input_hash", "0"*64),
                               ("values", [1.]), ("values", [math.nan] + [0.]*767),
                               ("values", [0.]*768)]:
                path.write_text(json.dumps({**record, key: value}))
                with self.assertRaises(ValueError):
                    load_embedding(row, tmp)

    def test_logistic_dot_bias_determinism(self):
        vector = [.6, .8] + [0.]*766
        expected = 1/(1+math.exp(.1))  # 2*.6 - .8 - .5 = -.1
        self.assertAlmostEqual(predict(model_fixture(), vector), expected)
        self.assertEqual(predict(model_fixture(), vector), predict(model_fixture(), vector))

    def test_sigmoid_extremes(self):
        self.assertEqual(sigmoid(1000), 1.)
        self.assertEqual(sigmoid(-1000), 0.)
        self.assertEqual(sigmoid(0), .5)
        for value in (math.nan, math.inf, -math.inf):
            with self.assertRaises(ValueError):
                sigmoid(value)

    def test_invalid_artifacts(self):
        for key, value in [("schema_version", 2), ("version", "latest"), ("dimension", 7),
                           ("weights", []), ("bias", math.nan), ("threshold", True),
                           ("embedding_version", "other"), ("trained_at", "not-a-date")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_model({**model_fixture(), key: value})

    def test_missing_artifact(self):
        with self.assertRaises(FileNotFoundError):
            load_model(ROOT / "artifacts/nonexistent.json")

    def test_invalid_embedding(self):
        for vector in ([1.], [math.nan]+[0.]*767, [0.]*768):
            with self.assertRaises(ValueError):
                predict(model_fixture(), vector)

    def test_same_campus_ignores_all_classifier_failure(self):
        self.assertTrue(gate("mac", "mac", None, math.nan, compatible=False))

    def test_foreign_boundary_and_failure(self):
        self.assertTrue(gate("mac", "waterloo", .85, .8))
        self.assertTrue(gate("mac", "waterloo", .8, .8))
        self.assertFalse(gate("mac", "waterloo", .7999, .8))
        for q in (None, math.nan, math.inf, -1., 1.1):
            self.assertFalse(gate("mac", "waterloo", q, .8))
        self.assertFalse(gate(None, None, 1., .8))
        self.assertFalse(gate("mac", None, 1., .8))
        self.assertFalse(gate("mac", "waterloo", 1., .8, compatible=False))

    def test_confusion_fpr_and_threshold_sweep(self):
        labels, scores = [0, 0, 1, 1], [.1, .8, .8, .2]
        m = metrics(labels, scores, .8)
        self.assertEqual(m["confusion_matrix"], [[1, 1], [1, 1]])
        self.assertEqual(m["fpr"], .5)
        self.assertEqual(m["fnr"], .5)
        table = sweep(labels, scores)
        self.assertEqual([r["threshold"] for r in table], [.5,.55,.6,.65,.7,.75,.8,.85,.9,.95])
        self.assertTrue(all(table[i]["accepted"] >= table[i+1]["accepted"] for i in range(9)))
        self.assertIsNone(select_threshold(table, max_fpr=.01))
        self.assertIsNone(metrics([1], [.5], .8)["fpr"])

    def test_threshold_does_not_select_reject_everything(self):
        self.assertIsNone(select_threshold(sweep([0, 1], [.1, .1]), min_recall=0))
        point = select_threshold(sweep([0, 1], [.1, .9]))
        self.assertEqual(point["threshold"], .9)

    def test_fit_reproducible_math_fixture_only(self):
        x = [[-1.,0.],[-.9,.1],[1.,0.],[.9,.1]]
        a, b = fit_student(x, [0,0,1,1]), fit_student(x, [0,0,1,1])
        np.testing.assert_array_equal(a.coef_, b.coef_)
        self.assertLess(a.predict_proba([[-1.,0.]])[0,1], .5)
        self.assertGreater(a.predict_proba([[1.,0.]])[0,1], .5)

    def test_optional_soft_labels(self):
        x = [[-1.,0.],[-.9,.1],[1.,0.],[.9,.1]]
        hard = fit_student(x, [0,0,1,1])
        soft = fit_student(x, [0,0,1,1], soft_targets=[0,0,1,1])
        np.testing.assert_allclose(hard.coef_, soft.coef_, atol=1e-7)
        with self.assertRaises(ValueError):
            fit_student(x, [0,0,1,1], soft_targets=[0,math.nan,1,1])

    def test_pipeline_reproducible_on_explicit_fake_vectors(self):
        # Algebra/plumbing fixture ONLY; not a semantic experiment or reported accuracy.
        vectors = {r["id"]: [1. if r["label"] else -1., 0.] for r in self.rows}
        a = train_experiment(self.rows, vectors)
        b = train_experiment(list(reversed(self.rows)), vectors)
        self.assertEqual(a, b)
        self.assertIsNotNone(a[0])
        self.assertIn("test", a[1]["trusted_metrics"])

    def test_rejected_experiment_keeps_diagnostics_without_artifact(self):
        # Identical numeric fixtures intentionally contain no predictive signal.
        vectors = {r["id"]: [1., 0.] for r in self.rows}
        params, report, analysis = train_experiment(self.rows, vectors)
        self.assertIsNone(params)
        self.assertIsNone(report["selected_validation_point"])
        self.assertEqual(report["status"], "no_acceptable_threshold")
        self.assertEqual(report["evaluation_threshold"], .5)
        self.assertEqual(report["evaluation_threshold_role"],
                         "fixed_diagnostic_only_not_for_deployment")
        self.assertEqual(set(report["trusted_metrics"]), {"train", "validation", "test"})
        self.assertIn("No artifact was exported", analysis)
        self.assertIn("False positives", analysis)
        self.assertIn("False negatives", analysis)

    def test_test_predictions_never_select_threshold(self):
        # Synthetic algebra fixtures only: reverse test signal, preserve training
        # and validation, and prove neither weights nor selection can change.
        vectors = {r["id"]: [1. if r["label"] else -1., 0.] for r in self.rows}
        params, report, _ = train_experiment(self.rows, vectors)
        changed = dict(vectors)
        for row in grouped_split(self.rows)["test"]:
            changed[row["id"]] = [-v for v in changed[row["id"]]]
        other_params, other_report, _ = train_experiment(self.rows, changed)
        self.assertEqual(params, other_params)
        self.assertEqual(report["selected_validation_point"], other_report["selected_validation_point"])
        self.assertNotEqual(report["trusted_metrics"]["test"], other_report["trusted_metrics"]["test"])

    def test_report_only_never_exports_candidate(self):
        # Explicit algebra fixtures: this tests the export gate, not model quality.
        with tempfile.TemporaryDirectory() as tmp:
            model, reports = Path(tmp) / "model.json", Path(tmp) / "reports"
            args = ["train", "--dataset", str(ROOT / "data/synthetic_v1.jsonl"),
                    "--dataset-version", "math-only", "--cache", tmp,
                    "--output-model", str(model), "--report-dir", str(reports), "--report-only"]
            with patch("sys.argv", args), patch("recommendation.cross_school.train.load_embedding",
                    side_effect=lambda row, cache: [1. if row["label"] else -1., 0.]), patch("builtins.print"):
                train_main()
            self.assertFalse(model.exists())
            self.assertTrue((reports / "cross_school_error_analysis.md").exists())
            report = json.loads((reports / "evaluation.json").read_text())
            self.assertIsNotNone(report["selected_validation_point"])

    def test_holdout_overlap_rejected(self):
        row = {**self.rows[0], "id": "anon-1", "dataset_kind": "real_holdout", "anonymized": True}
        with self.assertRaises(ValueError):
            ensure_untouched_holdout([row], {"data_provenance": {"input_hashes": [input_hash(row)]}})

    def test_evaluation_reports_errors_and_uncertainty(self):
        rows = [{**self.rows[0], "label": 0}, {**self.rows[1], "label": 1}]
        result = evaluation(rows, [.9, .1], .8)
        self.assertEqual(result["roc_auc"], 0.)
        self.assertTrue(result["small_sample_warning"])
        report = error_analysis(rows, [.9, .1], .8)
        for section in ("False positives", "False negatives", "Nearest boundary", "Human interpretation"):
            self.assertIn(section, report)


@unittest.skipUnless(os.getenv("CROSS_SCHOOL_SANITY_MODEL") and os.getenv("CROSS_SCHOOL_SANITY_CACHE"),
                     "Semantic sanity awaits trained V1-embedding artifact/cache; not a passing semantic test")
class SemanticSanityTests(unittest.TestCase):
    def test_frozen_real_embedding_sanity(self):
        model = load_model(os.environ["CROSS_SCHOOL_SANITY_MODEL"])
        rows = load_dataset(ROOT / "data/sanity_v1.jsonl")
        for row in rows:
            q = predict(model, load_embedding(row, os.environ["CROSS_SCHOOL_SANITY_CACHE"]))
            with self.subTest(text=row["text"]):
                self.assertEqual(int(q >= model["threshold"]), row["label"])


if __name__ == "__main__":
    unittest.main()
