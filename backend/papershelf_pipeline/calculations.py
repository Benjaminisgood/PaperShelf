"""Small, auditable scientific calculations; model text is never evaluated as code."""
from __future__ import annotations

import ast
import math
import operator
import re

from .contracts import PipelineError, normalize_quote


OPERATORS = {'add':operator.add,'sub':operator.sub,'mul':operator.mul,'div':operator.truediv,'pow':operator.pow}
FUNCTIONS = {'exp':math.exp,'log':math.log,'log10':math.log10,'sqrt':math.sqrt,'sin':math.sin,'cos':math.cos,'tan':math.tan,'abs':abs}


def expression_tree(expression: str, variables: set[str]) -> dict:
    if not isinstance(expression,str) or len(expression)>1000:
        raise PipelineError('复算表达式必须是不超过 1000 字符的算式。')
    try:
        tree = ast.parse(expression,mode='eval')
    except SyntaxError as error:
        raise PipelineError('复算表达式不是有效算式。') from error
    def convert(node,depth=0):
        if depth>20:
            raise PipelineError('复算表达式过深。')
        if isinstance(node,ast.Constant) and type(node.value) in (int,float) and math.isfinite(node.value):
            return {'op':'number','value':node.value}
        if isinstance(node,ast.Name) and node.id in variables:
            return {'op':'variable','name':node.id}
        binary = {ast.Add:'add',ast.Sub:'sub',ast.Mult:'mul',ast.Div:'div',ast.Pow:'pow'}
        if isinstance(node,ast.BinOp) and type(node.op) in binary:
            return {'op':binary[type(node.op)],'left':convert(node.left,depth+1),'right':convert(node.right,depth+1)}
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.UAdd,ast.USub)):
            return {'op':'positive' if isinstance(node.op,ast.UAdd) else 'negative','value':convert(node.operand,depth+1)}
        if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in FUNCTIONS and len(node.args)==1 and not node.keywords:
            return {'op':'function','name':node.func.id,'value':convert(node.args[0],depth+1)}
        raise PipelineError('复算表达式包含未允许的符号、函数或代码。')
    return convert(tree.body)


def evaluate(tree: dict,variables: dict) -> float:
    op = tree['op']
    try:
        if op=='number':
            value = tree['value']
        elif op=='variable':
            value = variables[tree['name']]
        elif op in OPERATORS:
            left,right = evaluate(tree['left'],variables),evaluate(tree['right'],variables)
            if op=='pow' and abs(right)>100:
                raise PipelineError('指数绝对值不得超过 100。')
            value = OPERATORS[op](left,right)
        elif op in {'positive','negative'}:
            value = evaluate(tree['value'],variables)*(1 if op=='positive' else -1)
        elif op=='function':
            value = FUNCTIONS[tree['name']](evaluate(tree['value'],variables))
        else:
            raise PipelineError('复算运算无效。')
        if type(value) not in (int,float) or not math.isfinite(value):
            raise PipelineError('复算结果不是有限实数。')
        return float(value)
    except (OverflowError,ValueError,ZeroDivisionError,KeyError) as error:
        raise PipelineError('复算输入超出定义域、缺少变量或分母为零。') from error


def validate_calculation(item: dict,blocks: dict) -> dict:
    variables = item.get('variables',[])
    if not isinstance(variables,list) or not variables:
        raise PipelineError('数值复算需要有来源的变量。')
    values = {}
    for variable in variables:
        name,value = variable.get('name'),variable.get('value')
        if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*',name) or name in values:
            raise PipelineError('复算变量名必须唯一且为英文字母/数字/下划线。')
        if type(value) not in (int,float) or not math.isfinite(value):
            raise PipelineError('复算变量必须是有限数值。')
        evidence = variable.get('evidence',[])
        if not evidence:
            raise PipelineError('复算变量缺少原文数值证据。')
        numeric_match = False
        for citation in evidence:
            block = blocks.get(citation.get('block_id'))
            quote = citation.get('quote','')
            if not block or citation.get('page')!=block['page'] or not quote or normalize_quote(quote) not in normalize_quote(block['text']):
                raise PipelineError('复算变量引用与原文或页码不符。')
            numbers = re.findall(r'(?<![A-Za-z0-9])[-+]?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?',quote)
            numeric_match = numeric_match or any(math.isclose(float(number),value,rel_tol=1e-12,abs_tol=1e-12) for number in numbers)
        if not numeric_match:
            raise PipelineError('复算变量值没有逐字数值来源；请保留原始数值，换算写在表达式中。')
        for bound in ('min','max'):
            if bound in variable and (type(variable[bound]) not in (int,float) or not math.isfinite(variable[bound])):
                raise PipelineError('复算变量边界必须为有限数值。')
        values[name] = value
    tree = expression_tree(item.get('expression',''),set(values))
    def used_variables(node):
        found = {node['name']} if node.get('op')=='variable' else set()
        for child in node.values():
            if isinstance(child,dict):
                found.update(used_variables(child))
        return found
    if item.get('interactive',True):
        unused = set(values)-used_variables(tree)
        if unused:
            raise PipelineError('复算交互输入未用于算式：'+', '.join(sorted(unused))+'；expression必须引用变量名，不能用对应数值硬编码代替。')
    computed = evaluate(tree,values)
    item['expression_tree'] = tree
    item['computed_value'] = computed
    if item.get('reported_value') is not None:
        reported = item['reported_value']
        if type(reported) not in (int,float) or not math.isfinite(reported):
            raise PipelineError('待比较的论文数值必须是有限实数。')
        item['absolute_difference'] = computed-reported
        item['relative_difference'] = (computed-reported)/abs(reported) if reported else None
    return item


CALCULATOR_JS = r"""
(()=>{'use strict';function calc(node,values){let x;switch(node.op){case'number':x=node.value;break;case'variable':x=values[node.name];break;case'positive':x=calc(node.value,values);break;case'negative':x=-calc(node.value,values);break;case'function':{const f={exp:Math.exp,log:Math.log,log10:Math.log10,sqrt:Math.sqrt,sin:Math.sin,cos:Math.cos,tan:Math.tan,abs:Math.abs}[node.name];if(!f)throw Error();x=f(calc(node.value,values));break}default:{const a=calc(node.left,values),b=calc(node.right,values);switch(node.op){case'add':x=a+b;break;case'sub':x=a-b;break;case'mul':x=a*b;break;case'div':if(b===0)throw Error();x=a/b;break;case'pow':if(Math.abs(b)>100)throw Error();x=Math.pow(a,b);break;default:throw Error()}}}if(!Number.isFinite(x))throw Error();return x}
document.querySelectorAll('[data-calculator]').forEach(box=>{const tree=JSON.parse(box.querySelector('script[type="application/json"]').textContent);const output=box.querySelector('output');function update(){try{const values={};for(const input of box.querySelectorAll('input[data-variable]')){if(!input.value.trim())throw Error();const value=Number(input.value);if(!Number.isFinite(value)||(input.min!==''&&value<Number(input.min))||(input.max!==''&&value>Number(input.max)))throw Error();values[input.dataset.variable]=value}output.textContent=calc(tree,values).toPrecision(8)+' '+box.dataset.unit}catch(e){output.textContent='请输入有效数值；检查允许范围、分母和函数定义域。'}}box.querySelectorAll('input').forEach(input=>input.addEventListener('input',update));update()});})();
"""
