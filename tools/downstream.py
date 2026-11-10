#!/usr/bin/env python3
"""The downstream check: runs every project's own CI and plan against a
shared-platform commit, before that commit reaches main (docs/contract.md).

Projects follow shared-platform at main, so a change here must not break them.
Each project that declares a receiver in projects/<name>.yaml

    downstream:
      workflow: platform-check.yml          # in the project's repo, on its default branch
      apply:                                # optional: what to start after a merge that changes its plan
        workflow: infra.yml
        inputs: { apply: "true" }

gets a workflow_dispatch of that workflow with the inputs platform_ref (the
commit to test) and request_id. The receiver puts request_id in its run-name
(that is how its run is found) and may upload an artifact `platform-check`
holding result.json: {"stacks": [{"name": ..., "exitcode": "0"|"2"|"skip", "summary": ...}]}.

  check   dispatch, wait for every run, write the PR comment, exit 1 when a
          project failed, timed out or can't be reached. A project whose
          receiver file doesn't exist yet is reported and doesn't block.
  notify  the same after a merge, then start the `apply` workflow of each
          project whose plan has changes.

Usage: downstream.py check|notify --ref SHA [--projects DIR] [--comment FILE]
                                  [--timeout SECONDS] [--poll SECONDS]
Env: GH_TOKEN (platform-bot's installation token: actions write on the
projects' repos), RUN_URL. Prints project names, results and run links only.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

MARKER = "<!-- downstream-check -->"
BLOCKING = {"failed", "timeout", "unreachable", "error"}
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
WORKFLOW = re.compile(r"^[A-Za-z0-9_.-]+\.ya?ml$")
INPUT_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
MAX_ARTIFACT = 1_000_000


@dataclass(frozen=True)
class Target:
    project: str
    repo: str
    workflow: str
    apply_workflow: str = ""
    apply_inputs: tuple[tuple[str, str], ...] = ()


@dataclass
class Result:
    target: Target
    status: str = "error"  # passed, failed, timeout, no-receiver, unreachable, error
    detail: str = ""
    url: str = ""
    stacks: list[dict[str, str]] = field(default_factory=list)
    applied: bool = False

    @property
    def changed(self) -> bool:
        return any(s["exitcode"] == "2" for s in self.stacks)


def load_targets(projects_dir: str) -> list[Target]:
    """Every project with a downstream.workflow. Files starting with _ are not projects."""
    import yaml  # PyYAML; only this function needs it

    targets = []
    for path in sorted(Path(projects_dir).glob("*.yaml")):
        if path.name.startswith("_"):
            continue
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        down = doc.get("downstream")
        if not down:
            continue
        repo, workflow = str(doc.get("repo", "")), str(down.get("workflow", ""))
        apply = down.get("apply") or {}
        apply_workflow = str(apply.get("workflow", ""))
        inputs = apply.get("inputs") or {}
        if not REPO.match(repo) or not WORKFLOW.match(workflow):
            raise ValueError(f"{path.name}: downstream needs repo (owner/name) and workflow (a .yml file name)")
        if apply_workflow and not WORKFLOW.match(apply_workflow):
            raise ValueError(f"{path.name}: downstream.apply.workflow must be a .yml file name")
        if not isinstance(inputs, dict) or not all(INPUT_NAME.match(str(k)) for k in inputs):
            raise ValueError(f"{path.name}: downstream.apply.inputs must be a map of input names to values")
        targets.append(Target(path.stem, repo, workflow, apply_workflow,
                              tuple((str(k), str(v)) for k, v in inputs.items())))
    return targets


class GitHub:
    """The GitHub REST API through `gh api` (GH_TOKEN from the environment)."""

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        args = ["gh", "api", "-X", method, path]
        if body is not None:
            args += ["--input", "-"]
        proc = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                              capture_output=True, text=True, check=False)
        if proc.returncode == 0:
            return 200, json.loads(proc.stdout) if proc.stdout.strip() else {}
        found = re.search(r"\(HTTP (\d{3})\)", proc.stderr)
        return int(found.group(1)) if found else 0, {}

    def download(self, path: str) -> bytes | None:
        proc = subprocess.run(["gh", "api", path], capture_output=True, check=False)
        return proc.stdout if proc.returncode == 0 else None


def clean(text: object, limit: int = 160) -> str:
    """Text from a project's run goes into a PR comment: plain words and counts only."""
    return re.sub(r"[^A-Za-z0-9 .,:;()+_/-]", "", str(text))[:limit].strip()


