"""Versioned AI editorial revision without mutating or depending on the old run."""
from __future__ import annotations

import copy
import datetime as dt
import re
import shutil
import signal
import threading
import urllib.parse
import uuid
from pathlib import Path

from .contracts import PipelineCancelled, PipelineError, read_json, sha256, validate_request, write_json


def _check_documents(documents):
    for document in documents:
        path = Path(document['path'])
        if not path.is_file() or sha256(path) != document['sha256']:
            raise PipelineError('原文或补充材料已改变或丢失；不能混用不同来源，请重新生成资料。')


def _coverage(source):
    main = [identifier for group in source.get('reading_main_blocks', []) for identifier in group['source_ids']]
    main_set = set(main)
    auxiliary = [block['id'] for block in source['blocks'] if block.get('include_in_reading') and block['id'] not in main_set]
    excluded = [block['id'] for block in source['blocks'] if not block.get('include_in_reading')]
    return {'main_source_ids': main, 'auxiliary_source_ids': auxiliary, 'excluded_source_ids': excluded,
            'reading_groups': len(source.get('reading_main_blocks', [])), 'canonical_blocks': len(source['blocks']),
            'human_scientific_acceptance': False}


def _metrics(source, learning, extraction, provider):
    coverage = _coverage(source)
    return {'pages': len(source['pages']), 'source_blocks': len(source['blocks']),
            'raw_source_blocks': len(source.get('raw_blocks', source['blocks'])),
            'processed_blocks': len(learning.get('paragraphs', [])), 'explained_blocks': len(learning.get('paragraphs', [])),
            'source_characters': sum(len(page['text']) for page in source['pages']),
            'page_previews': len(source.get('figures', [])), 'records': len(extraction.get('records', [])),
            'equations': len(learning.get('equations', [])), 'quiz_questions': len(learning.get('quiz', [])),
            'calculations': len(learning.get('calculations', [])), 'reading_groups': coverage['reading_groups'],
            'reading_evidence_groups': len(source.get('reading_blocks', [])),
            'main_source_blocks': len(coverage['main_source_ids']), 'auxiliary_source_blocks': len(coverage['auxiliary_source_ids']),
            'excluded_source_blocks': len(coverage['excluded_source_ids']),
            'clean_reading_groups': len(learning.get('clean_reading', [])),
            'thematic_sections': len(learning.get('thematic_sections', [])),
            'figure_candidates': len(source.get('figure_inventory', [])),
            'provider_calls': provider.calls if provider else 0, 'provider_usage': dict(provider.usage) if provider else {}}


