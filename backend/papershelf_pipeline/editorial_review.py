"""Apply source-bound editorial evidence, preserving every replaced draft.

These receipts record a source review, not the user's scientific acceptance.
"""
from __future__ import annotations

import copy
import re
from pathlib import Path

from .contracts import PipelineError, read_json, sha256, write_json


def _equation_key(equation, sources):
    label = str(equation.get('label', ''))
    match = re.fullmatch(r'\s*(?:Eq(?:uation|n)?\.?|式)?\s*[（(]?\s*(S?\d+[a-z]?)\s*[）)]?\s*', label, re.I)
    key = match.group(1).lower() if match else label.strip().casefold()
    documents = {sources[i].get('document_id', 'main') for i in equation.get('source_ids', []) if i in sources}
    return tuple(sorted(documents)), key


def load_editorial_review(path, source):
    bundle = read_json(path)
    if not isinstance(bundle, dict) or bundle.get('source_sha256') != source['sha256']:
        raise PipelineError('校订证据与当前原文 SHA256 不符。')
    if not isinstance(bundle.get('reviewer'), str) or not bundle['reviewer'].strip():
        raise PipelineError('校订证据缺少审阅者。')
    blocks = {item['id']: item for item in source['blocks']}
    reading_groups = {item['id']: item for item in source.get('reading_main_blocks', [])}
    previews = {(item.get('document_id', 'main'), item['page']): item['path'] for item in source.get('figures', []) if item.get('path')}
    equation_keys = set()
    equation_aliases = {}
    for section in ('equations', 'content_corrections', 'annotation_corrections', 'semantic_constraints', 'reading_notes'):
        items = bundle.get(section, [])
        if not isinstance(items, list):
            raise PipelineError(f'校订证据 {section} 必须为数组。')
        for item in items:
            content = item.get('equation', {}) if section == 'equations' else item
            ids = content.get('source_ids')
            if not isinstance(ids, list) or not ids or any(identifier not in blocks for identifier in ids):
                raise PipelineError('校订证据必须指向完整、有效的原文来源。')
            extra_ids = item.get('additional_evidence_source_ids', [])
            if not isinstance(extra_ids, list) or any(identifier not in blocks for identifier in extra_ids):
                raise PipelineError('额外版面证据必须为有效原文来源数组。')
            if extra_ids:
                group = reading_groups.get(item.get('reading_group_id'), {})
                if section != 'content_corrections' or item.get('section') != 'clean_reading' or set(group.get('source_ids', [])) != set(ids) or not set(extra_ids).issubset(set(group.get('linked_layout_source_ids', []))):
                    raise PipelineError('额外版面证据必须属于当前阅读组已有的版面关联，不能引用无关片段。')
            evidence_ids = ids + extra_ids
            verification = item.get('verification', {})
            pages = verification.get('pages')
            hashes = verification.get('page_image_sha256')
            if not isinstance(pages, list) or not pages or not isinstance(hashes, dict) or not verification.get('method'):
                raise PipelineError('校订证据缺少页图核验记录。')
            documents = {blocks[identifier].get('document_id', 'main') for identifier in evidence_ids}
            if len(documents) != 1:
                raise PipelineError('单条校订证据必须绑定同一文档。')
            document = next(iter(documents))
            if not {blocks[identifier]['page'] for identifier in evidence_ids}.issubset(set(pages)):
                raise PipelineError('校订来源页不在核验页范围内。')
            for page in pages:
                preview = previews.get((document, page))
                expected = hashes.get(str(page))
                if not preview or not expected or not Path(preview).is_file() or sha256(preview) != expected:
                    raise PipelineError('校订证据的原页图 SHA256 不符或不可读取。')
            if section == 'equations':
                if any(not isinstance(content.get(key), str) or not content[key].strip() for key in ('label', 'latex', 'meaning')):
                    raise PipelineError('校订公式缺少完整公式及解释。')
                if not isinstance(content.get('symbols'), list) or any(not isinstance(symbol, dict) or not all(isinstance(symbol.get(key), str) for key in ('symbol', 'meaning')) for symbol in content['symbols']):
                    raise PipelineError('校订公式的符号说明不完整。')
                key = _equation_key(content, blocks)
                if key in equation_keys:
                    raise PipelineError('校订公式编号重复；正文与补充材料编号须保持独立。')
                equation_keys.add(key)
                aliases = item.get('replace_labels', [])
                if not isinstance(aliases, list) or any(not isinstance(label, str) or not label.strip() for label in aliases):
                    raise PipelineError('校订公式别名必须为非空文字数组。')
                for label in [content['label']] + aliases:
                    alias = _equation_key({**content, 'label': label}, blocks)
                    owner = equation_aliases.setdefault(alias, key)
                    if owner != key:
                        raise PipelineError('校订公式别名与另一个公式冲突，不能交叉覆盖。')
            elif section == 'content_corrections':
                if any(not isinstance(item.get(key), str) or not item[key] for key in ('section', 'field', 'original', 'corrected', 'why')):
                    raise PipelineError('正文修正须提供原值、新值及原因。')
                if item['section'] == 'clean_reading' and (item['field'] not in {'text', 'translation'} or not isinstance(item.get('reading_group_id'), str)):
                    raise PipelineError('阅读正文修订须指定reading_group_id及text或translation。')
                follow = item.get('required_follow_through', {})
                if not isinstance(follow, dict):
                    raise PipelineError('阅读修订的关联更新必须为对象。')
                for field in ('translation_units', 'editing_notes'):
                    keys = (field + '_original', field + '_corrected')
                    if any(key in follow for key in keys) and not all(isinstance(follow.get(key), list) for key in keys):
                        raise PipelineError('阅读修订的关联更新须同时提供完整原值和新值。')
                for quote in item.get('source_evidence', []):
                    block = blocks.get(quote.get('block_id')) if isinstance(quote, dict) else None
                    if not block or block['id'] not in evidence_ids or quote.get('page') != block['page'] or not isinstance(quote.get('quote'), str) or not quote['quote'] or quote['quote'] not in block['text']:
                        raise PipelineError('正文修订的逐字来源证据不匹配。')
            elif section == 'annotation_corrections':
                if item.get('field') != 'editing_notes' or not isinstance(item.get('reading_group_id'), str) or not item['reading_group_id'] or not isinstance(item.get('why'), str) or not item['why']:
                    raise PipelineError('编辑说明修订须指定阅读组、editing_notes字段及原因。')
                if any(not isinstance(item.get(key), list) or any(not isinstance(note, str) for note in item[key]) for key in ('original', 'corrected')):
                    raise PipelineError('编辑说明修订须提供完整原说明与新说明文字数组。')
            elif section == 'reading_notes':
                if not isinstance(item.get('text'), str) or not item['text'].strip():
                    raise PipelineError('正文校核说明为空。')
            elif not isinstance(item.get('instruction'), str) or not item['instruction']:
                raise PipelineError('语义核验记录为空。')
    return bundle


