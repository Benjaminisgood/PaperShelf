"""Explicit request validation and stable JSON IO; never persist provider secrets."""
from __future__ import annotations

import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any


class PipelineError(RuntimeError):
    pass


class PipelineCancelled(PipelineError):
    pass


def read_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path: str | Path, value: Any) -> None:
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def sha256(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def valid_value(value: Any, field: dict) -> bool:
    if value is None:
        return True
    kind = field["type"]
    checks = {
        "string": lambda: isinstance(value, str),
        "number": lambda: type(value) in (int, float) and math.isfinite(value),
        "integer": lambda: type(value) is int,
        "boolean": lambda: type(value) is bool,
        "array": lambda: isinstance(value, list),
        "object": lambda: isinstance(value, dict),
    }
    if not checks[kind]():
        return False
    if "enum" in field and value not in field["enum"]:
        return False
    if kind == "array" and field.get("items"):
        return all(valid_value(item, field["items"]) for item in value)
    if kind == "object" and field.get("properties"):
        return all(key in field["properties"] and valid_value(item, field["properties"][key]) for key, item in value.items()) and all(key in value for key in field.get("required_properties", []))
    return True


def validate_fields(fields: Any) -> list[dict]:
    if not isinstance(fields, list):
        raise PipelineError("fields 必须是字段数组。")
    names = set()
    def validate_type(field):
        if field.get("type") not in {"string", "number", "integer", "boolean", "array", "object"}:
            raise PipelineError("字段 type 必须为 string/number/integer/boolean/array/object。")
        if field.get("enum") is not None and (not isinstance(field["enum"], list) or not field["enum"]):
            raise PipelineError("字段 enum 必须为非空数组。")
        if field.get("items"):
            validate_type(field["items"])
        for nested in field.get("properties", {}).values():
            validate_type(nested)
    for field in fields:
        if not isinstance(field, dict) or not isinstance(field.get("name"), str) or not field["name"].strip():
            raise PipelineError("每个自定义字段都必须有非空 name。")
        if field["name"] in names:
            raise PipelineError(f"字段名称重复：{field['name']}")
        names.add(field["name"])
        validate_type(field)
        field.setdefault("description", "")
    return fields


def validate_request(request: dict) -> dict:
    if not isinstance(request, dict):
        raise PipelineError("请求必须是 JSON 对象。")
    source = Path(request.get("source_path", "")).expanduser()
    if not source.is_file():
        raise PipelineError(f"找不到文献文件：{source}")
    if not request.get("output_root"):
        raise PipelineError("缺少 output_root。")
    request["source_path"] = str(source.resolve())
    request["output_root"] = str(Path(request["output_root"]).expanduser().resolve())
    request.setdefault("mode", "offline")
    if request["mode"] == "evidence":
        request["mode"] = "offline"
    if request["mode"] not in {"offline", "llm"}:
        raise PipelineError("mode 必须为 offline 或 llm。")
    if 'outputs' in request:
        outputs = request['outputs']
        allowed = {'guide', 'markdown', 'source', 'dataset', 'agent', 'presentation'}
        if (not isinstance(outputs, list) or not outputs
                or any(not isinstance(item, str) or item not in allowed for item in outputs)
                or len(set(outputs)) != len(outputs)):
            raise PipelineError('outputs 必须是非空、无重复的成果数组：guide/markdown/source/dataset/agent/presentation。')
        # Source and Agent preparation are entirely local even when the user's
        # preferred reading mode is AI. No provider needs to be configured.
        if set(outputs) <= {'source', 'agent'}:
            request['mode'] = 'offline'
        if 'dataset' not in outputs:
            request['fields'] = []
    request["fields"] = validate_fields(request.get("fields", []))
    from .dataset import validate_fields as validate_dataset_fields
    validate_dataset_fields(request["fields"])
    def reject_credentials(value):
        if isinstance(value,dict):
            for key,item in value.items():
                if key.lower() in {'api_key','apikey','password','token','secret','authorization','api_token','access_token','secret_key','access_key_secret'}:
                    raise PipelineError('配置不能保存明文凭据；请使用 api_key_env/password_environment 等环境变量名。')
                reject_credentials(item)
        elif isinstance(value,list):
            for item in value:
                reject_credentials(item)
    for section in ('provider','graphiti','paper2agent','presentation'):
        reject_credentials(request.get(section,{}))
    return request


def normalize_quote(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()
