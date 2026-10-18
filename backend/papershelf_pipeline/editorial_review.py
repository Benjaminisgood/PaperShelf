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
    previews = {(item.get('document_id', 'main'), item['page']): item['path'] for item in source.get('figures', []) if item.get('path')}
    equation_keys = set()
    equation_aliases = {}
    for section in ('equations', 'content_corrections', 'semantic_constraints', 'reading_notes'):
        items = bundle.get(section, [])
        if not isinstance(items, list):
            raise PipelineError(f'校订证据 {section} 必须为数组。')
        for item in items:
            content = item.get('equation', {}) if section == 'equations' else item
            ids = content.get('source_ids')
            if not isinstance(ids, list) or not ids or any(identifier not in blocks for identifier in ids):
                raise PipelineError('校订证据必须指向完整、有效的原文来源。')
            verification = item.get('verification', {})
            pages = verification.get('pages')
            hashes = verification.get('page_image_sha256')
            if not isinstance(pages, list) or not pages or not isinstance(hashes, dict) or not verification.get('method'):
                raise PipelineError('校订证据缺少页图核验记录。')
            documents = {blocks[identifier].get('document_id', 'main') for identifier in ids}
            if len(documents) != 1:
                raise PipelineError('单条校订证据必须绑定同一文档。')
            document = next(iter(documents))
            if not {blocks[identifier]['page'] for identifier in ids}.issubset(set(pages)):
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
            elif section == 'reading_notes':
                if not isinstance(item.get('text'), str) or not item['text'].strip():
                    raise PipelineError('正文校核说明为空。')
            elif not isinstance(item.get('instruction'), str) or not item['instruction']:
                raise PipelineError('语义核验记录为空。')
    return bundle


def apply_editorial_review(learning, source, bundle, directory):
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
        locations = []
        for prefix, sections in (('', learning), ('consolidated.', learning.get('consolidated', {}))):
            for index, item in enumerate(sections.get(correction['section'], [])):
                if isinstance(item, dict) and item.get(correction['field']) == correction['original'] and set(item.get('source_ids', [])) == set(correction['source_ids']):
                    item[correction['field']] = correction['corrected']
                    locations.append(f'{prefix}{correction["section"]}[{index}].{correction["field"]}')
        records.append({**correction, 'status': 'applied_exact_match' if locations else 'retained_as_grounding_constraint', 'matches': len(locations), 'locations': locations})
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