def read_stacks(archive: bytes | None) -> list[dict[str, str]]:
    """The stacks in a platform-check artifact; anything malformed counts as no report."""
    if not archive or len(archive) > MAX_ARTIFACT:
        return []
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            info = z.getinfo("result.json")
            if info.file_size > MAX_ARTIFACT:
                return []
            doc = json.loads(z.read(info))
        out = []
        for s in doc["stacks"][:20]:
            exitcode = str(s.get("exitcode", ""))
            out.append({"name": clean(s.get("name", "?"), 60) or "?",
                        "exitcode": exitcode if exitcode in ("0", "2", "skip") else "?",
                        "summary": clean(s.get("summary", ""))})
        return out
    except (KeyError, TypeError, ValueError, AttributeError, zipfile.BadZipFile):
        return []


class Check:
    def __init__(self, gh: GitHub, ref: str, timeout: float = 1800, poll: float = 15,
                 sleep=time.sleep, clock=time.monotonic):
        self.gh, self.ref, self.poll, self.sleep, self.clock = gh, ref, poll, sleep, clock
        self.deadline = clock() + timeout
        self.find_deadline = clock() + min(timeout, 180)

    def dispatch(self, repo: str, workflow: str, inputs: dict[str, str]) -> tuple[int, str]:
        """Starts a workflow on the repo's default branch. (HTTP status, default branch)."""
        status, info = self.gh.call("GET", f"repos/{repo}")
        if status != 200 or not isinstance(info, dict):
            return -1, ""
        branch = str(info.get("default_branch", "main"))
        status, _ = self.gh.call("POST", f"repos/{repo}/actions/workflows/{workflow}/dispatches",
                                 {"ref": branch, "inputs": inputs})
        return status, branch

    def start(self, target: Target) -> tuple[Result, str]:
        result, request_id = Result(target), uuid.uuid4().hex[:16]
        status, branch = self.dispatch(target.repo, target.workflow,
                                       {"platform_ref": self.ref, "request_id": request_id})
        if status == -1:
            result.status, result.detail = "unreachable", "platform-bot can't see the repository (is it installed there?)"
        elif status == 404:
            result.status, result.detail = "no-receiver", f"{target.workflow} is not on {branch} yet"
        elif status != 200:
            result.detail = f"the dispatch was refused (HTTP {status})"
        else:
            result.status = "pending"
        return result, request_id

    def find_run(self, target: Target, request_id: str) -> dict | None:
        path = f"repos/{target.repo}/actions/workflows/{target.workflow}/runs?event=workflow_dispatch&per_page=30"
        while True:
            status, data = self.gh.call("GET", path)
            if status == 200 and isinstance(data, dict):
                for run in data.get("workflow_runs") or []:
                    if request_id in str(run.get("display_title", "")) or request_id in str(run.get("name", "")):
                        return run
            if self.clock() >= self.find_deadline:
                return None
            self.sleep(self.poll)

    def wait(self, target: Target, run: dict) -> dict | None:
        while run.get("status") != "completed":
            if self.clock() >= self.deadline:
                return None
            self.sleep(self.poll)
            status, data = self.gh.call("GET", f"repos/{target.repo}/actions/runs/{run['id']}")
            if status == 200 and isinstance(data, dict):
                run = data
        return run

    def stacks(self, target: Target, run_id: object) -> list[dict[str, str]]:
        status, data = self.gh.call("GET", f"repos/{target.repo}/actions/runs/{run_id}/artifacts")
        if status != 200 or not isinstance(data, dict):
            return []
        for artifact in data.get("artifacts") or []:
            if artifact.get("name") == "platform-check" and not artifact.get("expired"):
                return read_stacks(self.gh.download(f"repos/{target.repo}/actions/artifacts/{artifact['id']}/zip"))
        return []

    def run(self, targets: list[Target]) -> list[Result]:
        # Dispatch everything first: the projects run side by side.
        started = [self.start(t) for t in targets]
        results = []
        for result, request_id in started:
            results.append(result)
            if result.status != "pending":
                continue
            target = result.target
            run = self.find_run(target, request_id)
            if run is None:
                result.status = "error"
                result.detail = "its run didn't appear (does the receiver put request_id in run-name?)"
                continue
            result.url = str(run.get("html_url", ""))
            done = self.wait(target, run)
            if done is None:
                result.status, result.detail = "timeout", "its run didn't finish in time"
                continue
            result.status = "passed" if done.get("conclusion") == "success" else "failed"
            result.detail = "" if result.status == "passed" else f"its run ended as {clean(done.get('conclusion'), 20)}"
            result.stacks = self.stacks(target, done["id"])
        return results

    def apply_changed(self, results: list[Result]) -> None:
        """After a merge: start the apply workflow of each project whose plan has changes."""
        for r in results:
            if r.status == "passed" and r.changed and r.target.apply_workflow:
                status, _ = self.dispatch(r.target.repo, r.target.apply_workflow, dict(r.target.apply_inputs))
                r.applied = status == 200
                if not r.applied:
                    r.status, r.detail = "error", f"starting {r.target.apply_workflow} was refused (HTTP {status})"


