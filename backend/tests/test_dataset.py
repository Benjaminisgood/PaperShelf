import argparse
import copy
import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from papershelf_pipeline.dataset import (
    DatasetError, apply_corrections, export_dataset, project_graph,
    query_graph, register_subcommands, validate_extraction, validate_fields,
)


def fixtures():
    source = {"path": "/papers/experiment.pdf", "sha256": "a" * 64, "blocks": [
        {"id": "p1-b1", "page": 1, "text": "Sample A was tested at 400 K and its yield was 20 percent."},
        {"id": "p2-b1", "page": 2, "text": "Sample B was tested at 500 K and its yield was 70 percent."},
        {"id": "p2-b2", "page": 2, "text": "A later table corrects the yield of Sample A to 25 percent."},
    ]}
    fields = [
        {"name": "sample", "type": "string", "required": True},
        {"name": "temperature", "type": "number", "unit": "K", "required": True},
        {"name": "yield", "type": "number", "unit": "%"},
        {"name": "unreported", "type": "string", "required": True},
    ]
    records = []
    for index, (sample, temperature, yield_) in enumerate((("A", 400, 20), ("B", 500, 70))):
        evidence = [{"block_id": source["blocks"][index]["id"], "page": index + 1,
                     "quote": source["blocks"][index]["text"]}]
        records.append({"id": f"record-{sample}", "label": f"Sample {sample}", "values": {
            "sample": {"value": sample, "status": "supported", "evidence": evidence},
            "temperature": {"value": temperature, "status": "supported", "evidence": evidence, "unit": "K"},
            "yield": {"value": yield_, "status": "supported", "evidence": evidence, "unit": "%"},
            "unreported": {"value": None, "status": "not_found", "evidence": []},
        }})
    return {"schema_version": 1, "fields": fields, "records": records, "warnings": []}, source