def _synchronize_reading_correction(item, correction, learning, bundle):
    follow = correction.get('required_follow_through', {})
    units = item.get('translation_units', [])
    if correction['field'] == 'translation' and units and 'translation_units_corrected' not in follow:
        raise PipelineError('完整译文修订必须同时核对逐句translation_units，不能留下相互矛盾的译文。')
    for field in ('translation_units', 'editing_notes'):
        if field + '_corrected' not in follow:
            continue
        original, corrected = follow[field + '_original'], follow[field + '_corrected']
        if item.get(field, []) not in (original, corrected):
            raise PipelineError(f'阅读修订的{field}原值不匹配，不能覆盖新变化。')
        if field == 'translation_units':
            if any(not isinstance(unit, dict) for unit in original + corrected) or [unit.get('unit_id') for unit in original] != [unit.get('unit_id') for unit in corrected]:
                raise PipelineError('审校不可增加、删除或重排翻译单元ID。')
            if any(not isinstance(unit.get('translation'), str) or not unit['translation'].strip() for unit in corrected):
                raise PipelineError('审校后的逐句译文不能为空。')
            if corrected and '\n\n'.join(unit['translation'].strip() for unit in corrected) != item['translation']:
                raise PipelineError('审校后的逐句译文与完整译文不一致。')
        elif any(not isinstance(note, str) for note in corrected):
            raise PipelineError('审校后的编辑说明必须为文字数组。')
        item[field] = copy.deepcopy(corrected)
    item.setdefault('validation_before_editorial_review', copy.deepcopy(item.get('translation_validation', {})))
    item['translation_validation'] = {**item.get('translation_validation', {}),
                                      'numeric_tokens': 'source_reviewed_correction',
                                      'semantic_review': 'source_reviewed_correction_not_human_acceptance'}
    if correction['field'] == 'text':
        item.setdefault('reading_validation_before_editorial_review', copy.deepcopy(item.get('validation', {})))
        item['validation'] = {**item.get('validation', {}), 'numeric_tokens': 'source_reviewed_correction',
                              'units': 'source_reviewed_correction', 'inline_markers': 'source_reviewed_correction',
                              'semantic_review': 'source_reviewed_correction_not_human_acceptance'}
    item['status'] = 'source_reviewed_correction'
    item.setdefault('editing_notes', [])
    if 'editing_notes_corrected' not in follow:
        note = '原页核对修订：' + correction['why']
        if note not in item['editing_notes']:
            item['editing_notes'].append(note)
    marker = {'id': correction.get('id'), 'field': correction['field'], 'reviewer': bundle['reviewer'],
              'source_sha256': bundle['source_sha256'], 'verification': copy.deepcopy(correction['verification']),
              'additional_evidence_source_ids': list(correction.get('additional_evidence_source_ids', [])),
              'human_scientific_acceptance': False}
    if marker not in item.setdefault('source_reviewed_corrections', []):
        item['source_reviewed_corrections'].append(marker)
    for paragraph in learning.get('paragraphs', []):
        if paragraph.get('source_id') != item['id']:
            continue
        if set(paragraph.get('source_ids', [paragraph['source_id']])) != set(item['source_ids']):
            raise PipelineError('阅读正文与逐段译述来源映射不一致，不能应用审校修订。')
        paragraph['explanation'] = item['translation']
        paragraph['translation_units'] = copy.deepcopy(item.get('translation_units', []))
        paragraph['translation_validation'] = copy.deepcopy(item['translation_validation'])


