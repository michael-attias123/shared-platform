#!/usr/bin/env python3
"""The downstream check: runs every project's own CI and plan against a
shared-platform commit, before that commit reaches main (docs/contract.md).

Projects follow shared-platform at main, so a change here must not break them.
Each project that declares a receiver in projects/<name>.yaml

    downstream:
      workflow: platform-check.yml     # in the project's repo, on its default branch
      changed_event: platform-changed  # optional: sent after a merge that changes the project's plan

gets a workflow_dispatch of that workflow with the inputs platform_ref (the
commit to test) and report_to (the shared-platform PR number, empty after a
merge). The receiver names its run `Platform check <platform_ref>
(shared-platform#<report_to>)`, which is how the run is found. The run's
conclusion is the answer. Each plan's result is a notice on the run titled
`<stack> plan` that starts with `no changes`, `changes` or `not planned`.

  check   dispatch, wait for every run, write the PR comment, exit 1 when a
          project failed, timed out or can't be reached. A project whose
          receiver file doesn't exist yet is reported and doesn't block.
  notify  the same after a merge, then send changed_event (a
          repository_dispatch) to each project whose plan has changes.

A project's check runs this commit's tools with the project's own
credentials, so the caller must only pass commits of shared-platform's own
branches, never a fork's (downstream.yml refuses fork PRs).

Usage: downstream.py check|notify --ref SHA [--pr NUMBER] [--projects DIR]
                                  [--comment FILE] [--timeout SECONDS] [--poll SECONDS]
Env: GH_TOKEN (platform-bot's installation token: Actions write on the
projects' repos, Checks read for the plan notices, and Contents write for
changed_event), RUN_URL. Prints project names, results and run links only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from dataclasses import dataclass, field
from pathlib import Path

MARKER = "<!-- downstream-check -->"
BLOCKING = {"failed", "timeout", "unreachable", "error"}
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
WORKFLOW = re.compile(r"^[A-Za-z0-9_.-]+\.ya?ml$")
EVENT = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
PLAN_NOTICE = re.compile(r"^(?P<stack>.+) plan$")


@dataclass(frozen=True)
class Target:
    project: str
    repo: str
    workflow: str
    changed_event: str = ""


@dataclass
class Result:
    target: Target
    status: str = "error"  # passed, failed, timeout, no-receiver, unreachable, error
    detail: str = ""
    url: str = ""
    stacks: list[dict[str, str]] = field(default_factory=list)
    notified: bool = False

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
        event = str(down.get("changed_event") or "")
        if not REPO.match(repo) or not WORKFLOW.match(workflow):
            raise ValueError(f"{path.name}: downstream needs repo (owner/name) and workflow (a .yml file name)")
        if event and not EVENT.match(event):
            raise ValueError(f"{path.name}: downstream.changed_event must be an event name like platform-changed")
        targets.append(Target(path.stem, repo, workflow, event))
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


def clean(text: object, limit: int = 160) -> str:
    """Text from a project's run goes into a PR comment: plain words and counts only."""
    return re.sub(r"[^A-Za-z0-9 .,:;()+_/-]", "", str(text))[:limit].strip()


def read_stacks(annotations: object) -> list[dict[str, str]]:
    """The plan results among a job's annotations: notices titled `<stack> plan`."""
    out = []
    for a in annotations if isinstance(annotations, list) else []:
        if not isinstance(a, dict) or a.get("annotation_level") != "notice":
            continue
        found = PLAN_NOTICE.match(str(a.get("title") or ""))
        if not found:
            continue
        message = str(a.get("message") or "").strip()
        exitcode = ("0" if message.startswith("no changes") else "2" if message.startswith("changes")
                    else "skip" if message.startswith("not planned") else "?")
        out.append({"name": clean(found.group("stack"), 60) or "?", "exitcode": exitcode, "summary": clean(message)})
    return out


def run_title(ref: str, pr: str) -> str:
    return f"Platform check {ref}" + (f" (shared-platform#{pr})" if pr else "")


