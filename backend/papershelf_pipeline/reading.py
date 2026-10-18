"""Traceable clean reading groups layered over immutable PDF text and IDs."""
from __future__ import annotations

from collections import Counter
import re


_WORD = re.compile(r"(?<![A-Za-z-])[A-Za-z]{3,}(?![A-Za-z-])")
_WRAPPED_WORD = re.compile(r"([A-Za-z]{2,})[-\u2010\u00ad][ \t]*\n[ \t]*([A-Za-z]+)")
_LIGATURES = str.maketrans({'\ufb00': 'ff', '\ufb01': 'fi', '\ufb02': 'fl', '\ufb03': 'ffi', '\ufb04': 'ffl', '\ufb05': 'st', '\ufb06': 'st'})
_SECTION = re.compile(r'^\s*(?:\d+(?:\.\d+)*\.?\s+)?(?:abstract|introduction|background|methods?|materials(?: and methods)?|results(?: and discussion)?|discussion|conclusions?|references(?: and notes)?|acknowledg(?:e)?ments?|(?:supporting information|supplementary (?:information|materials?))(?: for)?)\s*$', re.I)
_PUBLISHER_NOTICE = re.compile(r'(?:^view (?:article|journal|issue)|^cite this:|^received\b.{0,100}\baccepted\b|this (?:article|journal) is (?:licensed|©)|open access article\..*downloaded on|^terms of use:|^permanent link:|^published version:)', re.I)
_MATH_WORDS = {'ln', 'log', 'exp', 'sin', 'cos', 'tan', 'arg', 'min', 'max', 'inf', 'sup',
               'det', 'diag', 'tr', 'sum', 'prod', 'lim', 'loss'}
_PROSE_CUES = re.compile(r'\b(?:where|which|whose|when|because|since|although|therefore|thus|hence|'
                         r'denote|denotes|represent|represents|corresponds|indicates|defined|shown|given|'
                         r'we|our|their|the|is|are|was|were|can|should|must|will|consider|let)\b', re.I)


def _lexical_evidence(blocks):
    """Use the document's own unbroken spellings; never invent a dictionary fix."""
    words, compounds = Counter(), Counter()
    for block in blocks:
        text = block['text'].translate(_LIGATURES)
        words.update(word.casefold() for word in _WORD.findall(text))
        compounds.update(word.casefold() for word in re.findall(r'\b[A-Za-z]+-[A-Za-z]+\b', text))
    return words, compounds


def clean_reading_text(text, words=None, compounds=None, *, prose=True):
    """Create a readable projection, retaining an explicit transformation log.

    Raw text is never changed. Only a document-attested unbroken spelling can
    remove a hard line-end hyphen; real/ambiguous compounds retain the hyphen.
    Mathematical font encodings and unknown control glyphs are not guessed.
    """
    words, compounds = words or {}, compounds or {}
    edits, notes = [], []
    original = text
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    translated = text.translate(_LIGATURES)
    if translated != text:
        edits.append({'kind': 'unicode_ligatures', 'before': text, 'after': translated})
        text = translated

    def unknown(match):
        glyph = match.group()
        replacement = f'⟦U+{ord(glyph):04X}⟧'
        edits.append({'kind': 'unmapped_control_glyph', 'before': glyph, 'after': replacement})
        return replacement

    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', unknown, text)
    if any(edit['kind'] == 'unmapped_control_glyph' for edit in edits):
        notes.append('PDF 字体包含未映射控制字符；以 Unicode 编号标记，不能据此补写运算符、指数或单位，需查看原页。')
    if prose:
        def unwrap(match):
            left, right = match.groups()
            joined, compound = left + right, left + '-' + right
            if '\u00ad' in match.group() or (words.get(joined.casefold(), 0) and not compounds.get(compound.casefold(), 0)):
                after, basis = joined, 'soft_hyphen' if '\u00ad' in match.group() else 'unbroken_spelling_elsewhere_in_document'
            else:
                after, basis = compound, 'attested_compound' if compounds.get(compound.casefold(), 0) else 'ambiguous_hyphen_preserved'
                if basis == 'ambiguous_hyphen_preserved':
                    notes.append(f'行末连字符可能是断词或复合词，未猜改：{compound}')
            edits.append({'kind': 'line_end_hyphen', 'before': match.group(), 'after': after, 'basis': basis})
            return after
        text = _WRAPPED_WORD.sub(unwrap, text)
        # Normal PDF layout wraps (including separately justified words) are
        # spaces, not semantic line breaks. Equation/table projections keep rows.
        text = re.sub(r'\s+', ' ', text).strip()
        text = re.sub(r'\s+([,;:.!?，。；：！？])', r'\1', text)
    else:
        text = '\n'.join(re.sub(r'[ \t]+', ' ', line).strip() for line in text.splitlines()).strip()
    if text != original and not edits:
        edits.append({'kind': 'layout_whitespace', 'before': original, 'after': text})
    return text, edits, list(dict.fromkeys(notes))