LABELS = {"passed": "passed", "failed": "**failed**", "timeout": "**timed out**", "unreachable": "**unreachable**",
          "error": "**error**", "no-receiver": "no receiver yet"}


def render(results: list[Result], ref: str, run_url: str) -> str:
    lines = [MARKER, "### Downstream check: each project against this change", "",
             f"Commit {ref[:7]}" + (f" · [run log]({run_url})" if run_url else ""), ""]
    if not results:
        return "\n".join(lines + ["No project declares a `downstream` receiver.", ""])
    lines += ["| Project | Result | Its plans |", "|---|---|---|"]
    for r in results:
        label = LABELS.get(r.status, r.status)
        if r.url:
            label += f" ([run]({r.url}))"
        if r.detail:
            label += f": {r.detail}"
        plans = "<br>".join(f"`{s['name']}`: {s['summary'] or 'exit code ' + s['exitcode']}" for s in r.stacks)
        if r.applied:
            plans += f"<br>started `{r.target.apply_workflow}`"
        lines.append(f"| {r.target.project} | {label} | {plans} |")
    blocked = [r.target.project for r in results if r.status in BLOCKING]
    lines += ["", f"Blocked by: {', '.join(blocked)}." if blocked else "No project blocks this change."]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, gh: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("mode", choices=["check", "notify"])
    parser.add_argument("--ref", required=True, help="the shared-platform commit to test")
    parser.add_argument("--projects", default="projects")
    parser.add_argument("--comment", help="write the PR comment (markdown) to this file")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--poll", type=float, default=15)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", args.ref):
        print("::error::downstream: bad ref", file=sys.stderr)
        return 1
    try:
        targets = load_targets(args.projects)
    except (OSError, ValueError) as exc:
        print(f"::error::downstream: {exc}", file=sys.stderr)
        return 1
    check = Check(gh or GitHub(), args.ref, args.timeout, args.poll)
    results = check.run(targets)
    if args.mode == "notify":
        check.apply_changed(results)
    for r in results:
        note = f" ({r.detail})" if r.detail else ""
        started = f"; started {r.target.apply_workflow}" if r.applied else ""
        print(f"{r.target.project}: {r.status}{note}{started} {r.url}".rstrip())
        if r.status in BLOCKING:
            print(f"::error::downstream: {r.target.project}: {r.status}{note}")
    if args.comment:
        Path(args.comment).write_text(render(results, args.ref, os.environ.get("RUN_URL", "")), encoding="utf-8")
    return 1 if any(r.status in BLOCKING for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
