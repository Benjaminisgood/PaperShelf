"""A minimal OpenAI-compatible client with environment-only credentials."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
import sys
import time

from .contracts import PipelineError


class Provider:
    def __init__(self, config: dict):
        self.config = dict(config)
        self.base_url = config.get("base_url") or config.get("endpoint") or os.environ.get("PAPERSHELF_BASE_URL", "")
        self.model = config.get("model") or os.environ.get("PAPERSHELF_MODEL", "")
        if not self.base_url or not self.model:
            raise PipelineError("LLM 模式需要 provider.base_url 和 provider.model；离线资料包请选 offline。")
        parsed = urllib.parse.urlparse(self.base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            raise PipelineError("模型服务地址必须是没有内嵌凭据的 http(s) URL。")
        self.key_env = config.get("api_key_env") or config.get("api_key_environment") or "PAPERSHELF_API_KEY"
        self.key = os.environ.get(self.key_env, "")
        self.timeout = float(config.get("timeout", 180))
        self.calls = 0
        self.usage = {}
        self.extra_body = config.get('extra_body',{})
        if not isinstance(self.extra_body,dict) or any(key in self.extra_body for key in ('messages','model','stream','api_key','authorization','Authorization')):
            raise PipelineError('provider.extra_body 必须是对象，且不能覆盖 messages/model/stream 或凭据。')

    def complete(self, system: str, user: str, json_mode: bool = False) -> str:
        streaming = bool(self.config.get('stream',False))
        body = {"model": self.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}], "stream": streaming}
        if self.config.get('temperature') is not None:
            body['temperature'] = float(self.config['temperature'])
        if json_mode and self.config.get("json_mode", True):
            body["response_format"] = {"type": "json_object"}
        if self.config.get("max_tokens"):
            body["max_tokens"] = int(self.config["max_tokens"])
        body.update(self.extra_body)
        endpoint = self.base_url.rstrip("/")
        if not endpoint.endswith("/chat/completions"):
            endpoint += "/chat/completions"
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = f"Bearer {self.key}"
        request = urllib.request.Request(endpoint, data=json.dumps(body, ensure_ascii=False).encode(), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                if streaming:
                    pieces,finish,usage = [],None,{}
                    last_notice = time.monotonic()
                    for raw in response:
                        line = raw.decode('utf-8').strip()
                        if not line.startswith('data:'):
                            continue
                        data = line[5:].strip()
                        if data=='[DONE]':
                            break
                        try:
                            event = json.loads(data)
                        except json.JSONDecodeError as error:
                            raise PipelineError('模型服务返回了无效的流式 JSON 事件。') from error
                        if event.get('error'):
                            raise PipelineError('模型服务报告了流式生成错误；请检查服务状态。')
                        usage.update(event.get('usage') or {})
                        for choice in event.get('choices',[]):
                            delta = choice.get('delta',{}).get('content')
                            if isinstance(delta,str):
                                pieces.append(delta)
                            finish = choice.get('finish_reason') or finish
                        if time.monotonic()-last_notice>20:
                            print(f'模型流式生成中：已接收 {sum(map(len,pieces))} 字符',file=sys.stderr,flush=True)
                            last_notice=time.monotonic()
                    result = {'choices':[{'message':{'content':''.join(pieces)},'finish_reason':finish}],'usage':usage}
                else:
                    result = json.load(response)
        except urllib.error.HTTPError as error:
            # Do not repeat server bodies: providers can echo submitted keys.
            raise PipelineError(f"模型服务 HTTP {error.code}；请检查地址、模型和环境变量 {self.key_env}。") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise PipelineError(f"无法连接模型服务（{type(error).__name__}）；请检查服务可达性。") from error
        self.calls += 1
        for key, count in result.get("usage", {}).items():
            if isinstance(count, int):
                self.usage[key] = self.usage.get(key, 0) + count
        try:
            choice = result["choices"][0]
            if choice.get("finish_reason") == "length":
                raise PipelineError("模型输出达到长度上限；请提高 max_tokens 或减小 chunk_characters 后重新生成。")
            content = choice["message"]["content"]
            if not isinstance(content, str) or not content.strip():
                raise KeyError("content")
            return content
        except (KeyError, IndexError, TypeError) as error:
            raise PipelineError("模型服务没有返回有效 message.content。") from error

    def json(self, system: str, user: str) -> dict:
        # Some compatible endpoints reject json_object unless a message explicitly
        # requests JSON, even when a structured example is already present.
        system = system + '\nRespond with one valid JSON object.'
        text = self.complete(system, user, json_mode=True).strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
        try:
            value = json.loads(text)
        except json.JSONDecodeError as error:
            raise PipelineError("模型返回了无效 JSON；保留已处理分块，可在运行记录检查失败位置。") from error
        if not isinstance(value, dict):
            raise PipelineError("模型返回值必须是 JSON 对象。")
        return value


def models(config: dict) -> dict:
    """Explicit read-only catalog request; no automatic provider discovery."""
    base_url = config.get('base_url') or config.get('endpoint') or os.environ.get('PAPERSHELF_BASE_URL','')
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme not in {'http','https'} or not parsed.hostname or parsed.username or parsed.password:
        raise PipelineError('请提供没有内嵌凭据的 http(s) base_url。')
    key_env = config.get('api_key_env') or config.get('api_key_environment') or 'PAPERSHELF_API_KEY'
    endpoint = base_url.rstrip('/')
    if endpoint.endswith('/chat/completions'):
        endpoint = endpoint[:-len('/chat/completions')]
    headers = {'Accept':'application/json'}
    key = os.environ.get(key_env,'')
    if key:
        headers['Authorization'] = 'Bearer '+key
    request = urllib.request.Request(endpoint+'/models',headers=headers)
    try:
        with urllib.request.urlopen(request,timeout=float(config.get('timeout',30))) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise PipelineError(f'模型目录 HTTP {error.code}；部分服务不实现 /models，可手动配置模型并使用 provider-probe。') from error
    except (urllib.error.URLError,TimeoutError,OSError) as error:
        raise PipelineError(f'无法读取模型目录（{type(error).__name__}）。') from error
    data = payload.get('data',[])
    if not isinstance(data,list):
        raise PipelineError('模型目录没有返回 data 数组。')
    return {'status':'completed','base_url':base_url,'models':[{'id':item['id'],'owned_by':item.get('owned_by')} for item in data if isinstance(item,dict) and isinstance(item.get('id'),str)]}


def probe(config: dict) -> dict:
    provider = Provider(config)
    result = provider.json('This is a connection test. Return only the requested JSON.', 'Return {"ok": true}.')
    if result.get('ok') is not True:
        raise PipelineError('服务可连接，但没有按要求返回有效 JSON；请检查模型的 JSON 输出能力。')
    return {'status':'completed','model':provider.model,'base_url':provider.base_url,'json_response_verified':True,'provider_usage':provider.usage,'message':'模型服务与 JSON 输出已验证；未发送任何文献。'}


def register_subcommands(subparsers):
    from .contracts import read_json
    for name,operation in [('provider-models',models),('provider-probe',probe)]:
        parser = subparsers.add_parser(name,help='Read configured model catalog' if name.endswith('models') else 'Verify provider connection and JSON response without sending a document')
        parser.add_argument('--config',required=True)
        def dispatch(args,operation=operation):
            config = read_json(args.config)
            return operation(config.get('provider',config))
        parser.set_defaults(func=dispatch)
