"""Apply explicit, source-checked editorial corrections without erasing history."""
from __future__ import annotations

import copy
from pathlib import Path

from .contracts import PipelineError, read_json, write_json


def layout_observations(source,request):
    path = request.get('layout_observations_path')
    if not path:
        return []
    values = read_json(Path(path).expanduser())
    if not isinstance(values,list):
        raise PipelineError('版面核验观察必须为数组。')
    documents = {Path(item['path']).stem:item for item in source['documents']}
    blocks = {item['id']:item for item in source['blocks']}
    result = []
    for item in values:
        if not isinstance(item,dict):
            raise PipelineError('版面核验观察必须为对象。')
        document = documents.get(item.get('paper'))
        if not document:
            continue
        if item.get('source_sha256')!=document['sha256']:
            raise PipelineError('版面核验观察与源文件哈希不一致，不能复用。')
        if not all(isinstance(item.get(key),str) and item[key] for key in ('observation','verification')):
            raise PipelineError('版面核验观察需要说明及核验记录。')
        ids = item.get('source_ids',[])
        if not ids or any(identifier not in blocks or blocks[identifier].get('document_id','main')!=document['id'] for identifier in ids):
            raise PipelineError('版面核验观察引用了不存在或不属于该文件的来源。')
        result.append({**item,'document_id':document['id'],'kind':item.get('kind','layout_verification')})
    return result


def load_corrections(request):
    path = request.get('review_corrections_path')
    if not path:
        return []
    corrections = read_json(Path(path).expanduser())
    if not isinstance(corrections,list):
        raise PipelineError('学习稿审阅修正必须为数组。')
    for correction in corrections:
        if not isinstance(correction,dict) or not all(isinstance(correction.get(key),str) and correction[key] for key in ('paper','section','field','reason')):
            raise PipelineError('审阅修正需要paper/section/field/original/corrected/reason。')
        if type(correction.get('chunk')) is not int or not isinstance(correction.get('source_ids'),list) or not correction['source_ids']:
            raise PipelineError('审阅修正需要来源ID及分块编号。')
        if correction['field'] not in {'explanation','reasoning','body','reading','meaning','definition','english','answer','symbols','translation_units','text','latex','expression','title','interpretation'}:
            raise PipelineError('此审阅入口只修改讲解文字，不能修改原文、字段值或证据。')
        for key in ('original','corrected'):
            value = correction.get(key)
            if correction['field'] in {'symbols','translation_units'}:
                keys = ('symbol','meaning') if correction['field']=='symbols' else ('unit_id','translation')
                if not isinstance(value,list) or any(not isinstance(item,dict) or not all(isinstance(item.get(field),str) for field in keys) for item in value):
                    raise PipelineError('符号或逐句译述审阅修正必须保留对应的ID和文字对象数组。')
            elif not isinstance(value,str) or not value:
                raise PipelineError('审阅修正的前后值必须为非空文字。')
    return corrections


def apply_corrections(result,source,chunk_index,corrections,chunk_dir,review_log):
    applicable = [item for item in corrections if item['paper']==Path(source['path']).stem and item['chunk']==chunk_index]
    if not applicable:
        return result
    original = copy.deepcopy(result)
    for correction in applicable:
        if correction['section']=='summary' and correction['field']=='text':
            source_ids = {item.get('source_id') for item in result.get('paragraphs',[])}
            if not set(correction['source_ids'])<=source_ids or result.get('summary') not in (correction['original'],correction['corrected']):
                raise PipelineError(f'分块{chunk_index}的摘要审阅修正来源或精确原值不匹配。')
            result['summary'] = correction['corrected']
            review_log.append({**correction,'status':'applied','review_kind':'source_based_editorial_correction','human_scientific_acceptance':False})
            continue
        if correction['section']=='gaps' and correction['field']=='text':
            matches = [index for index,item in enumerate(result.get('gaps',[])) if item in (correction['original'],correction['corrected'])]
            requested_index = correction.get('index')
            if type(requested_index) is int and requested_index in matches:
                matches = [requested_index]
            if len(matches)!=1:
                raise PipelineError(f'分块{chunk_index}的缺口审阅修正找不到唯一且原值一致的目标。')
            result['gaps'][matches[0]] = correction['corrected']
            review_log.append({**correction,'status':'applied','review_kind':'source_based_editorial_correction','human_scientific_acceptance':False})
            continue
        matches = []
        for item in result.get(correction['section'],[]):
            ids = [item.get('source_id')] if correction['section']=='paragraphs' else item.get('source_ids',[])
            if ids==correction['source_ids'] and (item.get(correction['field'])==correction['original'] or item.get(correction['field'])==correction['corrected']):
                matches.append(item)
        if len(matches)!=1:
            raise PipelineError(f'分块{chunk_index}的审阅修正找不到唯一且原值一致的目标，拒绝错位修改。')
        matches[0][correction['field']] = correction['corrected']
        review_log.append({**correction,'status':'applied','review_kind':'source_based_editorial_correction','human_scientific_acceptance':False})
    write_json(chunk_dir/f'chunk-{chunk_index:04d}-before-review.json',original)
    write_json(chunk_dir.parent/'learning-review.json',{'corrections':review_log,'notice':'保留修改前后文字及来源；审阅修正不代表研究者科学验收。'})
    return result


