"""Lossless, geometry-based paragraphs with an exact path to raw PDF text.

PDF text blocks are often single rendered lines, and a single PDF block can
contain text from two columns. Group lines rather than trusting either case.
Every character remains in a raw-block slice; ambiguous extraction falls back
to the intact raw block instead of silently changing or dropping text.
"""
from __future__ import annotations

from collections import Counter
import re
import statistics


def _union(boxes):
    return [min(box[0] for box in boxes), min(box[1] for box in boxes),
            max(box[2] for box in boxes), max(box[3] for box in boxes)]


def _font(spans):
    counts = Counter()
    for span in spans:
        counts[(span.get('font', ''), round(span.get('size', 10), 2), int(span.get('flags', 0)))] += len(span.get('text', '').strip())
    return counts.most_common(1)[0][0] if counts else ('', 10., 0)


def _raw_lines(page, raw_blocks):
    # Match with raw extraction, including its original block numbers when
    # provided. get_text's sort order is not a stable block identity.
    import pymupdf
    blocks = [block for block in page.get_text('dict', flags=pymupdf.TEXTFLAGS_DICT & ~pymupdf.TEXT_PRESERVE_IMAGES)['blocks'] if block.get('type') == 0]
    unused = set(range(len(blocks)))
    result = []
    for raw in raw_blocks:
        raw_text, box = raw['text'], list(raw['bbox'])
        candidates = []
        for index in unused:
            block = blocks[index]
            text = ''.join(''.join(span['text'] for span in line['spans']) + '\n' for line in block['lines'])
            if text == raw_text and all(abs(first-second) < 0.2 for first, second in zip(block['bbox'], box)):
                candidates.append(index)
        if len(candidates) > 1 and raw.get('block_number') is not None:
            candidates = [index for index in candidates if blocks[index].get('number') == raw['block_number']]
        if len(candidates) != 1:
            result.append({'raw_block_id': raw['id'], 'start': 0, 'end': len(raw_text), 'text': raw_text,
                           'bbox': box, 'direction': [1., 0.], 'font': '', 'font_size': 10.,
                           'font_flags': 0, 'baseline': box[3], 'fallback': True,
                           'note': '无法唯一匹配 PDF 文字行，完整保留原始文本块；阅读顺序需对照页图。'})
            continue
        index = candidates[0]; unused.remove(index)
        offset = 0
        for line_number, line in enumerate(blocks[index]['lines']):
            text = ''.join(span['text'] for span in line['spans']) + '\n'
            font, size, flags = _font(line['spans'])
            dominant = max(line['spans'], key=lambda span: len(span.get('text', '')), default={})
            result.append({'raw_block_id': raw['id'], 'start': offset, 'end': offset+len(text),
                           'text': text, 'bbox': list(line['bbox']), 'direction': list(line.get('dir', (1., 0.))),
                           'font': font, 'font_size': size, 'font_flags': flags,
                           'baseline': dominant.get('origin', [0, line['bbox'][3]])[1],
                           'line_number': line_number,
                           'spans': [{'text': span['text'], 'bbox': list(span['bbox'])} for span in line['spans']]})
            offset += len(text)
    return result