def _document_page(block):
    return block.get('document_id', 'main'), block['page']


def _reading_font(block):
    counts = Counter()
    for line in block.get('lines', []):
        if abs(line.get('direction', [1, 0])[1]) < .05:
            counts[round(line.get('font_size', 10), 2)] += len(line.get('text', '').strip())
    return counts.most_common(1)[0][0] if counts else 10.


def _page_metrics(source):
    metrics = {}
    for page in source.get('pages', []):
        key = _document_page(page)
        if page.get('width') and page.get('height'):
            metrics[key] = (page['width'], page['height'])
    # Legacy source.json has exact glyph boxes but no page dimensions. Margins
    # inferred from all boxes are used only for conservative classification.
    extents = {}
    for block in source['blocks']:
        key, box = _document_page(block), block.get('bbox')
        if box and key not in metrics:
            before = extents.get(key, (0, 0))
            extents[key] = (max(before[0], box[2]), max(before[1], box[3]))
    for key, (right, bottom) in extents.items():
        metrics[key] = (right + 25, bottom + 20)
    return metrics


def _role_signature(text):
    text = re.sub(r'\s+', ' ', text).strip().casefold()
    # Journals often alternate the page number before/after the same footer.
    text = re.sub(r'^\d+\s*[|·]\s*|\s*[|·]\s*\d+$', '', text)
    return re.sub(r'\d+', '#', text)


def _standalone_expression(text):
    """Recognize symbolic display text without interpreting its PDF glyphs.

    A few ASCII identifiers can make a formula look like a short English
    sentence. Require a mathematical shape and no prose clause before moving
    it to the formula index. Mixed explanation stays in the main reading.
    This never translates font encodings such as ¼/þ into guessed operators.
    """
    text = re.sub(r'\s+', ' ', text).strip()
    if _PROSE_CUES.search(text) or re.search(r'[\u3400-\u9fff]', text):
        return False
    mathematical_shape = re.search(r'[=∑∏∫⇒→⇌¼þ÷]|->|[pqL]ð|\b(?:log|ln|exp)\s*\(|[A-Za-z]\([^)]*\|', text)
    # Some PDF math fonts encode a reaction arrow as !. A bare rate constant
    # followed by a molecular identifier is symbolic; an exclamation mark in
    # a sentence (including "No CO!") is not sufficient evidence.
    bare_rate_reaction = re.fullmatch(r'k[a-z0-9_]{0,3}\s+[A-Z][A-Z0-9*]*\s*!', text)
    if not mathematical_shape and not bare_rate_reaction:
        return False
    tokens = re.findall(r'(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]*(?![A-Za-z0-9])', text)
    prose_words = [word for word in tokens if len(word) >= 3 and word.casefold() not in _MATH_WORDS
                   and not re.search(r'[0-9]', word) and not word.isupper()
                   and not re.search(r'[A-Z]', word[1:])
                   and not re.search(r'\b' + re.escape(word) + r'\s*\(', text)]
    return len(prose_words) <= 2


