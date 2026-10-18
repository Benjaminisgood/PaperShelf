"""Publish exact, source-bound overview edits as a new run without model calls."""
from __future__ import annotations

import copy
import datetime as dt
import shutil
import uuid
from pathlib import Path

from .contracts import PipelineError, read_json, sha256, write_json


def corrected_summary(learning, source, corrections):
    if not isinstance(corrections, list) or not corrections:
        raise PipelineError('综合概览审阅需要非空修正数组。')
    result = copy.deepcopy(learning)
    ids = {block['id'] for block in source['blocks']}
    for item in corrections:
        if not isinstance(item, dict) or item.get('source_sha256') != source['sha256']:
            raise PipelineError('综合概览审阅与来源哈希不一致。')
        field = item.get('field')
        if field not in {'overview', 'reading_route'}:
            raise PipelineError('综合概览审阅只允许overview或reading_route。')
        if not all(isinstance(item.get(key), str) and item[key].strip() for key in ('actor', 'reason')):
            raise PipelineError('综合概览审阅需要actor与reason。')
        evidence = item.get('source_ids')
        if not isinstance(evidence, list) or not evidence or any(identifier not in ids for identifier in evidence):
            raise PipelineError('综合概览审阅引用了不存在的来源段落。')
        if result.get(field) != item.get('original'):
            raise PipelineError('综合概览审阅原值不匹配，拒绝覆盖不同版本。')
        value = item.get('corrected')
        valid = isinstance(value, str) and bool(value.strip()) if field == 'overview' else (
            isinstance(value, list) and bool(value) and all(isinstance(step, str) and step.strip() for step in value))
        if not valid:
            raise PipelineError('综合概览审阅后的文字或阅读路线格式无效。')
        result[field] = copy.deepcopy(value)
    return result


def corrected_paragraphs(learning, source, corrections):
    """Apply exact paragraph edits, using the same validated source blocks."""
    from .generation import validate_paragraph
    if not isinstance(corrections, list):
        raise PipelineError('段落审阅需要修正数组。')
    result = copy.deepcopy(learning)
    blocks = {block['id']: block for block in source['blocks']}
    for item in corrections:
        if not isinstance(item, dict) or item.get('source_sha256') != source['sha256']:
            raise PipelineError('段落审阅与来源哈希不一致。')
        ids = item.get('source_ids')
        field = item.get('field')
        if (field not in {'explanation', 'reasoning'} or not isinstance(ids, list) or len(ids) != 1
                or ids[0] not in blocks or not all(isinstance(item.get(key), str) and item[key].strip()
                    for key in ('original', 'corrected', 'actor', 'reason'))):
            raise PipelineError('段落审阅需要单一来源ID、完整旧值/新值、actor与reason。')
        matches = [p for p in result['paragraphs'] if p['source_id'] == ids[0]]
        if len(matches) != 1 or matches[0].get(field) != item['original']:
            raise PipelineError('段落审阅原值不匹配，拒绝覆盖不同版本。')
        matches[0][field] = item['corrected']
    for identifier in {item['source_ids'][0] for item in corrections}:
        paragraph = next(p for p in result['paragraphs'] if p['source_id'] == identifier)
        before = copy.deepcopy(paragraph)
        validate_paragraph(paragraph, blocks[identifier])
        if before != paragraph:
            raise PipelineError('段落修正被规范化规则改变，必须先解决对应来源的校验冲突。')
    return result


