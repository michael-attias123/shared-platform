#!/usr/bin/env python3
"""Checks a saved OpenTofu plan before it is applied. Two optional rules:

  --allow PREFIX     every changed resource must be inside one of these module
                     addresses (e.g. module.observability). Repeatable. Without
                     it, any address is in scope.
  --protect TYPE     a resource of this type may not be deleted or replaced
                     (e.g. vault_mount). Repeatable. --allow-destroy lifts it
                     (the workflow passes it when the PR has the allow-destroy
                     label).

Usage:
  tofu show -json tfplan > plan.json
  plan_guard.py [--allow PREFIX]... [--protect TYPE]... [--allow-destroy] plan.json   # or - for stdin

Exits 0 when the plan may be applied (no changes counts), 1 when a rule is
broken or the plan cannot be read. Data source reads and no-ops write nothing
and are ignored. Prints resource addresses and actions only, never attribute
values.
"""
from __future__ import annotations

import argparse
import json
import sys

IGNORED_ACTIONS = ({"no-op"}, {"read"})


def in_scope(address: str, allowed: tuple[str, ...]) -> bool:
    if not allowed:
        return True
    return any(address == m or address.startswith((m + ".", m + "[")) for m in allowed)


def changes(plan: dict) -> list[tuple[str, str, str]]:
    """(address, type, action) for each resource the plan would write."""
    out = []
    for rc in plan.get("resource_changes") or []:
        actions = (rc.get("change") or {}).get("actions") or []
        if set(actions) in IGNORED_ACTIONS:
            continue
        out.append((str(rc.get("address", "?")), str(rc.get("type", "?")), "-".join(actions) or "?"))
    return out


def check(plan: object, allowed: tuple[str, ...] = (), protected: frozenset[str] = frozenset(),
          allow_destroy: bool = False) -> tuple[list[tuple[str, str, str]], list[str]]:
    """The changes, and the problems that forbid applying them."""
    if not isinstance(plan, dict) or "format_version" not in plan:
        return [], ["not the output of `tofu show -json <planfile>`"]
    problems = []
    if plan.get("errored"):
        problems.append("the plan errored")
    found = changes(plan)
    for address, rtype, action in found:
        if not in_scope(address, allowed):
            problems.append(f"{action} {address} is outside {' and '.join(allowed)}")
        if rtype in protected and "delete" in action and not allow_destroy:
            problems.append(f"{action} {address}: {rtype} is protected (add the allow-destroy label to the PR)")
    return found, problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("plan", help="plan JSON file, or - for stdin")
    parser.add_argument("--allow", action="append", default=[], metavar="PREFIX")
    parser.add_argument("--protect", action="append", default=[], metavar="TYPE")
    parser.add_argument("--allow-destroy", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.plan == "-":
            plan = json.load(sys.stdin)
        else:
            with open(args.plan, encoding="utf-8") as f:
                plan = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"plan_guard: cannot read the plan: {exc.__class__.__name__}", file=sys.stderr)
        return 1
    allowed = tuple(args.allow)
    found, problems = check(plan, allowed, frozenset(args.protect), args.allow_destroy)
    for address, _, action in found:
        print(f"  {action} {address}")
    if problems:
        for problem in problems:
            print(f"::error::plan_guard: {problem}")
        print("plan_guard: refused.")
        return 1
    scope = f", all inside {' and '.join(allowed)}" if allowed else ""
    print(f"plan_guard: {len(found)} change(s){scope}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