def _reading_role(block, metrics, repeated, cover_pages, body_sizes, page_counts, body_pages):
    text = re.sub(r'\s+', ' ', block['text']).strip()
    page_key = _document_page(block)
    hint, box = block.get('source_role_hint'), block.get('bbox')
    if not text:
        if any(block['id'] in observation.get('source_ids', []) and observation.get('observation')
               for observation in block.get('layout_observations', [])):
            return 'equation_fragment', True, '此空白映射已有关联版面复核，作为未映射数学字形保留，不能当作无内容空白丢弃。'
        return 'whitespace', False, '原版面空白保留于原始来源。'
    if page_key in cover_pages:
        return 'repository_cover', False, '仓储存取/版本/许可封面，不作为论文科学正文。'
    if hint == 'page_number':
        return hint, False, '页码保留于原始来源。'
    if hint == 'marginal':
        if _PUBLISHER_NOTICE.search(text) or re.search(r'licensed under|downloaded on|all rights reserved|creativecommons\.org', text, re.I):
            return 'publisher_notice', False, '旋转边栏中的许可或访问记录，不作为科学正文。'
        return 'layout_fragment', True, '旋转文字可能是科学图轴或图例，保留在版面片段中，不能仅凭旋转方向当作出版杂讯。'
    # A real section/caption can recur at a page edge (continued tables).
    # Its scientific role takes precedence over repetition heuristics.
    if _SECTION.fullmatch(text) or (len(text) < 120 and re.match(r'^appendi(?:x|ces)\b', text, re.I)):
        return 'heading', True, ''
    if re.match(r'^(?:Fig(?:ure)?\.?|Table)\s+[A-Za-z]?\d+[A-Za-z]?\b', text, re.I):
        return 'caption', True, ''
    width, height = metrics.get(page_key, (0, 0))
    if box and height:
        margin = box[3] < height * .13 or box[1] > height * .90
        if re.fullmatch(r'\d{1,4}', text) and margin:
            return 'page_number', False, '页边页码。'
        repeated_pages = len(repeated.get((page_key[0], _role_signature(text)), set()))
        header_shape = (len(text.split()) >= 2 or re.fullmatch(r'[A-Z]{3,12}', text)
                        or text.casefold() in {'paper', 'article', 'review'})
        if (margin and page_key in body_pages and header_shape and len(re.findall(r'[A-Za-z\u3400-\u9fff]', text)) >= 3
                and repeated_pages >= max(3, page_counts[page_key[0]] * .5)):
            return ('page_header' if box[3] < height * .13 else 'page_footer'), False, '至少三页相同页边文字（数字变化不影响匹配）。'
    if _PUBLISHER_NOTICE.search(text):
        return 'publisher_notice', False, '出版导航、许可或访问记录，不作为科学正文。'
    if (text.casefold() in {'paper', 'article', 'review', 'research article'} and box and height
            and box[3] < height * .2 and len(repeated.get((page_key[0], _role_signature(text)), set())) >= 3):
        return 'publisher_notice', False, '重复出现的出版物类型页眉。'
    if re.match(r'^(?:Department|School|Faculty|Institute|Corresponding author|ORCID|E-mail|Email)\b', text, re.I):
        # Affiliations are retained separately; prose discussing an institute is
        # not removed solely because it contains this word later in a sentence.
        if len(text) < 500 and (re.search(r'@|\b(?:University|Institute|Technology|ORCID|E-mail|Email|Department)\b', text) or len(text.split()) < 12):
            return 'author_metadata', False, '作者机构或联系方式，保留于文献信息来源。'
    font = _reading_font(block)
    body = body_sizes.get(page_key[0], font)
    if len(text) < 240 and len(text.split()) <= 28 and font >= body * 1.25:
        return 'heading', True, ''
    if re.match(r'^(?:\d+(?:\.\d+)*\.?\s+){1,2}[A-Z][A-Za-z :–—-]+$', text) and len(text.split()) < 20:
        return 'heading', True, ''
    if _standalone_expression(text):
        return 'equation_fragment', True, '独立数学或反应表达式，保留原始符号和行结构；不交由正文校订猜改字体编码或运算符。'
    lexical = re.findall(r'[A-Za-z]{3,}|[\u3400-\u9fff]', text)
    word_tokens = re.findall(r'[A-Za-z][A-Za-z0-9]*|[\u3400-\u9fff]', text)
    # Word count alone does not distinguish an axis label from a short but
    # crucial result such as "No catalyst was used" or "Conversion reached 95%".
    # Prefer readable prose when sentence/measurement evidence exists; keep
    # undecodable mathematical glyphs in the separate formula evidence index.
    control_glyphs = bool(re.search(r'[\x00-\x08\x0b\x0e-\x1f]', text))
    complete_short_sentence = len(word_tokens) >= 2 and re.search(r'[.!?。！？][”"\')\]]*$', text)
    short_prose = len(word_tokens) >= 3 and any(re.search(r'[a-z]{2,}', word) for word in word_tokens)
    equation_operators = bool(re.search(r'[=∑∏∫]', text))
    if not control_glyphs and (len(lexical) >= 3 or ((complete_short_sentence or short_prose) and not equation_operators)
                              or (len(lexical) >= 2 and re.search(r'\d', text))):
        return 'body', True, ''
    emphasized = [line for line in block.get('lines', []) if line.get('font_flags', 0) & 16 or 'bold' in line.get('font', '').casefold()]
    if emphasized and 1 <= len(lexical) < 18 and len(text) < 140 and not re.search(r'[=∑∏∫⇒→⇌]', text):
        return 'heading', True, ''
    if not box:
        # Plain text, Markdown and PDFKit fallbacks have no geometry supporting
        # a plot/equation-fragment inference. Short source paragraphs stay main.
        return 'body', True, ''
    if len(lexical) < 5:
        if re.search(r'[=∑∏∫⇒→⇌𝑎-𝟿]|[\x00-\x08\x0b\x0e-\x1f]', text) or re.fullmatch(r'\(?\d{1,3}\)?', text):
            return 'equation_fragment', True, '短公式/数值版面片段，保留原行结构；应与页图/公式区对照，不单独推导结论。'
        return 'layout_fragment', True, '短版面片段可能属于图表、作者或公式；保留而不自动当成完整句。'
    return 'body', True, ''