class Check:
    def __init__(self, gh: GitHub, ref: str, pr: str = "", timeout: float = 1800, poll: float = 15,
                 sleep=time.sleep, clock=time.monotonic, now=lambda: datetime.now(timezone.utc)):
        self.gh, self.ref, self.pr, self.poll, self.sleep, self.clock = gh, ref, pr, poll, sleep, clock
        # A run of an earlier attempt at the same commit has the same name: only newer runs count.
        self.since = (now() - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.deadline = clock() + timeout
        self.find_deadline = clock() + min(timeout, 180)

    def default_branch(self, repo: str) -> str | None:
        status, info = self.gh.call("GET", f"repos/{repo}")
        return str(info.get("default_branch", "main")) if status == 200 and isinstance(info, dict) else None

    def start(self, target: Target) -> Result:
        result = Result(target)
        branch = self.default_branch(target.repo)
        if branch is None:
            result.status, result.detail = "unreachable", "platform-bot can't see the repository (is it installed there?)"
            return result
        status, _ = self.gh.call("POST", f"repos/{target.repo}/actions/workflows/{target.workflow}/dispatches",
                                 {"ref": branch, "inputs": {"platform_ref": self.ref, "report_to": self.pr}})
        if status == 404:
            result.status, result.detail = "no-receiver", f"{target.workflow} is not on {branch} yet"
        elif status != 200:
            result.detail = f"the dispatch was refused (HTTP {status})"
        else:
            result.status = "pending"
        return result

    def find_run(self, target: Target) -> dict | None:
        path = f"repos/{target.repo}/actions/workflows/{target.workflow}/runs?event=workflow_dispatch&per_page=30"
        title = run_title(self.ref, self.pr)
        while True:
            status, data = self.gh.call("GET", path)
            if status == 200 and isinstance(data, dict):
                for run in data.get("workflow_runs") or []:  # newest first
                    if str(run.get("display_title", "")) == title and str(run.get("created_at", "")) >= self.since:
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
        status, data = self.gh.call("GET", f"repos/{target.repo}/actions/runs/{run_id}/jobs?per_page=100")
        if status != 200 or not isinstance(data, dict):
            return []
        out = []
        for job in data.get("jobs") or []:
            status, annotations = self.gh.call("GET", f"repos/{target.repo}/check-runs/{job.get('id')}/annotations")
            if status == 200:
                out += read_stacks(annotations)
        return out[:20]

    def run(self, targets: list[Target]) -> list[Result]:
        # Dispatch everything first: the projects run side by side.
        started = [self.start(t) for t in targets]
        results = []
        for result in started:
            results.append(result)
            if result.status != "pending":
                continue
            target = result.target
            run = self.find_run(target)
            if run is None:
                result.status = "error"
                result.detail = f"its run didn't appear (is its run-name '{run_title('<platform_ref>', '<report_to>')}'?)"
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

    def notify_changed(self, results: list[Result]) -> None:
        """After a merge: tell each project whose plan has changes, so it applies its main."""
        for r in results:
            if r.status == "passed" and r.changed and r.target.changed_event:
                status, _ = self.gh.call("POST", f"repos/{r.target.repo}/dispatches",
                                         {"event_type": r.target.changed_event})
                r.notified = status == 200
                if not r.notified:
                    r.status, r.detail = "error", f"sending {r.target.changed_event} was refused (HTTP {status})"


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
        if r.notified:
            plans += f"<br>sent `{r.target.changed_event}`"
        lines.append(f"| {r.target.project} | {label} | {plans} |")
    blocked = [r.target.project for r in results if r.status in BLOCKING]
    lines += ["", f"Blocked by: {', '.join(blocked)}." if blocked else "No project blocks this change."]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, gh: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("mode", choices=["check", "notify"])
    parser.add_argument("--ref", required=True, help="the shared-platform commit to test")
    parser.add_argument("--pr", default="", help="the shared-platform PR number (names the projects' runs)")
    parser.add_argument("--projects", default="projects")
    parser.add_argument("--comment", help="write the PR comment (markdown) to this file")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--poll", type=float, default=15)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", args.ref) or not re.fullmatch(r"[0-9]*", args.pr):
        print("::error::downstream: bad ref or PR number", file=sys.stderr)
        return 1
    try:
        targets = load_targets(args.projects)
    except (OSError, ValueError) as exc:
        print(f"::error::downstream: {exc}", file=sys.stderr)
        return 1
    check = Check(gh or GitHub(), args.ref, args.pr, args.timeout, args.poll)
    results = check.run(targets)
    if args.mode == "notify":
        check.notify_changed(results)
    for r in results:
        note = f" ({r.detail})" if r.detail else ""
        started = f"; sent {r.target.changed_event}" if r.notified else ""
        print(f"{r.target.project}: {r.status}{note}{started} {r.url}".rstrip())
        if r.status in BLOCKING:
            print(f"::error::downstream: {r.target.project}: {r.status}{note}")
    if args.comment:
        Path(args.comment).write_text(render(results, args.ref, os.environ.get("RUN_URL", "")), encoding="utf-8")
    return 1 if any(r.status in BLOCKING for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
