"""CLI with one JSON response on stdout and progress on stderr."""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import sys

from .contracts import PipelineError, read_json


def main():
    parser = argparse.ArgumentParser(description='PaperShelf literature learning pipeline')
    subparsers = parser.add_subparsers(dest='command',required=True)
    run_parser = subparsers.add_parser('run',help='Generate a fresh, evidence-grounded learning package')
    run_parser.add_argument('--request',required=True)
    agent = subparsers.add_parser('agent',help='Search or ask a generated paper agent; optionally serve MCP')
    agent.add_argument('--manifest',required=True)
    agent.add_argument('--query')
    agent.add_argument('--mode',choices=['offline','llm'],default='offline')
    agent.add_argument('--limit',type=int,default=8)
    agent.add_argument('--stdio',action='store_true')
    agent.add_argument('--provider-config',help='Use current explicitly selected provider instead of the saved bundle provider')
    from .dataset import register_subcommands as register_dataset
    from .integrations import register_subcommands as register_integrations
    from .provider import register_subcommands as register_provider
    from .summary_review import register_subcommands as register_summary_review
    register_dataset(subparsers)
    register_integrations(subparsers)
    register_provider(subparsers)
    register_summary_review(subparsers)
    args = parser.parse_args()
    try:
        if args.command == 'agent' and args.stdio:
            from .agent import serve_stdio
            serve_stdio(args.manifest)
            return
        with contextlib.redirect_stdout(sys.stderr):
            if args.command == 'run':
                from .pipeline import run
                result = run(read_json(args.request))
            elif args.command == 'agent':
                if not args.query:
                    raise PipelineError('请提供 --query 或 --stdio。')
                from .agent import answer
                config = read_json(args.provider_config) if args.provider_config else None
                config = config.get('provider',config) if config is not None else None
                result = answer(args.manifest,args.query,args.mode,args.limit,config)
            else:
                result = args.func(args)
        print(json.dumps(result,ensure_ascii=False,allow_nan=False))
    except Exception as error:
        print(json.dumps({'status':'failed','error':str(error)},ensure_ascii=False))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