class DatasetTests(unittest.TestCase):
    def test_required_missing_is_explicit_warning_not_invented_data(self):
        extraction, source = fixtures()
        warnings = validate_extraction(extraction, source)
        self.assertEqual(len(warnings), 2)
        self.assertTrue(all("unreported" in item for item in warnings))
        self.assertIsNone(extraction["records"][0]["values"]["unreported"]["value"])

    def test_types_enums_and_nested_custom_fields(self):
        extraction, source = fixtures()
        extraction["fields"] = [{"name": "任意字段", "type": "object", "properties": {
            "phase": {"type": "string", "enum": ["alpha", "beta"], "required": True},
            "counts": {"type": "array", "items": "integer"},
        }}]
        evidence = extraction["records"][0]["values"]["sample"]["evidence"]
        extraction["records"] = [{"id": "custom", "values": {"任意字段": {
            "value": {"phase": "alpha", "counts": [1, 2]}, "status": "supported", "evidence": evidence,
        }}}]
        self.assertEqual(validate_extraction(extraction, source), [])
        cell = extraction["records"][0]["values"]["任意字段"]
        for invalid in ({"phase": "gamma"}, {"phase": "alpha", "counts": [True]},
                        {"counts": [2]}, {"phase": "alpha", "unexpected": 2}):
            with self.subTest(invalid=invalid):
                cell["value"] = invalid
                with self.assertRaises(DatasetError):
                    validate_extraction(extraction, source)

    def test_invalid_types_finite_numbers_and_duplicate_names_rejected(self):
        for invalid in (True, "400", float("nan"), float("inf")):
            extraction, source = fixtures()
            extraction["records"][0]["values"]["temperature"]["value"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(DatasetError):
                validate_extraction(extraction, source)
        with self.assertRaises(DatasetError):
            validate_fields([{"name": "x"}, {"name": "x"}])
        with self.assertRaises(DatasetError):
            validate_fields([{"name": "x", "type": "number", "enum": ["bad"]}])

    def test_evidence_requires_actual_quote_and_correct_page(self):
        for change in ({"quote": "There was a yield of 99 percent."}, {"page": 9}, {"block_id": "absent"}):
            extraction, source = fixtures()
            evidence = extraction["records"][0]["values"]["sample"]["evidence"][0]
            evidence.update(change)
            with self.subTest(change=change), self.assertRaises(DatasetError):
                validate_extraction(extraction, source)
        extraction, source = fixtures()
        extraction["records"][0]["values"]["sample"]["evidence"][0]["quote"] = "Sample A was\n tested at 400 K"
        validate_extraction(extraction, source)

    def test_reported_fact_requires_evidence_and_missing_value_is_null(self):
        extraction, source = fixtures()
        extraction["records"][0]["values"]["sample"]["evidence"] = []
        with self.assertRaises(DatasetError):
            validate_extraction(extraction, source)
        extraction, source = fixtures()
        extraction["records"][0]["values"]["unreported"]["value"] = "fabricated"
        with self.assertRaises(DatasetError):
            validate_extraction(extraction, source)

    def test_exports_keep_all_records_types_units_evidence_and_missing_status(self):
        extraction, source = fixtures()
        with tempfile.TemporaryDirectory() as directory:
            artifacts = export_dataset(extraction, Path(directory), source)
            self.assertEqual(set(artifacts), {"csv", "tsv", "graph"})
            for kind, delimiter in (("csv", ","), ("tsv", "\t")):
                with open(artifacts[kind], encoding="utf-8-sig", newline="") as handle:
                    rows = list(csv.DictReader(handle, delimiter=delimiter))
                self.assertEqual(len(rows), 2)
                self.assertEqual(rows[0]['value["temperature"]'], "400")
                self.assertEqual(rows[1]['value["yield"]'], "70")
                self.assertEqual(rows[0]['status["unreported"]'], "not_found")
                self.assertEqual(rows[0]['unit["temperature"]'], "K")
                self.assertEqual(json.loads(rows[1]['evidence["yield"]'])[0]["page"], 2)
            graph = json.loads(Path(artifacts["graph"]).read_text())
            self.assertEqual(len([node for node in graph["nodes"] if node["type"] == "evidence"]), 2)
            self.assertFalse(any(node.get("field") == "unreported" for node in graph["nodes"]))

    def test_text_formula_escape_preserves_raw_json_and_numeric_values(self):
        extraction, source = fixtures()
        extraction["records"][0]["label"] = "=2+2"
        extraction["records"][0]["values"]["sample"]["value"] = "@formula"
        extraction["records"][0]["values"]["yield"]["value"] = -20
        with tempfile.TemporaryDirectory() as directory:
            artifacts = export_dataset(extraction, Path(directory), source)
            with open(artifacts["csv"], encoding="utf-8-sig", newline="") as handle:
                row = next(csv.DictReader(handle))
            self.assertEqual(row["record_label"], "'=2+2")
            self.assertEqual(row['value["sample"]'], "'@formula")
            self.assertEqual(row['value["yield"]'], "-20")
            graph = json.loads(Path(artifacts["graph"]).read_text())
            self.assertIn("@formula", [node.get("value") for node in graph["nodes"]])

    def test_filters_do_not_combine_different_samples_conditions(self):
        extraction, source = fixtures()
        graph = project_graph(extraction, source)
        filters = [{"field": "temperature", "op": "eq", "value": 400, "unit": "K"},
                   {"field": "yield", "op": "gt", "value": 50, "unit": "%"}]
        self.assertEqual(query_graph(graph, filters=filters)["count"], 0)
        filters[0]["value"] = 500
        result = query_graph(graph, filters=filters)
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["records"][0]["record_id"], "record-B")
        self.assertTrue(all(fact["evidence"] for fact in result["records"][0]["facts"]))
        filters[0]["unit"] = "C"
        self.assertEqual(query_graph(graph, filters=filters)["count"], 0)

    def test_search_conflicts_and_dynamic_unknown_field(self):
        extraction, source = fixtures()
        extraction["records"][0]["values"]["yield"]["status"] = "conflict"
        graph = project_graph(extraction, source)
        result = query_graph(graph, query="Sample A 400")
        self.assertEqual(result["count"], 1)
        self.assertEqual(next(f for f in result["records"][0]["facts"] if f["field"] == "yield")["status"], "conflict")
        with self.assertRaises(DatasetError):
            query_graph(graph, filters=[{"field": "not_configured", "value": 1}])

    def test_corrections_preserve_original_and_chain_audit(self):
        extraction, source = fixtures()
        original = copy.deepcopy(extraction)
        replacement = {"value": 25, "status": "supported", "unit": "%", "evidence": [
            {"block_id": "p2-b2", "page": 2, "quote": source["blocks"][2]["text"]}]}
        correction = {"record_id": "record-A", "field": "yield", "reason": "Checked later table", "after": replacement}
        reviewed = apply_corrections(extraction, [correction], "reviewer", source)
        self.assertEqual(extraction, original)
        event = reviewed["review_history"][0]
        self.assertEqual(event["before"]["value"], 20)
        self.assertEqual(event["after"]["value"], 25)
        self.assertEqual(event["actor"], "reviewer")
        second = apply_corrections(reviewed, [correction], "second-reviewer", source)
        self.assertEqual(second["review_history"][1]["previous_event_sha256"], event["event_sha256"])
        correction["after"]["value"] = "incorrect type"
        with self.assertRaises(DatasetError):
            apply_corrections(extraction, [correction], "reviewer", source)
        self.assertEqual(extraction, original)

    def test_unit_mismatch_is_reported_without_silent_conversion(self):
        extraction, source = fixtures()
        extraction["records"][0]["values"]["temperature"]["unit"] = "C"
        warnings = validate_extraction(extraction, source)
        self.assertTrue(any("no conversion" in warning for warning in warnings))
        self.assertEqual(extraction["records"][0]["values"]["temperature"]["value"], 400)

    def test_projection_cannot_overwrite_reserved_node_keys(self):
        extraction, source = fixtures()
        extraction["warnings"] = ["Supplementary information was not supplied."]
        extraction["records"][0]["values"]["sample"]["evidence"][0].update(id="injected", type="fact")
        graph = project_graph(extraction, source)
        self.assertIn("Supplementary information was not supplied.", graph["warnings"])
        self.assertFalse(any(node["id"] == "injected" for node in graph["nodes"]))
        self.assertEqual(query_graph(graph)["count"], 2)

    def test_review_history_tamper_and_object_required_properties(self):
        extraction, source = fixtures()
        correction = {"record_id": "record-A", "field": "yield", "reason": "Verify reported result",
                      "after": copy.deepcopy(extraction["records"][0]["values"]["yield"])}
        reviewed = apply_corrections(extraction, [correction], "reviewer", source)
        reviewed["review_history"][0]["reason"] = "altered history"
        with self.assertRaisesRegex(DatasetError, "integrity"):
            apply_corrections(reviewed, [correction], "reviewer", source)
        extraction["fields"].append({"name": "conditions", "type": "object", "properties": {
            "pressure": {"type": "number"}}, "required_properties": ["pressure"]})
        extraction["records"][0]["values"]["conditions"] = {
            "value": {}, "status": "supported", "evidence": correction["after"]["evidence"]}
        with self.assertRaisesRegex(DatasetError, "pressure"):
            validate_extraction(extraction, source)

    def test_supplement_evidence_has_file_identity_and_changes_graph_identity(self):
        extraction, source = fixtures()
        source["documents"] = [{"name": "paper.pdf", "role": "main", "sha256": "a" * 64},
                               {"name": "SI.pdf", "role": "supplement", "sha256": "b" * 64}]
        source["blocks"][1].update(document="SI.pdf", document_id="s1")
        graph = project_graph(extraction, source)
        result = query_graph(graph, filters=[{"field": "sample", "value": "B"}])
        evidence = result["records"][0]["facts"][0]["evidence"][0]
        self.assertEqual(evidence["document"], "SI.pdf")
        self.assertEqual(evidence["document_id"], "s1")
        self.assertEqual(result["source"]["documents"][1]["name"], "SI.pdf")
        source["documents"][1]["sha256"] = "c" * 64
        updated = project_graph(extraction, source)
        self.assertNotEqual(graph["nodes"][0]["id"], updated["nodes"][0]["id"])

    def test_cli_exports_queries_and_review_preserves_original(self):
        extraction, source = fixtures()
        module = Path(__file__).resolve().parents[1] / "papershelf_pipeline/dataset.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path, source_path = root / "extraction.json", root / "source.json"
            input_path.write_text(json.dumps(extraction))
            source_path.write_text(json.dumps(source))
            exported = subprocess.run([sys.executable, str(module), "dataset-export", "--extraction", str(input_path),
                                       "--source", str(source_path), "--output", str(root / "exports")],
                                      capture_output=True, text=True, check=True)
            artifacts = json.loads(exported.stdout)
            queried = subprocess.run([sys.executable, str(module), "graph-query", "--graph", artifacts["graph"],
                                      "--filters", '[{"field":"sample","value":"B"}]'],
                                     capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(queried.stdout)["records"][0]["record_id"], "record-B")
            parser = argparse.ArgumentParser()
            register_subcommands(parser.add_subparsers(required=True))
            args = parser.parse_args(["dataset-review", "--extraction", str(input_path), "--source", str(source_path),
                                      "--corrections", "unused.json", "--actor", "reviewer", "--output", str(input_path)])
            with self.assertRaises(DatasetError):
                args.func(args)
            self.assertEqual(json.loads(input_path.read_text()), extraction)


if __name__ == "__main__":
    unittest.main()