def apply_editorial_review(learning, source, bundle, directory, *, require_exact=False):
    sources = {item['id']: item for item in source['blocks']}
    before = copy.deepcopy(learning)
    records = []
    equations = learning.setdefault('equations', [])
    for entry in bundle.get('equations', []):
        corrected = copy.deepcopy(entry['equation'])
        key = _equation_key(corrected, sources)
        aliases = set(entry.get('replace_labels', []))
        def replaces(item):
            item_key = _equation_key(item, sources)
            return item_key == key or (item_key[0] == key[0] and item.get('label') in aliases)
        matches = [item for item in equations if replaces(item)]
        original = copy.deepcopy(matches)
        unresolved = learning.get('unresolved_equations', [])
        resolved_drafts = [item for item in unresolved if replaces(item)]
        learning['unresolved_equations'] = [item for item in unresolved if not replaces(item)]
        for draft in resolved_drafts:
            prefix = f'公式 {draft.get("label", "无编号")}（来源 {", ".join(draft.get("source_ids", []))}）'
            resolved_notes = [note for note in learning.get('gaps', []) if note.startswith(prefix) and '未可靠映射字形' in note]
            learning['gaps'] = [note for note in learning.get('gaps', []) if note not in resolved_notes]
            learning.setdefault('process_notes', []).extend(note + '（本版已对照原页重新转写，旧稿保留在校订记录。）' for note in resolved_notes)
        position = equations.index(matches[0]) if matches else len(equations)
        equations[:] = [item for item in equations if not replaces(item)]
        corrected['editorial_verification'] = {**entry['verification'], 'reviewer': bundle['reviewer'], 'source_sha256': source['sha256'], 'human_scientific_acceptance': False}
        equations.insert(position, corrected)
        records.append({'kind': 'equation', 'original': original, 'unresolved_original': copy.deepcopy(resolved_drafts), 'corrected': corrected, 'why': entry.get('why', ''), 'verification': entry['verification']})
    positions = {identifier: index for index, identifier in enumerate(sources)}
    def reading_order(equation):
        key = _equation_key(equation, sources)[1]
        number = re.fullmatch(r'(s?)(\d+)([a-z]?)', key)
        label_order = (number.group(1), int(number.group(2)), number.group(3)) if number else ('z', 0, key)
        return min((positions[i] for i in equation.get('source_ids', []) if i in positions), default=len(positions)), label_order
    equations.sort(key=reading_order)
    for correction in bundle.get('content_corrections', []):
        locations, already = [], []
        for prefix, sections in (('', learning), ('consolidated.', learning.get('consolidated', {}))):
            for index, item in enumerate(sections.get(correction['section'], [])):
                if not isinstance(item, dict) or set(item.get('source_ids', [])) != set(correction['source_ids']):
                    continue
                if correction['section'] == 'clean_reading' and item.get('id') != correction.get('reading_group_id'):
                    continue
                value = item.get(correction['field'])
                if value not in (correction['original'], correction['corrected']):
                    continue
                location = f'{prefix}{correction["section"]}[{index}].{correction["field"]}'
                (locations if value == correction['original'] else already).append(location)
                item[correction['field']] = correction['corrected']
                if correction['section'] == 'clean_reading':
                    _synchronize_reading_correction(item, correction, learning, bundle)
        if require_exact and not locations and not already:
            raise PipelineError(f'审校修订{correction.get("id", correction["section"])}未匹配任何原值或已修订值；已停止另存，原版本保持不变。')
        records.append({**correction, 'status': 'applied_exact_match' if locations else ('already_applied' if already else 'retained_as_grounding_constraint'),
                        'matches': len(locations), 'locations': locations, 'already_applied_locations': already})
    for correction in bundle.get('annotation_corrections', []):
        matches = [item for item in learning.get('clean_reading', []) if item.get('id') == correction['reading_group_id']
                   and set(item.get('source_ids', [])) == set(correction['source_ids'])]
        if len(matches) != 1 or matches[0].get('editing_notes', []) not in (correction['original'], correction['corrected']):
            if require_exact:
                raise PipelineError(f'编辑说明修订{correction.get("id", correction["reading_group_id"])}未匹配原值或已修订值。')
            records.append({**correction, 'kind': 'annotation_correction', 'status': 'retained_as_grounding_constraint', 'locations': []})
            continue
        item = matches[0]
        already = item.get('editing_notes', []) == correction['corrected']
        item['editing_notes'] = copy.deepcopy(correction['corrected'])
        records.append({**correction, 'kind': 'annotation_correction', 'status': 'already_applied' if already else 'applied_exact_match',
                        'locations': [f'clean_reading[{learning["clean_reading"].index(item)}].editing_notes']})
    # Scientific caveats belong beside the affected passage as well as in the
    # equation cards. These are verified annotations, never replacement prose.
    for entry in bundle.get('reading_notes', []):
        locations = []
        annotation = {**copy.deepcopy(entry), 'reviewer': bundle['reviewer'],
                      'source_sha256': source['sha256'], 'human_scientific_acceptance': False}
        for collection in ('clean_reading', 'paragraphs'):
            for index, item in enumerate(learning.get(collection, [])):
                identifiers = item.get('source_ids') or [item.get('source_id')]
                if not set(identifiers).intersection(entry['source_ids']):
                    continue
                notes = item.setdefault('editorial_notes', [])
                if annotation not in notes:
                    notes.append(copy.deepcopy(annotation))
                locations.append(f'{collection}[{index}].editorial_notes')
        records.append({'kind': 'reading_note', **copy.deepcopy(entry),
                        'status': 'annotated' if locations else 'no_matching_reading_group', 'locations': locations})
    write_json(directory / 'learning-before-editorial-review.json', before)
    receipt = {'source_sha256': source['sha256'], 'reviewer': bundle['reviewer'], 'human_scientific_acceptance': False, 'records': records, 'semantic_constraints': bundle.get('semantic_constraints', [])}
    write_json(directory / 'editorial-review.json', receipt)
    learning['editorial_review'] = receipt
    return {'editorial_review': str(directory / 'editorial-review.json'), 'editorial_review_draft': str(directory / 'learning-before-editorial-review.json')}