def _compatible(group, line, body_size):
    previous = group[-1]
    if previous.get('fallback') or line.get('fallback'):
        return False
    if abs(line['direction'][1]) > 0.05 or abs(previous['direction'][1]) > 0.05:
        return False
    size = max(previous['font_size'], line['font_size'])
    if abs(previous['font_size']-line['font_size']) > max(.6, size*.08):
        return False
    if previous['font'] != line['font'] or (previous['font_flags'] & 16) != (line['font_flags'] & 16):
        return False
    delta = line['baseline']-previous['baseline']
    if not size*.65 <= delta <= size*2.1:
        return False
    gap = line['bbox'][1]-previous['bbox'][3]
    if not -size*.6 <= gap <= max(4., size*.85):
        return False
    left, right = previous['bbox'], line['bbox']
    overlap = min(left[2], right[2])-max(left[0], right[0])
    if overlap <= min(left[2]-left[0], right[2]-right[0])*.4:
        return False
    bounds = _union([item['bbox'] for item in group])
    centered_title = size >= body_size*1.2 and abs((left[0]+left[2])-(right[0]+right[2])) < size*2
    if not centered_title:
        if abs(left[0]-right[0]) > size*1.8:
            return False
        # Indentation starts a fresh paragraph; the next unindented line may
        # continue it. Superscript citations can make adjacent boxes overlap.
        if right[0] > bounds[0]+size*.7:
            return False
        if left[2]-left[0] < (bounds[2]-bounds[0])*.75 and re.search(r'[.!?。！？][\d,–—\-\]”"\')]*\s*$', previous['text']):
            return False
    # Avoid manufacturing prose paragraphs by stacking unrelated table cells,
    # plot ticks, or standalone equations from distinct raw blocks.
    if previous['raw_block_id'] != line['raw_block_id']:
        word_count = lambda text: len(re.findall(r'[A-Za-z]{3,}|[\u3400-\u9fff]', text))
        # A final wrapped line can be a single word. Require prose in the
        # preceding line and some lexical text in its continuation, rather
        # than breaking the last words away from a complete paragraph.
        if word_count(previous['text']) < 3 or word_count(line['text']) < 1:
            return False
        if re.match(r'\s*(?:\d+(?:\.\d+)*[.)]?\s+)?(?:Introduction|Abstract|References|Conclusions?|Methods?|Results|Discussion)\s*$', line['text'], re.I):
            return False
    return True


def _join_visual_rows(lines, page_width):
    """Rejoin justified words that MuPDF exposes as separate same-row lines.

    Keep the original slices, including newlines, for exact coverage. Requiring
    the same raw block and excluding observed column gutters avoids joining
    adjacent columns merely because their baselines happen to coincide.
    """
    starts = {}
    for line in lines:
        width = line['bbox'][2]-line['bbox'][0]
        if (not line.get('fallback') and abs(line['direction'][1]) < .05
                and page_width*.28 < width < page_width*.6):
            key = round(line['bbox'][0]/4)*4
            starts.setdefault(key, []).append(line)
    columns = sorted((statistics.median(l['bbox'][0] for l in values),
                      statistics.median(l['bbox'][2] for l in values))
                     for values in starts.values() if len(values) >= 3)
    gutters = [(left[1]+right[0])/2 for left in columns for right in columns
               if right[0]-left[0] > page_width*.25 and 2 < right[0]-left[1] < page_width*.12]
    rows = []
    for line in sorted(lines, key=lambda item: (round(item['baseline']/2), item['bbox'][0])):
        candidates = []
        if not line.get('fallback') and abs(line['direction'][1]) < .05:
            for row in rows:
                size = max(row['font_size'], line['font_size'])
                if (not row.get('fallback') and abs(row['direction'][1]) < .05
                        and row['raw_block_id'] == line['raw_block_id']
                        and abs(row['baseline']-line['baseline']) < size*.25
                        and abs(row['font_size']-line['font_size']) < max(.6, size*.08)
                        and -size*.15 <= line['bbox'][0]-row['bbox'][2] <= size*1.3
                        and not any(row['bbox'][2] <= cut <= line['bbox'][0] for cut in gutters)):
                    candidates.append(row)
        if candidates:
            row = max(candidates, key=lambda item: item['bbox'][2])
            row['parts'].append(line)
            row['text'] += line['text']
            row['bbox'] = _union([row['bbox'], line['bbox']])
            dominant = max(row['parts'], key=lambda item: len(item['text']))
            for key in ('font', 'font_size', 'font_flags', 'baseline'):
                row[key] = dominant[key]
        else:
            rows.append({**line, 'parts': [line]})
    return rows


def _reading_order(groups, page_width):
    """Recursive whitespace cuts: columns first, then horizontal page bands."""
    if len(groups) < 2:
        return groups
    for axis, threshold in [(0, max(6., page_width*.01)), (1, 8.)]:
        intervals = sorted((item['bbox'][axis], item['bbox'][axis+2]) for item in groups)
        edge = intervals[0][1]; gaps = []
        for start, end in intervals[1:]:
            if start-edge >= threshold:
                gaps.append((start-edge, (start+edge)/2))
            edge = max(edge, end)
        if gaps:
            cut = max(gaps)[1]
            before = [item for item in groups if item['bbox'][axis+2] <= cut]
            after = [item for item in groups if item['bbox'][axis] >= cut]
            if before and after and len(before)+len(after) == len(groups):
                return _reading_order(before, page_width)+_reading_order(after, page_width)
    return sorted(groups, key=lambda item: (round(item['bbox'][1]/3), item['bbox'][0]))