def revise(manifest_path, provider_config=None, progress=None, editorial_corrections_path=None, *, editorial_only=False):
    from .pipeline import create_agent, progress as default_progress, update_index
    from .provider import Provider
    from .reading import apply_reading_layer
    from .reading_editions import render_reading_editions
    from .rendering import render_guide
    from .synthesis import polish_reading, consolidate_learning, separate_process_notes
    from .dataset import export_dataset, validate_extraction

    progress = progress or default_progress
    if editorial_only and editorial_corrections_path is None:
        raise PipelineError('只应用审校修订时必须明确提供来源绑定的校订证据。')
    original_path = Path(manifest_path).expanduser().resolve()
    original = read_json(original_path)
    if original.get('status') not in {'completed', 'partial'}:
        raise PipelineError('只有已生成本地资料的版本才能校订；请先完成或恢复原任务。')
    previous = original_path.parent
    for name in ('request.json', 'source.json', 'learning.json', 'extraction.json'):
        if not (previous / name).is_file():
            raise PipelineError(f'原版本缺少 {name}；请先完成或恢复原任务。')
    request = read_json(previous / 'request.json')
    request.update(revision_of=str(original_path))
    if not editorial_only:
        request['mode'] = 'llm'
    request['editorial_only'] = editorial_only
    for key in ('resume_from', 'review_corrections_path', 'extraction_corrections_path', 'summary_corrections_path',
                'paragraph_corrections_path', 'editorial_corrections_path'):
        request.pop(key, None)
    if provider_config is not None:
        request['provider'] = provider_config
    request = validate_request(request)
    original_source = read_json(previous / 'source.json')
    documents = [{'id': 'main', 'path': request['source_path'], 'sha256': original_source['sha256']}]
    documents.extend(document for document in original_source.get('documents', []) if document['path'] != request['source_path'])
    _check_documents(documents)
    provider = None if editorial_only else Provider(request.get('provider', {}))
    root = Path(request['output_root'])
    if root == previous or previous in root.parents:
        raise PipelineError('校订输出根目录不能位于原版本内。')
    root.mkdir(parents=True, exist_ok=True)
    identifier = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:10]
    directory = root / identifier
    directory.mkdir()
    (directory / 'chunks').mkdir()
    (directory / 'draft').mkdir()
    path = directory / 'manifest.json'
    receipt = {**original, 'run_id': identifier, 'created_at': dt.datetime.now(dt.timezone.utc).isoformat(),
               'run_dir': str(directory), 'manifest_path': str(path), 'revision_of': str(original_path),
               'revision_kind': 'source_reviewed_revision' if editorial_only else 'ai_editorial_revision',
               'mode': request['mode'], 'quality': 'generated_unreviewed',
               'status': 'running', 'artifacts': {}, 'metrics': {}, 'warnings': list(original.get('warnings', [])),
               'extraction_reused': True}
    for key in ('error', 'finished_at', 'artifact_sha256', 'integration_errors', 'graphiti', 'paper2agent',
                'portable_artifacts', 'reused_integrations_from'):
        receipt.pop(key, None)
    write_json(directory / 'request.json', request)
    write_json(path, receipt)
    previous_sigterm, cancellation_requested = None, False
    if threading.current_thread() is threading.main_thread():
        previous_sigterm = signal.getsignal(signal.SIGTERM)
        def cancel(signum, frame):
            nonlocal cancellation_requested
            cancellation_requested = True
            raise PipelineCancelled('用户取消了本次校订；原版本及已完成校订均保留。')
        signal.signal(signal.SIGTERM, cancel)
    try:
        # Retain byte-identical prior data for audit. Copy all other local
        # resources, including custom asset folders and upstream task bundles;
        # a fixed list of image directories silently loses valid attachments.
        for name in ('source.json', 'learning.json', 'extraction.json', 'manifest.json', 'request.json'):
            shutil.copyfile(previous / name, directory / 'draft' / name)
        for item in previous.iterdir():
            if item.name in {'chunks', 'draft', 'agent', 'request.json', 'manifest.json', 'source.json', 'learning.json', 'extraction.json'}:
                continue
            if item.is_dir():
                shutil.copytree(item, directory / item.name)
            elif item.is_file():
                shutil.copyfile(item, directory / item.name)

        copied = {}
        for document in documents:
            source_file = Path(document['path']).resolve()
            target = directory / 'documents' / (str(document.get('id', 'source')) + '-' + source_file.name)
            target.parent.mkdir(exist_ok=True)
            shutil.copyfile(source_file, target)
            if sha256(target) != document['sha256']:
                raise PipelineError('复制来源时文件发生改变；校订已停止。')
            copied[str(source_file)] = str(target)

        def relocate(value, key=''):
            if isinstance(value, dict):
                return {name: relocate(item, name) for name, item in value.items()}
            if isinstance(value, list):
                return [relocate(item, key) for item in value]
            if not isinstance(value, str):
                return value
            if value in copied:
                return copied[value]
            if value == str(previous) or value.startswith(str(previous) + '/'):
                return str(directory) + value[len(str(previous)):]
            # Source metadata may reference a manually supplied crop outside
            # the run. Preserve it locally as well, without interpreting prose
            # strings or copying arbitrary provider configuration.
            if key in {'path', 'image_path', 'asset_path', 'preview_path', 'file_path'} and Path(value).is_absolute():
                resource = Path(value)
                if resource.is_file():
                    target = directory / 'assets' / (sha256(resource)[:16] + '-' + resource.name)
                    target.parent.mkdir(exist_ok=True)
                    shutil.copyfile(resource, target)
                    copied[value] = str(target)
                    return str(target)
            return value

        source = relocate(copy.deepcopy(original_source))
        if not editorial_only:
            source = apply_reading_layer(source)
        learning = relocate(copy.deepcopy(read_json(previous / 'learning.json')))
        extraction = relocate(copy.deepcopy(read_json(previous / 'extraction.json')))
        if editorial_only:
            from .synthesis import reading_groups
            groups = reading_groups(source)
            clean = learning.get('clean_reading', [])
            if not groups or [item.get('id') for item in clean] != [group['id'] for group in groups]:
                raise PipelineError('只应用审校修订需要已有完整、对应当前来源阅读组的正文。')
            if any(item.get('source_ids') != group['source_ids'] for item, group in zip(clean, groups)):
                raise PipelineError('只应用审校修订不能改变正文与原文的来源映射。')
        elif learning.get('mode') != 'llm':
            learning['overview'] = '本版已根据完整来源生成原语言校订与中文译述，内容仍需结合原文核验。自定义字段沿用原版本，没有在校订时重新提取。'
            old_notes = [note for note in learning.get('gaps', []) if isinstance(note, str) and note.startswith('未调用模型')]
            learning.setdefault('process_notes', []).extend(old_notes)
            learning['gaps'] = [note for note in learning.get('gaps', []) if note not in old_notes]
        if not editorial_only:
            learning['mode'] = 'llm'
        learning['reading_coverage'] = _coverage(source)
        request['source_path'] = copied[str(Path(request['source_path']).resolve())]
        request['supplementary_paths'] = [copied[str(Path(item).resolve())] for item in request.get('supplementary_paths', [])]
        request.pop('source_pages_path', None)  # Source extraction is reused, never repeated here.
        receipt['source_path'] = source['path']
        receipt['source_sha256'] = source['sha256']
        receipt['documents'] = source.get('documents', [])
        artifacts = receipt['artifacts']
        artifacts.update({'source': str(directory / 'source.json'), 'raw_source_markdown': str(directory / 'source.md'),
                          'prior_manifest': str(directory / 'draft' / 'manifest.json'),
                          'editorial_draft': str(directory / 'draft' / 'learning.json')})
        if not (directory / 'source.md').is_file():
            (directory / 'source.md').write_text(source.get('markdown', ''), encoding='utf-8')
        if source.get('canonical_markdown') is not None and not (directory / 'markitdown.md').is_file():
            (directory / 'markitdown.md').write_text(source['canonical_markdown'], encoding='utf-8')
        if (directory / 'markitdown.md').is_file():
            artifacts['converted_markdown'] = str(directory / 'markitdown.md')
        # Markdown conversions can link files that are not in figure metadata.
        # Keep local links relative and copy their targets, including links to
        # sibling files next to the original input document.
        for markdown in directory.rglob('*.md'):
            if 'draft' in markdown.relative_to(directory).parts:
                continue
            prior_markdown = previous / markdown.relative_to(directory)
            def local_link(match):
                target = match.group(1).strip()
                parsed = urllib.parse.urlsplit(target.strip('<>'))
                if parsed.scheme or parsed.netloc or not parsed.path:
                    return match.group()
                relative = Path(urllib.parse.unquote(parsed.path))
                candidates = [relative] if relative.is_absolute() else [prior_markdown.parent / relative, Path(documents[0]['path']).parent / relative]
                resource = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
                if resource is None:
                    return match.group()
                if resource == previous or previous in resource.parents:
                    destination = directory / resource.relative_to(previous)
                else:
                    destination = directory / 'assets' / (sha256(resource)[:16] + '-' + resource.name)
                if not destination.exists():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(resource, destination)
                import os
                new_target = urllib.parse.quote(os.path.relpath(destination, markdown.parent), safe='/')
                if parsed.fragment:
                    new_target += '#' + parsed.fragment
                return match.group().replace(match.group(1), new_target, 1)
            content = markdown.read_text(encoding='utf-8')
            updated = re.sub(r'!?\[[^\]\n]*\]\(([^)\n]+)\)', local_link, content)
            if updated != content:
                markdown.write_text(updated, encoding='utf-8')
        # Relocate all copied JSON task/resource records. Frozen draft files
        # remain byte-identical evidence; active files refer to this edition.
        for record in directory.rglob('*.json'):
            if 'draft' in record.relative_to(directory).parts or record.name in {'request.json', 'manifest.json'}:
                continue
            try:
                value = read_json(record)
            except (ValueError, UnicodeError):
                continue
            write_json(record, relocate(value))
        inventory = relocate(read_json(previous / 'figures.json')) if (previous / 'figures.json').is_file() else {}
        inventory.update(items=source.get('figure_inventory', []), coverage=source.get('figure_coverage'), documents=source.get('documents', []))
        write_json(directory / 'figures.json', inventory)
        artifacts['figure_inventory'] = str(directory / 'figures.json')
        write_json(directory / 'request.json', request)
        write_json(directory / 'source.json', source)
        for figure in source.get('figures', []) + source.get('figure_crops', []) + source.get('figure_inventory', []):
            resource = figure.get('image_path') or figure.get('path')
            if resource and not Path(resource).is_file():
                raise PipelineError(f'原版本引用的图像资源缺失：{resource}')
        bundle = None
        # Revisions of an already reviewed edition retain its source-bound
        # evidence. Revalidate the source and page hashes before applying it;
        # an explicit replacement bundle takes precedence.
        review_path = editorial_corrections_path or original.get('artifacts', {}).get('editorial_corrections_input')
        if review_path is not None:
            from .editorial_review import load_editorial_review
            corrections = Path(review_path).expanduser().resolve()
            bundle = load_editorial_review(corrections, source)
            correction_copy = directory / 'editorial-corrections-input.json'
            shutil.copyfile(corrections, correction_copy)
            request['editorial_corrections_path'] = str(correction_copy)
            source['editorial_review_context'] = bundle
            artifacts['editorial_corrections_input'] = str(correction_copy)
        write_json(directory / 'request.json', request)
        write_json(directory / 'source.json', source)
        receipt['metrics'] = _metrics(source, learning, extraction, provider)
        write_json(path, receipt)
        if editorial_only:
            progress('应用原页核验修订并另存版本')
        else:
            progress('对照完整原文，校订英文正文与中文译述')
            polish_reading(source, learning, provider, directory, progress)
            write_json(directory / 'learning.json', learning)
        artifacts['learning'] = str(directory / 'learning.json')
        if not editorial_only:
            progress('对照原文重新整理中文主题、限定条件和学习条目')
            # Revise the last reader-facing edition. The untouched draft/
            # snapshot retains earlier raw model cards for audit; restarting
            # from those cards can resurrect already corrected science.
            prior_cards = learning.get('consolidated', {})
            for key in ('methods', 'findings', 'critique', 'transfer', 'quiz', 'glossary'):
                if isinstance(prior_cards.get(key), list):
                    learning[key] = copy.deepcopy(prior_cards[key])
            consolidate_learning(learning, source, provider, directory, progress)
        if bundle is not None:
            from .editorial_review import apply_editorial_review
            artifacts.update(apply_editorial_review(learning, source, bundle, directory, require_exact=editorial_only))
        separate_process_notes(learning)
        learning['reading_coverage'] = _coverage(source)
        warnings = receipt['warnings']
        warnings.extend(note for note in validate_extraction(extraction, source) if note not in warnings)
        warnings.extend(note for note in extraction.get('warnings', []) if note not in warnings)
        write_json(directory / 'learning.json', learning)
        write_json(directory / 'extraction.json', extraction)
        artifacts['extraction'] = str(directory / 'extraction.json')
        artifacts.update(render_reading_editions(source, learning, directory))
        artifacts.update(render_guide(source, learning, extraction, directory, warnings))
        artifacts.update(export_dataset(extraction, directory, source))
        artifacts['agent'] = create_agent(source, extraction, request, directory)
        artifacts['mcp'] = str(directory / 'agent' / 'mcp.json')
        if request.get('book', {}).get('enabled', True) and request.get('book'):
            from .book import render_book
            artifacts.update(render_book(source, learning, extraction, request['book'], directory, warnings))
        for key in ('graphiti', 'upstream_paper2agent'):
            if key in original.get('artifacts', {}):
                old_record = Path(original['artifacts'][key])
                if not old_record.is_file():
                    raise PipelineError(f'上一版本的集成记录缺失：{old_record.name}')
                def preserve_integrated_input(value):
                    if isinstance(value, dict):
                        return {name: preserve_integrated_input(item) for name, item in value.items()}
                    if isinstance(value, list):
                        return [preserve_integrated_input(item) for item in value]
                    if isinstance(value, str) and value.startswith(str(previous) + '/') and Path(value).is_file():
                        # An old graph receipt must still describe the exact
                        # old text it ingested, not this edition's edited text.
                        snapshot = directory / 'draft' / 'integration-inputs' / Path(value).relative_to(previous)
                        snapshot.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(value, snapshot)
                        return str(snapshot)
                    return relocate(value)
                target = directory / old_record.name
                write_json(target, preserve_integrated_input(read_json(old_record)))
                artifacts[key] = str(target)
        if any(key in artifacts for key in ('graphiti', 'upstream_paper2agent')):
            receipt['reused_integrations_from'] = str(original_path)
            warnings.append('本次只校订阅读资料；Graphiti 与 Paper2Agent 保留上一版本的独立任务记录，未重新写入或执行。')
        _check_documents(documents)
        if cancellation_requested:
            raise PipelineCancelled('用户取消了本次校订；已保留完成的内容。')
        receipt.update(status='completed', finished_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                       metrics=_metrics(source, learning, extraction, provider),
                       portable_artifacts={key: str(Path(value).relative_to(directory)) for key, value in artifacts.items()},
                       artifact_sha256={key: sha256(value) for key, value in artifacts.items() if Path(value).is_file()})
        write_json(path, receipt)
        update_index(root, receipt)
        progress(f'校订完成：{directory}')
        return receipt
    except Exception as error:
        receipt.update(status='cancelled' if cancellation_requested or isinstance(error, PipelineCancelled) else 'failed',
                       error=str(error), finished_at=dt.datetime.now(dt.timezone.utc).isoformat())
        receipt['metrics'].update(provider_calls=provider.calls if provider else 0, provider_usage=dict(provider.usage) if provider else {})
        write_json(path, receipt)
        update_index(root, receipt)
        error_type = PipelineCancelled if receipt['status'] == 'cancelled' else PipelineError
        raise error_type(f'{error}（已保存运行记录：{path}）') from error
    finally:
        if previous_sigterm is not None:
            signal.signal(signal.SIGTERM, previous_sigterm)
