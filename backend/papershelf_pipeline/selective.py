"""Field-only extraction with complete source input and independent checkpoints."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path

from .contracts import PipelineError, read_json, write_json
from .dataset import DatasetError, validate_extraction
from .generation import CHUNK_SCHEMA, SYSTEM, groups


def _validated_response(response, fields, blocks, chunk_number):
    if not isinstance(response, dict) or set(response) - {'records', 'warnings'}:
        raise DatasetError('字段提取只允许 records 与 warnings，不生成学习内容。')
    if not isinstance(response.get('records'), list):
        raise DatasetError('字段提取必须返回 records 数组。')
    records = copy.deepcopy(response['records'])
    for number, record in enumerate(records, 1):
        if not isinstance(record, dict) or not isinstance(record.get('values'), dict):
            raise DatasetError('每条字段记录必须包含 values 对象。')
        record['id'] = f'extraction-{chunk_number:04d}-{number:04d}'
        for field in fields:
            record['values'].setdefault(field['name'], {
                'value': None, 'status': 'not_found', 'evidence': [],
                'notes': '模型未返回此字段；本次未获得可核验值，不能据此断言原文未报告。',
                'extraction_status': 'omitted_by_model',
            })
    extraction = {'schema_version': 1, 'mode': 'llm', 'fields': copy.deepcopy(fields),
                  'records': records, 'warnings': copy.deepcopy(response.get('warnings', []))}
    extraction['warnings'].extend(validate_extraction(extraction, {'blocks': blocks}))
    return extraction


def make_extraction(source, request, run_dir, provider, progress):
    """Extract only configured fields; never call the translation/learning workflow.

    Resume reads only this function's receipts, and revalidates exact input hashes
    and evidence. Legacy learning chunks are intentionally never reused here.
    """
    fields = copy.deepcopy(request.get('fields', []))
    mode = request.get('mode', 'offline')
    extraction = {'schema_version': 1, 'mode': mode, 'fields': fields,
                  'records': [], 'warnings': []}
    validate_extraction(extraction, source)
    coverage = {'source_block_count': len(source['blocks']), 'input_source_ids': [],
                'chunk_count': 0, 'reused_chunks': 0, 'human_scientific_acceptance': False}
    extraction['coverage'] = coverage
    if not fields:
        extraction['warnings'].append('未配置提取字段；未调用模型。')
        return extraction
    if mode in {'offline', 'evidence'}:
        extraction['mode'] = 'offline'
        extraction['records'] = [{'id': 'source-record', 'label': '待提取', 'values': {
            field['name']: {'value': None, 'status': 'not_found', 'evidence': [],
                            'notes': '离线模式未推断字段值。'} for field in fields}}]
        extraction['warnings'].append('字段模板未填写；未调用模型进行语义提取。')
        extraction['warnings'].extend(validate_extraction(extraction, source))
        return extraction
    if mode != 'llm' or provider is None:
        raise PipelineError('字段语义提取需要 llm 模式与已配置的模型服务。')

    run_dir = Path(run_dir)
    chunk_dir = run_dir / 'extraction-chunks'
    chunk_dir.mkdir(exist_ok=True)
    previous = Path(request['resume_from']).expanduser().resolve() if request.get('resume_from') else None
    chunks = list(groups(source['blocks'], max(2000, min(int(request.get('chunk_characters', 10000)), 40000))))
    system = SYSTEM + '\n本次只提取用户字段。只返回 records 和 warnings；不要生成译文、paragraphs、分析、图表、自测或学习稿。'
    for index, blocks in enumerate(chunks, 1):
        progress(f'字段提取 {index}/{len(chunks)}（来源块 {len(blocks)}）')
        prompt = {
            'task': '完整检查全部 source_blocks，只提取 fields 中定义的字段。每条 records 对应独立样品和条件，不能合并不同论文、样品或条件。没有可支持的记录时返回空 records，不编造记录。保留原文数值与原文单位，不进行单位换算。每个值必须有本次输入块内逐字 quote 与准确 page；找不到的字段使用 null/status=not_found。只返回 records 和 warnings。',
            'schema': {'records': CHUNK_SCHEMA['records'], 'warnings': ['具体的来源限制或缺失信息']},
            'fields': fields,
            'reader_context': request.get('reader_context', ''),
            'source_blocks': blocks,
            'required_source_ids': [block['id'] for block in blocks],
            'verified_layout_observations': [note for note in source.get('layout_observations', [])
                if set(note.get('source_ids', [])) & {block['id'] for block in blocks}],
        }
        serialized = json.dumps(prompt, ensure_ascii=False, allow_nan=False)
        fingerprint = {'contract_version': 1, 'system': system, 'prompt': prompt,
                       'provider': request.get('provider', {}),
                       'document_set_sha256': source.get('document_set_sha256', source.get('sha256'))}
        input_hash = hashlib.sha256(json.dumps(fingerprint, ensure_ascii=False, sort_keys=True,
                                              allow_nan=False).encode()).hexdigest()
        receipt_path = chunk_dir / f'chunk-{index:04d}.json'
        receipt = {'schema_version': 1, 'kind': 'field_extraction', 'status': 'running',
                   'input_sha256': input_hash, 'source_ids': prompt['required_source_ids']}
        result, response = None, None
        if previous is not None:
            cached = previous / 'extraction-chunks' / receipt_path.name
            if cached.is_file():
                try:
                    candidate = read_json(cached)
                    if (candidate.get('kind') == 'field_extraction' and candidate.get('status') == 'completed'
                            and candidate.get('input_sha256') == input_hash):
                        response = candidate['response']
                        result = _validated_response(response, fields, blocks, index)
                        receipt['resumed_from'] = str(cached)
                except (OSError, ValueError, TypeError, KeyError, AttributeError):
                    # A damaged or outdated checkpoint is not accepted as evidence.
                    result, response = None, None
        write_json(receipt_path, receipt)
        try:
            if result is None:
                response = provider.json(system, serialized)
                result = _validated_response(response, fields, blocks, index)
            receipt.update(status='completed', response=response, extraction=result)
            write_json(receipt_path, receipt)
        except Exception as error:
            receipt.update(status='failed', error=str(error))
            if response is not None:
                try:
                    json.dumps(response, allow_nan=False)
                    receipt['response'] = response
                except (ValueError, TypeError):
                    receipt['response_repr'] = repr(response)
            write_json(receipt_path, receipt)
            raise PipelineError(f'字段提取分块 {index} 未通过：{error}') from error
        extraction['records'].extend(result['records'])
        extraction['warnings'].extend(f'分块 {index}：{warning}' for warning in result['warnings'])
        coverage['input_source_ids'].extend(prompt['required_source_ids'])
        coverage['chunk_count'] += 1
        coverage['reused_chunks'] += int('resumed_from' in receipt)
    extraction['warnings'].extend([
        '字段提取已提交全部来源块；引文和类型校验不等于字段召回完整或科学验收。',
        '跨分块的样品与条件记录保持独立，需人工核验后合并；not_found/null 不代表原文一定未报告。',
    ])
    extraction['warnings'].extend(validate_extraction(extraction, source))
    extraction['warnings'] = list(dict.fromkeys(extraction['warnings']))
    return extraction
