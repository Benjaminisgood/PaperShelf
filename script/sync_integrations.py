#!/usr/bin/env python3
"""Inspect or fast-forward one unmodified upstream; never merges app custom code."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "integrations/upstreams.lock.json"


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fetch and report upstream heads (default)")
    parser.add_argument("--update", choices=["Paper2Agent", "markitdown", "graphiti", "ppt-master"])
    parser.add_argument("--ref", help="Specific fetched ref or commit; defaults to origin/default branch")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    reports = []
    for name, pin in lock.items():
        if args.update and name != args.update:
            continue
        path = ROOT / pin["path"]
        if git(path, "rev-parse", "--show-toplevel") != str(path):
            raise RuntimeError(f"{name} is not an initialized Git submodule")
        if git(path, "status", "--porcelain"):
            raise RuntimeError(f"{name} has local modifications; preserve them before synchronizing")
        current = git(path, "rev-parse", "HEAD")
        if current != pin["commit"]:
            raise RuntimeError(f"{name} checkout differs from upstreams.lock.json; reconcile it first")
        if git(path, "remote", "get-url", "origin") != pin["url"]:
            raise RuntimeError(f"{name} origin differs from the recorded upstream")
        git(path, "fetch", "origin", "--tags")
        target = git(path, "rev-parse", "--verify", (args.ref or f"origin/{pin['branch']}") + "^{commit}")
        report = {"name": name, "current": current, "available": target, "changed": current != target}
        if args.update and current != target:
            subprocess.check_call(["git", "-C", str(path), "merge-base", "--is-ancestor", current, target])
            git(path, "checkout", "--detach", target)
            pin["commit"] = target
            temporary = LOCK.with_suffix(".tmp")
            temporary.write_text(json.dumps(lock, indent=2) + "\n")
            temporary.replace(LOCK)
            report["updated"] = True
        reports.append(report)
    print(json.dumps(reports, indent=2))
    if args.update:
        print("Reinstall script/setup_integrations.sh, run backend/Swift tests, inspect the git diff, then commit both the submodule pointer and lock file.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
