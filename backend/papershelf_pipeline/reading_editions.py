"""Readable documents with an explicit, lossless path back to extraction evidence."""
from __future__ import annotations

from collections import Counter
from pathlib import Path


def render_reading_editions(source: dict, learning: dict, directory: Path) -> dict:
    blocks = {item['id']: item for item in source['blocks']}
    raw = ['# 原始来源索引', '', '以下保留提取文本，不执行 AI 改写。正文对应关系见 fulltext.md。', '']
    for block in source['blocks']:
        raw.extend([f'<a id="src-{block["id"]}"></a>', f'## p.{block["page"]} · {block["id"]}', '', block['text'], ''])
    (directory / 'source-index.md').write_text('\n'.join(raw), encoding='utf-8')

    def citations(ids):
        return ' · '.join(f'[p.{blocks[item]["page"]} · {item}](source-index.md#src-{item})' for item in ids if item in blocks)

    cleaned = learning.get('clean_reading')
    groups = cleaned or source.get('reading_main_blocks', source.get('reading_blocks', source['blocks']))
    output = [f'# {learning["title"]}', '', '> 原语言全文阅读版。' + ('经过 AI 校订；请结合来源核验。' if cleaned else '已整理版面换行；未经过 AI 校订。'), '',
              '[完整原始提取](source.md) · [逐块来源索引](source-index.md) · [中文研读](learning.md)', '']
    content = [f'# {learning["title"]}', '']
    document_id = None
    def ensure_document(identifiers):
        nonlocal document_id
        first = next((blocks[item] for item in identifiers if item in blocks), {})
        current_document = first.get('document_id', 'main')
        if current_document != document_id:
            if current_document != 'main':
                output.extend(['## 补充材料：' + first.get('document', current_document), ''])
            document_id = current_document
    positions = {identifier: index for index, identifier in enumerate(blocks)}
    verified_equations = sorted(
        (equation for equation in learning.get('equations', [])
         if equation.get('editorial_verification') and equation.get('source_ids')
         and all(identifier in blocks for identifier in equation['source_ids'])),
        key=lambda equation: min(positions[i] for i in equation['source_ids']))

    def append_equations_before(position):
        while verified_equations and min(positions[i] for i in verified_equations[0]['source_ids']) < position:
            equation = verified_equations.pop(0)
            ensure_document(equation['source_ids'])
            # Only a source/page-image reviewed transcription belongs in the
            # original-language edition. Unresolved extraction stays in its appendix.
            output.extend(['### ' + equation['label'], '', '$$\n' + equation['latex'] + '\n$$', '',
                           '<details><summary>公式来源与核验记录</summary>', '', citations(equation['source_ids']), '',
                           '对照原页转写；原式的符号疑点及解释见中文研读。', '', '</details>', ''])
            content.extend(['<!-- source_ids: ' + ', '.join(equation['source_ids']) + ' -->',
                            '$$\n' + equation['latex'] + '\n$$', ''])
    for group in groups:
        if group.get('reading_main') is False:
            continue
        identifiers = group.get('source_ids') or [group['id']]
        append_equations_before(min((positions[i] for i in identifiers if i in positions), default=len(positions)))
        ensure_document(identifiers)
        text = group.get('text', group.get('reading_text', ''))
        if not text.strip():
            continue
        content.extend(['<!-- source_ids: ' + ', '.join(identifiers) + ' -->', text, ''])
        output.extend([f'<a id="read-{group.get("id", identifiers[0])}"></a>', ''])
        kind = group.get('kind', '')
        if kind in {'heading', 'title', 'section_heading'}:
            output.extend(['## ' + text.replace('\n', ' '), ''])
        elif kind in {'equation', 'formula'}:
            # Preserve extracted notation rather than guessing a TeX conversion.
            output.extend(['```text', text, '```', ''])
        else:
            output.extend([text, ''])
        for note in group.get('editorial_notes', []):
            output.extend(['> 原文校核：' + note['text'].replace('\n', '\n> '), '', citations(note['source_ids']), ''])
        output.extend(['<details><summary>来源与校订记录</summary>', '', citations(identifiers), ''])
        notes = list(group.get('reading_notes', [])) + list(group.get('editing_notes', []))
        notes.extend(note for identifier in identifiers if identifier in blocks for note in blocks[identifier].get('reading_notes', []))
        notes.extend(note['observation'] for identifier in identifiers if identifier in blocks for note in blocks[identifier].get('layout_observations', []) if note.get('observation'))
        for note in dict.fromkeys(notes):
            output.append('- ' + str(note))
        # Machine validation is retained in learning.json. Repeating the same
        # technical receipt after every paragraph obscures the reading edition.
        output.extend(['', '</details>', ''])
    append_equations_before(len(positions) + 1)
    excluded = [block for block in source['blocks'] if block.get('include_in_reading') is False]
    fragments = source.get('reading_fragments', [])
    if fragments:
        appendix = ['# 公式与图表版面文字', '', '此文件保留暂不能安全重组成连贯文字的公式、图轴和短版面片段。请对照学习网页中的公式、图表和原页。', '']
        for fragment in fragments:
            appendix.extend(['## ' + fragment['id'], '', '```text', fragment['text'], '```', '', citations(fragment['source_ids']), ''])
            notes = list(fragment.get('reading_notes', []))
            notes.extend(note['observation'] for identifier in fragment['source_ids'] if identifier in blocks for note in blocks[identifier].get('layout_observations', []) if note.get('observation'))
            appendix.extend('- ' + note for note in dict.fromkeys(notes))
            appendix.append('')
        (directory / 'layout-fragments.md').write_text('\n'.join(appendix), encoding='utf-8')
        output.extend(['## 公式与图表文字', '', '[查看完整公式与图表版面文字](layout-fragments.md)。这些片段保留原始符号与来源，没有作为连贯句子改写。公式含义和图表读法见中文研读。', ''])
    if excluded:
        output.extend(['## 附属来源', '', '以下内容保留在原始来源索引中；不与连贯正文混排。', ''])
        for role, count in sorted(Counter(block.get('reading_role', '附属内容') for block in excluded).items()):
            output.append(f'- {role}：{count} 个来源块')
        output.extend(['', '[查看全部来源](source-index.md)', ''])
    (directory / 'fulltext.md').write_text('\n'.join(output), encoding='utf-8')
    # Knowledge extraction should not ingest editorial diagnostics or provenance UI.
    (directory / 'reading-content.md').write_text('\n'.join(content), encoding='utf-8')

    paragraphs = [f'# {learning["title"]} · 逐段对照', '', '[返回中文研读](learning.md) · [原语言全文](fulltext.md)', '']
    for paragraph in learning.get('paragraphs', []):
        identifiers = paragraph.get('source_ids') or [paragraph['source_id']]
        paragraphs.extend(['## ' + identifiers[0], '', paragraph['explanation'], '', paragraph.get('reasoning', ''), '', citations(identifiers), ''])
        for note in paragraph.get('editorial_notes', []):
            paragraphs.extend(['> 原文校核：' + note['text'].replace('\n', '\n> '), '', citations(note['source_ids']), ''])
        if paragraph.get('key_sentence'):
            paragraphs.extend(['> ' + paragraph['key_sentence'].replace('\n', '\n> '), ''])
    (directory / 'paragraphs.md').write_text('\n'.join(paragraphs), encoding='utf-8')
    return {**({'layout_fragments': str(directory / 'layout-fragments.md')} if fragments else {}),
            'source_markdown': str(directory / 'fulltext.md'), 'raw_source_markdown': str(directory / 'source.md'),
            'source_index': str(directory / 'source-index.md'), 'paragraph_markdown': str(directory / 'paragraphs.md'),
            'reading_content': str(directory / 'reading-content.md')}