def _can_continue_reading(previous, current, metrics):
    role = previous.get('reading_role')
    if role not in {'body', 'reference'} or current.get('reading_role') != role:
        return False
    if previous.get('document_id', 'main') != current.get('document_id', 'main'):
        return False
    first, second = previous['reading_text'].rstrip(), current['reading_text'].lstrip()
    if not first or not second:
        return False
    if role == 'body':
        if re.search(r'[.!?。！？][\d,–—\-\]”"\')]*$', first) or not re.match(r'[a-z\u3400-\u9fff]', second):
            return False
    elif re.match(r'^(?:\(\d{1,3}\)|\[\d{1,3}\]|\d{1,3}[.)]?)\s+[A-Z]', second):
        return False
    a, b = previous.get('bbox'), current.get('bbox')
    if not a or not b or previous.get('grouping_notes') or current.get('grouping_notes'):
        return False
    size, next_size = _reading_font(previous), _reading_font(current)
    if abs(size - next_size) > max(.7, size * .10):
        return False
    page_width, page_height = metrics.get(_document_page(previous), (0, 0))
    next_height = metrics.get(_document_page(current), (0, 0))[1]
    width_a, width_b = a[2] - a[0], b[2] - b[0]
    same_column = min(a[2], b[2]) - max(a[0], b[0]) > min(width_a, width_b) * .65
    if current['page'] == previous['page']:
        if same_column:
            return a[1] <= b[1] <= a[3] + size * 2.5 and b[0] <= a[0] + size * .7
        return bool(page_width and b[0] > a[0] + page_width * .25
                    and b[1] < a[3] and .7 < width_b / max(width_a, 1) < 1.45)
    return bool(current['page'] == previous['page'] + 1 and same_column
                and page_height and a[3] > page_height * .65 and b[1] < next_height * .23)


def _can_continue_numeric(previous, current, role):
    """Join an immediately wrapped scalar after a prose/caption equals sign.

    The same page, left edge, font and normal line gap distinguish a caption
    continuation from nearby graph ticks. Do not infer missing digits or units.
    """
    if previous is None or previous.get('reading_role') not in {'body', 'caption'}:
        return False
    if role not in {'body', 'layout_fragment', 'equation_fragment'} or current.get('source_role_hint') == 'marginal':
        return False
    if _document_page(previous) != _document_page(current) or not previous.get('reading_text', '').rstrip().endswith('='):
        return False
    if not re.fullmatch(r'\s*[+−-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+−-]?\d+)?\s*%?[.,;]?\s*', current['text']):
        return False
    a, b = previous.get('bbox'), current.get('bbox')
    if not a or not b or not previous.get('lines') or not current.get('lines'):
        return False
    if previous.get('grouping_notes') or current.get('grouping_notes'):
        return False
    size, next_size = _reading_font(previous), _reading_font(current)
    if abs(size - next_size) > max(.7, size * .10):
        return False
    return (abs(a[0] - b[0]) <= size * .7 and a[3] <= b[1] <= a[3] + size * 1.25
            and 0 < b[3] - b[1] <= size * 1.7)