def review_summary(manifest_path, corrections_path, paragraph_corrections_path=None):
    """Keep the old run immutable; regenerate local displays, reusing receipts."""
    from .dataset import validate_extraction
    from .pipeline import create_agent, update_index
    from .rendering import render_guide

    original_path = Path(manifest_path).expanduser().resolve()
    old = original_path.parent
    manifest = read_json(original_path)
    if manifest.get('status') not in {'completed', 'partial'} or Path(manifest['run_dir']).resolve() != old:
        raise PipelineError('只能审阅已有完整本地资料的运行。')
    for name, path in manifest['artifacts'].items():
        artifact = Path(path)
        if not artifact.is_file() or artifact.resolve().is_relative_to(old) is False:
            raise PipelineError(f'运行产物缺失或不属于该运行：{name}')
        if sha256(artifact) != manifest['artifact_sha256'].get(name):
            raise PipelineError(f'运行产物哈希变化，拒绝审阅：{name}')
    source = read_json(old / 'source.json')
    learning = read_json(old / 'learning.json')
    extraction = read_json(old / 'extraction.json')
    corrections = read_json(corrections_path)
    result = corrected_summary(learning, source, corrections)
    paragraph_corrections = read_json(paragraph_corrections_path) if paragraph_corrections_path else []
    result = corrected_paragraphs(result, source, paragraph_corrections)
    validate_extraction(extraction, source)
    now = dt.datetime.now(dt.timezone.utc)
    run_id = now.strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:10]
    directory = old.parent / run_id
    # A new directory keeps source assets, chunk responses and previous audit files.
    shutil.copytree(old, directory)
    new_manifest_path = directory / 'manifest.json'

    def relocate(value):
        if isinstance(value, str) and value.startswith(str(old) + '/'):
            return str(directory) + value[len(str(old)):]
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    manifest = copy.deepcopy(manifest)
    manifest['artifacts'] = relocate(manifest['artifacts'])
    manifest.update(run_id=run_id, run_dir=str(directory), manifest_path=str(new_manifest_path),
                    created_at=now.isoformat(), status='running')
    write_json(new_manifest_path, manifest)
    try:
        # Only artifact path fields are relinked; original quotes and model responses stay byte-for-byte.
        source = copy.deepcopy(source)
        for key in ('figures', 'figure_inventory', 'figure_crops'):
            if key in source:
                source[key] = relocate(source[key])
        write_json(directory / 'source.json', source)
        if (directory / 'figures.json').exists():
            write_json(directory / 'figures.json', {'items': source['figure_inventory'],
                       'coverage': source['figure_coverage'], 'documents': source['documents']})
        request = read_json(directory / 'request.json')
        request['summary_review_of'] = str(original_path)
        request['summary_corrections_path'] = str(Path(corrections_path).resolve())
        if paragraph_corrections_path:
            request['paragraph_corrections_path'] = str(Path(paragraph_corrections_path).resolve())
        write_json(directory / 'request.json', request)
        write_json(directory / 'learning-before-summary-review.json', learning)
        write_json(directory / 'learning.json', result)
        revised = {p['source_id']: p for p in result['paragraphs']
                   if p['source_id'] in {item['source_ids'][0] for item in paragraph_corrections}}
        for path in (directory / 'chunks').glob('chunk-????.json'):
            chunk = read_json(path)
            if any(p['source_id'] in revised for p in chunk['paragraphs']):
                write_json(path.with_name(path.stem + '-before-final-review.json'), chunk)
                chunk['paragraphs'] = [copy.deepcopy(revised.get(p['source_id'], p)) for p in chunk['paragraphs']]
                write_json(path, chunk)
        audit = {'source_sha256': source['sha256'], 'original_manifest': str(original_path),
                 'original_manifest_sha256': sha256(original_path),
                 'original_learning_sha256': sha256(old / 'learning.json'),
                 'corrections': corrections, 'provider_calls': 0, 'human_scientific_acceptance': False,
                 'paragraph_corrections': paragraph_corrections,
                 'notice': '精确审阅概览与阅读路线；保留原始模型输出，未重新调用模型或上游集成。'}
        write_json(directory / 'summary-review.json', audit)
        artifacts = manifest['artifacts']
        artifacts['summary_review'] = str(directory / 'summary-review.json')
        artifacts['learning_before_summary_review'] = str(directory / 'learning-before-summary-review.json')
        outputs = set(request.get('outputs', ['guide', 'markdown', 'dataset', 'agent']))
        formats = ({'html'} if 'guide' in outputs else set()) | ({'markdown'} if 'markdown' in outputs else set())
        artifacts.update(render_guide(source, result, extraction, directory, manifest['warnings'], formats=formats))
        if request.get('book', {}).get('enabled', bool(request.get('book'))):
            from .book import render_book
            artifacts.update(render_book(source, result, extraction, request['book'], directory, manifest['warnings'], formats=formats))
        if 'agent' in outputs:
            # Refresh only an explicitly requested Agent in the new version.
            shutil.rmtree(directory / 'agent', ignore_errors=True)
            artifacts['agent'] = create_agent(source, extraction, request, directory)
            artifacts['mcp'] = str(directory / 'agent' / 'mcp.json')
        # Integration receipts remain unchanged evidence of their originating runs.
        manifest['summary_review'] = audit
        manifest['status'] = 'partial' if manifest.get('integration_errors') else 'completed'
        manifest['finished_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
        manifest['artifact_sha256'] = {name: sha256(path) for name, path in artifacts.items()}
        write_json(new_manifest_path, manifest)
        update_index(old.parent, manifest)
        return manifest
    except Exception as error:
        manifest.update(status='failed', error=str(error), finished_at=dt.datetime.now(dt.timezone.utc).isoformat())
        write_json(new_manifest_path, manifest)
        update_index(old.parent, manifest)
        raise PipelineError(f'综合概览审阅失败；原运行未改变，新记录：{new_manifest_path}；{error}') from error


def register_subcommands(subparsers):
    parser = subparsers.add_parser('summary-review', help='Publish source-bound overview edits in a new run without model calls')
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--corrections', required=True)
    parser.add_argument('--paragraph-corrections', help='Optional SHA-bound exact explanation/reasoning corrections')
    parser.set_defaults(func=lambda args: review_summary(args.manifest, args.corrections, args.paragraph_corrections))
