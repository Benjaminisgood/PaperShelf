"""Evidence-preserving datasets and graph queries, independent of any domain schema.

This implements PaperShelf's own extraction/review workflow.  It does not import
CATDA code.  Missing facts remain missing, and a projection never adds inferred
scientific relationships.  Functions accept the extraction.json/source.json
documents used by the learning pipeline; the CLI also works on saved runs.
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class DatasetError(ValueError):
    """The saved schema, extraction, correction or query is not valid."""


TYPES = {"string", "number", "integer", "boolean", "array", "object"}
STATUSES = {"supported", "not_found", "conflict"}


def _json(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise DatasetError(f"Value is not finite JSON: {exc}") from exc


def _digest(value: Any) -> str:
    return hashlib.sha256(_json(value).encode("utf-8")).hexdigest()


def _text(value: Any, where: str, *, optional: bool = False) -> str:
    if not isinstance(value, str) or (not optional and not value.strip()):
        raise DatasetError(f"{where} must be {'a string' if optional else 'a nonempty string'}.")
    return value


def _schema_type(spec: dict, where: str) -> None:
    if not isinstance(spec, dict) or spec.get("type", "string") not in TYPES:
        raise DatasetError(f"{where} has an unsupported type.")
    if "required" in spec and not isinstance(spec["required"], bool):
        raise DatasetError(f"{where}.required must be boolean.")
    for key in ("description", "unit"):
        if key in spec:
            _text(spec[key], f"{where}.{key}", optional=True)
    if "enum" in spec:
        choices = spec["enum"]
        if not isinstance(choices, list) or not choices:
            raise DatasetError(f"{where}.enum must contain at least one choice.")
        if len({_json(choice) for choice in choices}) != len(choices):
            raise DatasetError(f"{where}.enum has duplicate choices.")
        for choice in choices:
            _value(choice, {k: v for k, v in spec.items() if k != "enum"}, where)
    if "items" in spec:
        if spec.get("type") != "array":
            raise DatasetError(f"{where}.items is only valid for arrays.")
        _schema_type(_item_schema(spec["items"]), f"{where}.items")
    if "properties" in spec:
        if spec.get("type") != "object" or not isinstance(spec["properties"], dict):
            raise DatasetError(f"{where}.properties must describe an object.")
        for key, child in spec["properties"].items():
            _text(key, f"{where} property name")
            _schema_type(child, f"{where}.{key}")
    if "required_properties" in spec:
        required = spec["required_properties"]
        if (spec.get("type") != "object" or not isinstance(required, list)
                or any(not isinstance(key, str) or key not in spec.get("properties", {}) for key in required)):
            raise DatasetError(f"{where}.required_properties must name configured object properties.")


def _item_schema(item: Any) -> dict:
    return {"type": item} if isinstance(item, str) else item


def _value(value: Any, spec: dict, where: str) -> None:
    kind = spec.get("type", "string")
    valid = {
        "string": isinstance(value, str),
        "number": type(value) is int or (type(value) is float and math.isfinite(value)),
        "integer": type(value) is int,
        "boolean": type(value) is bool,
        "array": isinstance(value, list),
        "object": isinstance(value, dict),
    }[kind]
    if not valid:
        raise DatasetError(f"{where} must have type {kind}; found {type(value).__name__}.")
    _json(value)  # Reject nonfinite values inside otherwise-untyped objects/arrays too.
    if "enum" in spec and not any(_json(value) == _json(choice) for choice in spec["enum"]):
        raise DatasetError(f"{where} is not one of its configured enum choices.")
    if kind == "array" and "items" in spec:
        for index, item in enumerate(value):
            _value(item, _item_schema(spec["items"]), f"{where}[{index}]")
    if kind == "object" and "properties" in spec:
        properties = spec["properties"]
        unknown = set(value) - set(properties)
        if unknown:
            raise DatasetError(f"{where} has unknown properties: {', '.join(sorted(unknown))}.")
        for key, child in properties.items():
            if key not in value or value[key] is None:
                if child.get("required") or key in spec.get("required_properties", []):
                    raise DatasetError(f"{where}.{key} is required.")
            else:
                _value(value[key], child, f"{where}.{key}")


def validate_fields(fields: Any) -> dict[str, dict]:
    if not isinstance(fields, list):
        raise DatasetError("fields must be a list of custom field definitions.")
    result = {}
    for index, spec in enumerate(fields):
        if not isinstance(spec, dict):
            raise DatasetError(f"fields[{index}] must be an object.")
        name = _text(spec.get("name"), f"fields[{index}].name")
        if name != name.strip() or any(ord(char) < 32 for char in name) or name in result:
            raise DatasetError(f"Field name {name!r} is duplicate or contains surrounding whitespace/control characters.")
        _schema_type(spec, name)
        result[name] = spec
    return result


def _normalize_space(text: str) -> str:
    return " ".join(text.split())


def _evidence(evidence: Any, where: str, blocks: dict | None) -> None:
    if not isinstance(evidence, list):
        raise DatasetError(f"{where}.evidence must be a list.")
    for index, item in enumerate(evidence):
        here = f"{where}.evidence[{index}]"
        if not isinstance(item, dict):
            raise DatasetError(f"{here} must be an object.")
        block_id = _text(item.get("block_id"), f"{here}.block_id")
        quote = _text(item.get("quote"), f"{here}.quote")
        page = item.get("page")
        if type(page) is not int or page < 1:
            raise DatasetError(f"{here}.page must be a positive integer.")
        if blocks is not None:
            block = blocks.get(block_id)
            if block is None or block.get("page") != page:
                raise DatasetError(f"{here} refers to a missing block or incorrect source page.")
            if _normalize_space(quote) not in _normalize_space(block.get("text", "")):
                raise DatasetError(f"{here} quote does not occur in the referenced source block.")


def validate_extraction(extraction: dict, source: dict | None = None) -> list[str]:
    """Validate data types and evidence; return review warnings, never invent values."""
    if not isinstance(extraction, dict) or extraction.get("schema_version", 1) != 1:
        raise DatasetError("Unsupported extraction schema_version (expected 1).")
    _json(extraction)
    if not isinstance(extraction.get("warnings", []), list) or any(not isinstance(item, str) for item in extraction.get("warnings", [])):
        raise DatasetError("warnings must be a list of strings.")
    fields = validate_fields(extraction.get("fields"))
    records = extraction.get("records")
    if not isinstance(records, list):
        raise DatasetError("records must be a list.")
    blocks = None
    if source is not None:
        if not isinstance(source, dict) or not isinstance(source.get("blocks"), list):
            raise DatasetError("source.blocks must be a list for evidence verification.")
        blocks = {}
        for block in source["blocks"]:
            if not isinstance(block, dict):
                raise DatasetError("Every source block must be an object.")
            block_id = _text(block.get("id"), "source block id")
            _text(block.get("text"), f"source block {block_id}.text", optional=True)
            if type(block.get("page")) is not int or block["page"] < 1 or block_id in blocks:
                raise DatasetError("Source block page must be positive and block ids unique.")
            blocks[block_id] = block
    seen, warnings = set(), []
    for record in records:
        if not isinstance(record, dict):
            raise DatasetError("Every record must be an object.")
        record_id = _text(record.get("id"), "record.id")
        if record_id in seen:
            raise DatasetError(f"Duplicate record id {record_id!r}.")
        seen.add(record_id)
        if "label" in record:
            _text(record["label"], f"{record_id}.label", optional=True)
        values = record.get("values")
        if not isinstance(values, dict):
            raise DatasetError(f"{record_id}.values must be an object.")
        unknown = set(values) - set(fields)
        if unknown:
            raise DatasetError(f"{record_id} has unknown fields: {', '.join(sorted(unknown))}.")
        for name, spec in fields.items():
            cell = values.get(name)
            if cell is None:
                if spec.get("required"):
                    warnings.append(f"{record_id}.{name}: required field was not found.")
                continue
            where = f"{record_id}.{name}"
            if not isinstance(cell, dict) or "value" not in cell:
                raise DatasetError(f"{where} must contain a value, status and evidence.")
            status = cell.get("status")
            if status not in STATUSES:
                raise DatasetError(f"{where}.status must be supported, not_found or conflict.")
            value = cell["value"]
            evidence = cell.get("evidence", [])
            _evidence(evidence, where, blocks)
            if status == "not_found":
                if value is not None:
                    raise DatasetError(f"{where}: not_found values must be null.")
                if spec.get("required"):
                    warnings.append(f"{where}: required field was not found.")
            else:
                if not evidence:
                    raise DatasetError(f"{where}: reported facts require source evidence.")
                if value is None and status != "conflict":
                    raise DatasetError(f"{where}: supported values cannot be null.")
                if value is not None:
                    _value(value, spec, where)
                if status == "conflict":
                    warnings.append(f"{where}: conflicting evidence needs review.")
            for key in ("unit", "notes"):
                if key in cell:
                    _text(cell[key], f"{where}.{key}", optional=True)
            if value is not None and spec.get("unit") and cell.get("unit") != spec["unit"]:
                warnings.append(f"{where}: reported unit {cell.get('unit', '(unspecified)')!r} differs from configured {spec['unit']!r}; no conversion was applied.")
    if source is None:
        warnings.append("Source document was not supplied; evidence quotes were not checked against source blocks.")
    return warnings


def _tabular_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, dict, bool)):
        return _json(value)
    return str(value)


def _spreadsheet_text(value: str) -> str:
    # Prevent text from becoming an executable spreadsheet formula on import.
    return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value


def project_graph(extraction: dict, source: dict | None = None) -> dict:
    """Project explicit document/record/field/evidence links without inferred facts."""
    warnings = validate_extraction(extraction, source)
    warnings = list(dict.fromkeys(extraction.get("warnings", []) + warnings))
    source_info = {key: source[key] for key in ("path", "sha256") if source and key in source}
    if source and source.get("documents"):
        source_info["documents"] = copy.deepcopy(source["documents"])
        source_info["document_set_sha256"] = _digest([
            {key: document.get(key) for key in ("sha256", "role")} for document in source["documents"]])
    source_blocks = {block["id"]: block for block in source.get("blocks", [])} if source else {}
    doc_id = "document:" + (source_info.get("document_set_sha256") or source_info.get("sha256") or _digest(extraction))
    nodes = [{"id": doc_id, "type": "document", **source_info}]
    edges, evidence_nodes = [], set()
    field_map = validate_fields(extraction["fields"])
    for record in extraction["records"]:
        record_node = doc_id + ":record:" + record["id"]
        nodes.append({"id": record_node, "type": "record", "record_id": record["id"],
                      "label": record.get("label", record["id"])})
        edges.append({"source": doc_id, "target": record_node, "type": "contains_record"})
        for name, cell in record["values"].items():
            if cell["status"] == "not_found":
                continue
            fact_id = record_node + ":fact:" + _digest(name)[:16]
            nodes.append({"id": fact_id, "type": "fact", "record_id": record["id"], "field": name,
                          "value": cell["value"], "status": cell["status"], "unit": cell.get("unit", ""),
                          "notes": cell.get("notes", ""), "field_type": field_map[name].get("type", "string")})
            edges.append({"source": record_node, "target": fact_id, "type": "has_fact"})
            for evidence in cell["evidence"]:
                location = {key: evidence[key] for key in ("block_id", "page", "quote")}
                block = source_blocks.get(evidence["block_id"])
                if block is not None:
                    location["document_id"] = block.get("document_id", "main")
                    location["document"] = block.get("document", Path(source_info.get("path", "")).name)
                evidence_id = doc_id + ":evidence:" + _digest(location)[:20]
                if evidence_id not in evidence_nodes:
                    nodes.append({"id": evidence_id, "type": "evidence",
                                  **location})
                    evidence_nodes.add(evidence_id)
                edges.append({"source": fact_id, "target": evidence_id, "type": "supported_by"})
    return {"schema_version": 1, "kind": "evidence_projection", "fields": extraction["fields"],
            "source": source_info, "nodes": nodes, "edges": edges, "warnings": warnings,
            "notice": "Edges describe recorded provenance, not inferred causal or scientific relationships."}


def export_dataset(extraction: dict, run_dir: Path, source: dict | None = None) -> dict[str, str]:
    """Write one row per record, preserving status/unit/evidence for every field."""
    graph = project_graph(extraction, source)  # Validate before creating any outputs.
    run_dir = Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    names = [field["name"] for field in extraction["fields"]]
    # JSON labels prevent a field such as 'x.status' colliding with a companion column.
    columns = ["record_id", "record_label"]
    columns += [f"{part}[{_json(name)}]" for name in names for part in ("value", "status", "unit", "evidence", "notes")]
    paths = {}
    for kind, delimiter in (("csv", ","), ("tsv", "\t")):
        path = run_dir / f"dataset.{kind}"
        with path.open("w", newline="", encoding="utf-8-sig") as handle:
            writer = csv.writer(handle, delimiter=delimiter)
            writer.writerow(columns)
            for record in extraction["records"]:
                row = [_spreadsheet_text(record["id"]), _spreadsheet_text(record.get("label", ""))]
                for name in names:
                    cell = record["values"].get(name, {"value": None, "status": "not_found", "evidence": []})
                    value = _tabular_value(cell["value"])
                    if isinstance(cell["value"], str):
                        value = _spreadsheet_text(value)
                    row.extend((value, cell["status"], _spreadsheet_text(cell.get("unit", "")),
                                _json(cell.get("evidence", [])), _spreadsheet_text(cell.get("notes", ""))))
                writer.writerow(row)
        paths[kind] = str(path.resolve())
    graph_path = run_dir / "evidence-graph.json"
    graph_path.write_text(json.dumps(graph, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    paths["graph"] = str(graph_path.resolve())
    return paths


def apply_corrections(extraction: dict, corrections: list[dict], actor: str,
                      source: dict | None = None) -> dict:
    """Return an edited copy with before/after history; never mutate the source run."""
    validate_extraction(extraction, source)
    _text(actor, "actor")
    if not isinstance(corrections, list) or not corrections:
        raise DatasetError("corrections must be a nonempty list.")
    result = copy.deepcopy(extraction)
    records = {record["id"]: record for record in result["records"]}
    fields = validate_fields(result["fields"])
    events = result.setdefault("review_history", [])
    if not isinstance(events, list):
        raise DatasetError("review_history must be a list.")
    previous = None
    for event in events:
        if (not isinstance(event, dict) or event.get("previous_event_sha256") != previous
                or event.get("event_sha256") != _digest({key: value for key, value in event.items() if key != "event_sha256"})):
            raise DatasetError("Existing review history failed its integrity check; preserve it for inspection.")
        previous = event["event_sha256"]
    previous = events[-1].get("event_sha256") if events else None
    for correction in corrections:
        if not isinstance(correction, dict):
            raise DatasetError("Each correction must be an object.")
        record_id, field = correction.get("record_id"), correction.get("field")
        if record_id not in records or field not in fields:
            raise DatasetError(f"Unknown correction record/field: {record_id!r}/{field!r}.")
        reason = _text(correction.get("reason"), "correction.reason")
        if not isinstance(correction.get("after"), dict):
            raise DatasetError("correction.after must be a complete value/status/evidence cell.")
        before = copy.deepcopy(records[record_id]["values"].get(field))
        after = copy.deepcopy(correction["after"])
        records[record_id]["values"][field] = after
        event = {"at": datetime.now(timezone.utc).isoformat(), "actor": actor, "record_id": record_id,
                 "field": field, "reason": reason, "before": before, "after": after,
                 "source_extraction_sha256": _digest(extraction), "previous_event_sha256": previous}
        event["event_sha256"] = _digest(event)
        events.append(event)
        previous = event["event_sha256"]
    result["review_warnings"] = validate_extraction(result, source)
    return result


def append_reviewed_record(extraction: dict, record: dict, actor: str, reason: str,
                           source: dict, retained_record_id: str | None = None,
                           retained_record_notice: str | None = None) -> dict:
    """Append one evidence-validated condition without replacing earlier records."""
    validate_extraction(extraction, source)
    _text(actor, "actor"); _text(reason, "reason")
    result = copy.deepcopy(extraction)
    events = result.setdefault("review_history", [])
    if not isinstance(events, list):
        raise DatasetError("review_history must be a list.")
    previous = None
    for event in events:
        if (not isinstance(event, dict) or event.get("previous_event_sha256") != previous
                or event.get("event_sha256") != _digest({key: value for key, value in event.items() if key != "event_sha256"})):
            raise DatasetError("Existing review history failed its integrity check; preserve it for inspection.")
        previous = event["event_sha256"]
    if not isinstance(record, dict) or any(item['id']==record.get('id') for item in result['records']):
        raise DatasetError("Appended review record must have a new unique id; existing records cannot be overwritten.")
    retained_before = retained_after = None
    if retained_record_id is not None:
        matches = [item for item in result['records'] if item['id']==retained_record_id]
        if len(matches)!=1:
            raise DatasetError("The retained general record does not exist uniquely.")
        _text(retained_record_notice,"retained_record_notice")
        retained_before = copy.deepcopy(matches[0])
        matches[0]['review_notice'] = retained_record_notice
        if 'original_label' not in matches[0]:
            matches[0]['original_label'] = matches[0].get('label',retained_record_id)
            matches[0]['label'] = matches[0]['original_label']+'（未拆分摘要，非独立实验）'
        retained_after = copy.deepcopy(matches[0])
    result['records'].append(copy.deepcopy(record))
    result['review_warnings'] = validate_extraction(result, source)
    event = {'at':datetime.now(timezone.utc).isoformat(),'actor':actor,'operation':'add_record','record_id':record['id'],
             'reason':reason,'before':None,'after':copy.deepcopy(record),'retained_record_before':retained_before,
             'retained_record_after':retained_after,'source_extraction_sha256':_digest(extraction),
             'previous_event_sha256':previous,'human_scientific_acceptance':False}
    event['event_sha256'] = _digest(event)
    events.append(event)
    return result


def _matches(value: Any, operator: str, target: Any) -> bool:
    if operator in ("eq", "ne"):
        equal = _json(value) == _json(target)
        return equal if operator == "eq" else not equal
    if operator == "contains":
        if isinstance(value, str) and isinstance(target, str):
            return target.casefold() in value.casefold()
        if isinstance(value, list):
            return any(_json(item) == _json(target) for item in value)
        return False
    if operator in ("gt", "gte", "lt", "lte"):
        if type(value) not in (int, float) or type(target) not in (int, float):
            return False
        return {"gt": value > target, "gte": value >= target, "lt": value < target, "lte": value <= target}[operator]
    raise DatasetError(f"Unsupported filter operator {operator!r}.")


def query_graph(graph: dict, query: str = "", filters: list[dict] | None = None) -> dict:
    """Search actual facts, filter within each record, and return every source quote.

    Filters are ANDed within one sample/condition record, preventing accidental
    joins between a temperature from one test and a yield from another. A unit
    can be required explicitly; this function never assumes unit conversion.
    """
    if graph.get("kind") != "evidence_projection" or graph.get("schema_version") != 1:
        raise DatasetError("Expected a PaperShelf evidence_projection graph.")
    fields = validate_fields(graph.get("fields"))
    filters = filters or []
    if not isinstance(filters, list):
        raise DatasetError("filters must be a list.")
    for item in filters:
        if not isinstance(item, dict) or item.get("field") not in fields:
            raise DatasetError(f"Filter refers to an unknown custom field: {item!r}.")
        if "value" not in item:
            raise DatasetError("Every filter needs a value.")
        if item.get("op", "eq") not in {"eq", "ne", "contains", "gt", "gte", "lt", "lte"}:
            raise DatasetError("Invalid filter operator.")
        _json(item["value"])
    evidence = {node["id"]: node for node in graph["nodes"] if node["type"] == "evidence"}
    labels = {node["record_id"]: node.get("label", node["record_id"]) for node in graph["nodes"] if node["type"] == "record"}
    support = {}
    for edge in graph["edges"]:
        if edge["type"] == "supported_by":
            if edge["target"] not in evidence:
                raise DatasetError("Graph contains a dangling evidence edge.")
            support.setdefault(edge["source"], []).append(evidence[edge["target"]])
    records = {}
    for node in graph["nodes"]:
        if node["type"] == "fact":
            if not support.get(node["id"]):
                raise DatasetError("Graph contains a fact without evidence.")
            records.setdefault(node["record_id"], {})[node["field"]] = {
                key: node.get(key, "") for key in ("field", "value", "status", "unit", "notes")}
            records[node["record_id"]][node["field"]]["evidence"] = [
                {key: item[key] for key in ("block_id", "page", "quote", "document_id", "document") if key in item}
                for item in support[node["id"]]]
    terms = _text(query, "query", optional=True).casefold().split()
    matches = []
    for record_id, facts in records.items():
        if any(item["field"] not in facts or
               ("unit" in item and facts[item["field"]]["unit"] != item["unit"]) or
               not _matches(facts[item["field"]]["value"], item.get("op", "eq"), item["value"])
               for item in filters):
            continue
        haystack = (labels[record_id] + " " + _json(list(facts.values()))).casefold()
        if terms and not all(term in haystack for term in terms):
            continue
        matches.append({"record_id": record_id, "label": labels[record_id], "facts": list(facts.values())})
    return {"query": query, "filters": filters, "records": matches, "count": len(matches),
            "source": graph.get("source", {}), "warnings": graph.get("warnings", []),
            "notice": "Results are recorded evidence. Conflict status is preserved; no scientific conclusion or unit conversion was inferred."}


def _load(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _source(args: argparse.Namespace) -> dict | None:
    return _load(args.source) if getattr(args, "source", None) else None


def _export_command(args: argparse.Namespace) -> dict:
    return export_dataset(_load(args.extraction), Path(args.output), _source(args))


def _review_command(args: argparse.Namespace) -> dict:
    original, output = Path(args.extraction).resolve(), Path(args.output).resolve()
    if output == original:
        raise DatasetError("Write reviewed extraction to a new path; preserve the original run.")
    if output.exists():
        raise DatasetError("The review output already exists; choose a new path.")
    result = apply_corrections(_load(original), _load(args.corrections), args.actor, _source(args))
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2, allow_nan=False)
    return {"extraction": str(output), "review_events": len(result["review_history"]),
            "warnings": result["review_warnings"]}


def _query_command(args: argparse.Namespace) -> dict:
    return query_graph(_load(args.graph), args.query, json.loads(args.filters))


def register_subcommands(subparsers: argparse._SubParsersAction) -> None:
    export = subparsers.add_parser("dataset-export", help="Export custom-field records and provenance graph")
    export.add_argument("--extraction", required=True)
    export.add_argument("--source", help="source.json for exact evidence verification")
    export.add_argument("--output", required=True)
    export.set_defaults(func=_export_command)
    review = subparsers.add_parser("dataset-review", help="Apply audited corrections to a new extraction file")
    review.add_argument("--extraction", required=True)
    review.add_argument("--source")
    review.add_argument("--corrections", required=True, help="JSON list of record_id, field, reason, after")
    review.add_argument("--actor", required=True)
    review.add_argument("--output", required=True)
    review.set_defaults(func=_review_command)
    query = subparsers.add_parser("graph-query", help="Search local evidence and filter dynamic fields")
    query.add_argument("--graph", required=True)
    query.add_argument("--query", default="")
    query.add_argument("--filters", default="[]", help='JSON list, e.g. [{"field":"temperature","op":"gte","value":400,"unit":"K"}]')
    query.set_defaults(func=_query_command)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    register_subcommands(parser.add_subparsers(dest="command", required=True))
    arguments = parser.parse_args()
    try:
        print(json.dumps(arguments.func(arguments), ensure_ascii=False, indent=2, allow_nan=False))
    except (DatasetError, OSError, json.JSONDecodeError) as error:
        parser.exit(2, f"{error}\n")
