#!/usr/bin/env python3
"""Which CI areas a push touches, as GitHub Actions outputs (area=true|false).

The areas are each repo's own, in a TOML file (default .platform/changes.toml):

    # A changed file under any of these runs every area.
    all = [".github/workflows/ci.yml", ".platform/"]

    [areas]
    web = ["web/"]
    database = ["supabase/migrations/", "ingest/"]

A branch is compared with where it left main (merge-base), so every push of
a branch tests everything the branch changes, not only its last commit. main
is compared with the previous main (the push's `before`). Anything unsure (a
manual run, a pull_request event, a new or rewritten main, a failed git
command) runs everything.

Usage: changes.py [--config FILE] [--main REF]   (prints area=true|false lines)
       env: GITHUB_EVENT_NAME, GITHUB_REF_NAME, BEFORE (github.event.before)
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Config:
    areas: dict[str, tuple[str, ...]]
    all: tuple[str, ...] = field(default=())


def load(path: str) -> Config:
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    areas = doc.get("areas")
    if not isinstance(areas, dict) or not areas:
        raise ValueError(f"{path}: [areas] must list at least one area")
    out: dict[str, tuple[str, ...]] = {}
    for name, prefixes in areas.items():
        if not isinstance(prefixes, list) or not all(isinstance(p, str) and p for p in prefixes):
            raise ValueError(f"{path}: areas.{name} must be a list of path prefixes")
        out[name] = tuple(prefixes)
    every = doc.get("all", [])
    if not isinstance(every, list) or not all(isinstance(p, str) and p for p in every):
        raise ValueError(f"{path}: all must be a list of path prefixes")
    return Config(out, tuple(every))


def areas_for(config: Config, files: list[str] | None) -> dict[str, bool]:
    """None means unknown: every area runs."""
    if files is None or (config.all and any(f.startswith(config.all) for f in files)):
        return {a: True for a in config.areas}
    return {a: any(f.startswith(prefixes) for f in files) for a, prefixes in config.areas.items()}


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def changed_files(event: str, branch: str, before: str, main: str = "origin/main") -> list[str] | None:
    try:
        if event != "push":
            return None
        if branch == main.removeprefix("origin/"):
            if not before or set(before) == {"0"}:
                return None
            _git("cat-file", "-e", f"{before}^{{commit}}")
            base = before
        else:
            base = _git("merge-base", main, "HEAD")
        return [f for f in _git("diff", "--name-only", base, "HEAD").splitlines() if f]
    except (subprocess.CalledProcessError, OSError):
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--config", default=".platform/changes.toml")
    parser.add_argument("--main", default="origin/main", help="the ref a branch is compared with")
    args = parser.parse_args(argv)
    try:
        config = load(args.config)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"::error::changes: {exc}", file=sys.stderr)
        return 1
    files = changed_files(os.environ.get("GITHUB_EVENT_NAME", ""), os.environ.get("GITHUB_REF_NAME", ""),
                          os.environ.get("BEFORE", ""), args.main)
    print(f"changed files: {'unknown, running everything' if files is None else len(files)}", file=sys.stderr)
    for area, run in areas_for(config, files).items():
        print(f"{area}={'true' if run else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