def validate_grouping(paragraphs, raw_blocks):
    """Every raw character must be present exactly once in an unchanged slice."""
    raw = {item['id']: item for item in raw_blocks}
    if len(raw) != len(raw_blocks):
        raise ValueError('Raw PDF block IDs must be unique.')
    coverage = {identifier: [] for identifier in raw}
    for paragraph in paragraphs:
        if paragraph['text'] != ''.join(line['text'] for line in paragraph['lines']):
            raise ValueError('Paragraph text differs from its raw line slices.')
        for line in paragraph['lines']:
            identifier = line['raw_block_id']
            start, end = line['start'], line['end']
            if (identifier not in raw or type(start) is not int or type(end) is not int
                    or not 0 <= start < end <= len(raw[identifier]['text'])
                    or raw[identifier]['text'][start:end] != line['text']):
                raise ValueError('PDF paragraph provenance does not match the raw block.')
            coverage[identifier].append((line['start'], line['end']))
    for identifier, ranges in coverage.items():
        offset = 0
        for start, end in sorted(ranges):
            if start != offset or end < start:
                raise ValueError('PDF paragraph grouping omitted or repeated raw text.')
            offset = end
        if offset != len(raw[identifier]['text']):
            raise ValueError('PDF paragraph grouping omitted raw text.')


def group_page_blocks(page, raw_blocks):
    """Return paragraphs containing text, bbox, raw_block_ids and exact lines.

    ``raw_blocks`` is a sequence of ``{id, text, bbox}`` records from this page's
    nonempty PyMuPDF text blocks. No text is normalized, sampled or discarded.
    ``lines`` retains offsets, bounding boxes and original span text for audit.
    """
    lines = _raw_lines(page, raw_blocks)
    font_counts = Counter()
    for line in lines:
        if abs(line['direction'][1]) < .05:
            font_counts[line['font_size']] += len(line['text'].strip())
    body_size = font_counts.most_common(1)[0][0] if font_counts else 10.
    groups = []
    for line in sorted(_join_visual_rows(lines, page.rect.width), key=lambda item: (round(item['baseline']/2), item['bbox'][0])):
        candidates = [group for group in groups if _compatible(group, line, body_size)]
        if candidates:
            nearest = min(candidates, key=lambda group: (line['baseline']-group[-1]['baseline'], abs(line['bbox'][0]-group[-1]['bbox'][0])))
            nearest.append(line)
        else:
            groups.append([line])
    paragraphs = []
    for rows in groups:
        group = [line for row in rows for line in row['parts']]
        item = {'text': ''.join(line['text'] for line in group), 'bbox': _union([line['bbox'] for line in group]),
                'raw_block_ids': list(dict.fromkeys(line['raw_block_id'] for line in group)), 'lines': group}
        notes = list(dict.fromkeys(line['note'] for line in group if line.get('note')))
        if notes:
            item['grouping_notes'] = notes
        paragraphs.append(item)
    main = [item for item in paragraphs if all(abs(line['direction'][1]) < .05 for line in item['lines'])]
    marginal = [item for item in paragraphs if item not in main]
    paragraphs = _reading_order(main, page.rect.width)+_reading_order(marginal, page.rect.width)
    height = getattr(page.rect, 'height', 0)
    for paragraph in paragraphs:
        if not paragraph['text'].strip():
            paragraph['source_role_hint'] = 'whitespace'
        elif any(abs(line['direction'][1]) >= .05 for line in paragraph['lines']):
            paragraph['source_role_hint'] = 'marginal'
        elif (height and re.fullmatch(r'\s*\d{1,4}\s*', paragraph['text'])
              and (paragraph['bbox'][1] > height*.9 or paragraph['bbox'][3] < height*.07)):
            paragraph['source_role_hint'] = 'page_number'
    validate_grouping(paragraphs, raw_blocks)
    return paragraphs