def apply_reading_layer(source):
    """Add a conservative reading projection without altering raw text or IDs.

    Reading groups carry canonical source_ids, page ranges and reasons for
    changes. All excluded material remains in blocks/raw_blocks and in a
    separate index. This is a layout/reading aid, not scientific acceptance.
    The function can also upgrade an existing source.json in memory.
    """
    blocks = source['blocks']
    words, compounds = _lexical_evidence(blocks)
    metrics = _page_metrics(source)
    repeated, by_page, fonts = {}, {}, {}
    for block in blocks:
        key = _document_page(block)
        repeated.setdefault((key[0], _role_signature(block['text'])), set()).add(key[1])
        by_page.setdefault(key, []).append(block)
        fonts.setdefault(key[0], Counter())[_reading_font(block)] += len(block['text'])
    body_sizes = {document: sizes.most_common(1)[0][0] for document, sizes in fonts.items()}
    page_counts = Counter(key[0] for key in by_page)
    body_pages = set()
    for key, values in by_page.items():
        height = metrics.get(key, (0, 0))[1]
        if height and any(b.get('bbox') and b['bbox'][1] < height * .85
                          and (b['bbox'][1] + b['bbox'][3]) / 2 > height * .15
                          and len(re.findall(r'[A-Za-z]{3,}|[\u3400-\u9fff]', b['text'])) >= 5 for b in values):
            body_pages.add(key)
    covers = set()
    for key, values in by_page.items():
        page_text = '\n'.join(block['text'] for block in values)
        labels = sum(bool(re.search(pattern, page_text, re.I | re.M)) for pattern in
                     [r'^\s*permanent link:', r'^\s*terms of use:', r'^\s*published version:', r'^\s*version:', r'^\s*citation:'])
        if labels >= 3 and not re.search(r'^\s*(?:Abstract|\d+\.?\s+Introduction)\b', page_text, re.I | re.M):
            covers.add(key)
    first_pages = {}
    for key in sorted(by_page):
        if key not in covers:
            first_pages.setdefault(key[0], key)
    abstract_tops = {}
    for key in first_pages.values():
        long_paragraphs = [b for b in by_page[key] if b.get('bbox') and len(b['text'].split()) >= 45]
        if long_paragraphs:
            abstract_tops[key] = min(b['bbox'][1] for b in long_paragraphs)
    excluded, groups, previous, previous_group = [], [], None, None
    by_id = {block['id']: block for block in blocks}
    in_references = {}
    for block in blocks:
        role, included, reason = _reading_role(block, metrics, repeated, covers, body_sizes, page_counts, body_pages)
        document = block.get('document_id', 'main')
        if role == 'heading':
            heading = re.sub(r'^\s*\d+(?:\.\d+)*\.?\s*', '', block['text']).strip().casefold()
            if heading.startswith('references'):
                in_references[document] = True
            elif re.search(r'support|supplement|appendix', heading):
                in_references[document] = False
        elif in_references.get(document) and (included or role == 'author_metadata'):
            # A bibliography can contain journal names beginning with
            # 'Institute' or 'Department'; they are not author affiliations.
            role, included, reason = 'reference', True, ''
        elif (role == 'body' and _document_page(block) in abstract_tops and block.get('bbox')
              and block['bbox'][3] < abstract_tops[_document_page(block)]
              and len(block['text'].split()) < 25 and _reading_font(block) > body_sizes[document] * 1.04):
            role, included, reason = 'author_metadata', False, '论文标题与首段正文之间的短署名文字，另列文献信息。'
        numeric_continuation = included and _can_continue_numeric(previous, block, role)
        if numeric_continuation:
            role = previous['reading_role']
            reason = '等号后的独立数值与前文同页、同列、同字号且紧邻下一行，作为原句续行保留；未改数值或补写单位。'
        text, edits, notes = clean_reading_text(block['text'], words, compounds,
                                               prose=role not in {'equation_fragment', 'layout_fragment'})
        notes = list(dict.fromkeys(list(block.get('grouping_notes', [])) + notes))
        observations = [item for item in block.get('layout_observations', [])
                        if block['id'] in item.get('source_ids', []) and item.get('observation')]
        notes.extend('已记录版面复核：' + item['observation'] for item in observations)
        if not text and observations:
            text = '⟦PDF 未映射字形；请查看对应原页与版面复核⟧'
            edits.append({'kind': 'observed_blank_glyph', 'before': block['text'], 'after': text,
                          'basis': 'source_linked_layout_observation_no_symbol_guessed'})
        if reason:
            notes.insert(0, reason)
        main = included and role not in {'equation_fragment', 'layout_fragment'}
        block.update(reading_text=text, reading_role=role, include_in_reading=included, reading_main=main,
                     reading_edits=edits, reading_notes=notes)
        entry = {'id': block['id'], 'source_ids': [block['id']], 'text': text, 'reading_text': text,
                 'kind': role, 'role': role, 'reading_role': role, 'include_in_reading': included,
                 'reading_main': main,
                 'page': block['page'], 'pages': [block['page']], 'document_id': document,
                 'reading_notes': list(notes)}
        if observations:
            entry['layout_observations'] = observations
        if not included:
            excluded.append(entry)
            # Page furniture can interrupt the physical block list, but does
            # not interrupt a supported page/column continuation.
            continue
        continuation = numeric_continuation or (previous is not None and _can_continue_reading(previous, block, metrics))
        group, joined_from, skipped_fragments = previous_group, previous, []
        if not continuation and role == 'body':
            # Inline formula glyphs may be emitted before a wrapped word's
            # continuation. Rejoin only an attested split word; keep the glyphs
            # separately indexed, never pretend to reconstruct the equation.
            candidate = len(groups) - 1
            while candidate >= 0 and groups[candidate]['kind'] in {'equation_fragment', 'layout_fragment'}:
                skipped_fragments[0:0] = groups[candidate]['source_ids']
                candidate -= 1
            if skipped_fragments and candidate >= 0 and groups[candidate]['kind'] == 'body':
                proposed = groups[candidate]
                last = by_id[proposed['source_ids'][-1]]
                left = re.search(r'([A-Za-z]{2,})-$', proposed['text'])
                right = re.match(r'([a-z][A-Za-z]*)', text)
                if (left and right and words.get((left[1] + right[1]).casefold(), 0)
                        and _can_continue_reading(last, block, metrics)):
                    continuation, group, joined_from = True, proposed, last
        if continuation:
            combined, join_edits, join_notes = clean_reading_text(group['text'] + '\n' + text, words, compounds)
            group['text'] = group['reading_text'] = combined
            group['source_ids'].append(block['id'])
            group['pages'] = list(dict.fromkeys(group['pages'] + [block['page']]))
            group['reading_notes'] = list(dict.fromkeys(group['reading_notes'] + notes + join_notes))
            basis = 'numeric_continuation_after_equals_and_matching_layout' if numeric_continuation else 'unfinished_sentence_and_matching_layout'
            group.setdefault('joins', []).append({'from': joined_from['id'], 'to': block['id'], 'basis': basis, 'edits': join_edits})
            if skipped_fragments:
                group.setdefault('linked_layout_source_ids', []).extend(skipped_fragments)
                group['reading_notes'].append('断词之间的独立公式字形仍保留在版面片段索引，未据此重构公式。')
        else:
            groups.append(entry)
            group = entry
        previous = block
        previous_group = group
    source['reading_blocks'] = groups
    source['reading_excluded'] = excluded
    source['reading_main_blocks'] = [group for group in groups if group['reading_main']]
    source['reading_fragments'] = [group for group in groups if not group['reading_main']]
    source['reading_layer'] = {'version': 'source-reading-v1', 'source_block_count': len(blocks),
                               'reading_group_count': len(groups), 'excluded_block_count': len(excluded),
                               'main_reading_group_count': len(source['reading_main_blocks']),
                               'fragment_group_count': len(source['reading_fragments']),
                               'roles': dict(Counter(block['reading_role'] for block in blocks)),
                               'raw_text_unchanged': True,
                               'acceptance': 'layout_and_typographic_projection_only_not_scientific_acceptance'}
    assigned = [identifier for group in groups + excluded for identifier in group['source_ids']]
    if len(assigned) != len(blocks) or set(assigned) != {block['id'] for block in blocks} or len(set(assigned)) != len(assigned):
        raise ValueError('Reading layer must account for every canonical source block exactly once.')
    return source