def apply_extraction_review(extraction,source,request,run_dir):
    """Apply independent, exact-match field review before any public artifact.

    The dataset review implementation validates types, units/status structure,
    quotes/pages and the existing audit chain.  This wrapper binds corrections
    to the exact PDF and initial cell so a later run cannot silently drift.
    """
    path = request.get('extraction_corrections_path')
    if not path:
        return extraction
    corrections = read_json(Path(path).expanduser())
    if not isinstance(corrections,list):
        raise PipelineError('字段审阅修正必须为数组。')
    applicable = []
    for item in corrections:
        if not isinstance(item,dict):
            raise PipelineError('字段审阅修正必须为对象。')
        if item.get('paper')!=Path(source['path']).stem:
            continue
        if item.get('source_sha256')!=source.get('sha256'):
            raise PipelineError('字段审阅修正与源文件哈希不一致，不能复用。')
        if item.get('operation')=='add_record':
            if (not isinstance(item.get('record'),dict) or
                    not all(isinstance(item.get(key),str) and item[key].strip() for key in ('reason','actor'))):
                raise PipelineError('追加审阅条件需要完整record、reason和actor。')
            applicable.append(item)
            continue
        if item.get('operation','replace_cell')!='replace_cell':
            raise PipelineError('未知字段审阅operation。')
        if not all(isinstance(item.get(key),str) and item[key].strip() for key in ('record_id','field','reason','actor')):
            raise PipelineError('字段审阅修正需要record_id/field/reason/actor。')
        if not all(isinstance(item.get(key),dict) for key in ('original','corrected')):
            raise PipelineError('字段审阅修正需要完整original和corrected单元格。')
        applicable.append(item)
    if not applicable:
        return extraction
    from .dataset import DatasetError, apply_corrections as apply_dataset_corrections, append_reviewed_record
    result = copy.deepcopy(extraction)
    review_log = []
    for item in applicable:
        if item.get('operation')=='add_record':
            matches = [record for record in result.get('records',[]) if record.get('id')==item['record'].get('id')]
            if matches and (len(matches)!=1 or matches[0]!=item['record']):
                raise PipelineError('追加审阅条件的record_id已被不同记录使用，拒绝覆盖。')
            status = 'already_applied' if matches else 'applied'
            if not matches:
                try:
                    result = append_reviewed_record(result,item['record'],item['actor'],item['reason'],source,
                        item.get('retain_original_record_id'),item.get('original_record_notice'))
                except DatasetError as error:
                    raise PipelineError(f'追加审阅条件未通过类型及逐字来源校验：{error}') from error
            review_log.append({**item,'status':status,'review_kind':'source_based_extraction_record_addition','human_scientific_acceptance':False})
            continue
        matches = [record for record in result.get('records',[]) if record.get('id')==item['record_id']]
        if len(matches)!=1 or matches[0].get('values',{}).get(item['field']) not in (item['original'],item['corrected']):
            raise PipelineError('字段审阅修正找不到唯一且原值一致的目标，拒绝错位修改。')
        current = matches[0]['values'][item['field']]
        status = 'already_applied' if current==item['corrected'] else 'applied'
        if status=='applied':
            try:
                result = apply_dataset_corrections(result,[{'record_id':item['record_id'],'field':item['field'],
                    'reason':item['reason'],'after':item['corrected']}],item['actor'],source)
            except DatasetError as error:
                raise PipelineError(f'字段审阅修正未通过类型及逐字来源校验：{error}') from error
        review_log.append({**item,'status':status,'review_kind':'source_based_extraction_correction','human_scientific_acceptance':False})
    result['review_provenance'] = {'kind':'source_based_extraction_correction','human_scientific_acceptance':False,
        'notice':'字段经独立来源核对修正；保留原值、操作者和证据，此记录不代表用户或研究者科学验收。'}
    result.setdefault('warnings',[]).append('部分字段或条件记录经独立来源核对修正；extraction-review.json及review_history保留前后值和操作者，不代表研究者科学验收。条件行数不能当作独立实验次数，未拆分摘要不得与条件行重复计数。')
    write_json(run_dir/'extraction-before-review.json',extraction)
    write_json(run_dir/'extraction-review.json',{'corrections':review_log,**result['review_provenance']})
    return result
