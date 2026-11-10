"""downstream.py against a fake GitHub: dispatch, find the run, wait, read its report."""
import io
import json
import sys
import zipfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import downstream  # noqa: E402

REF = "a" * 40


def artifact(doc) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("result.json", doc if isinstance(doc, str) else json.dumps(doc))
    return buf.getvalue()


class FakeGitHub:
    """One repo per behaviour. Records every dispatch."""

    def __init__(self, conclusion="success", stacks=None, polls=1, title=True, missing=(), no_workflow=()):
        self.conclusion, self.polls, self.title = conclusion, polls, title
        self.report = {"stacks": stacks if stacks is not None else [{"name": "infra", "exitcode": "0", "summary": "No changes."}]}
        self.missing, self.no_workflow = set(missing), set(no_workflow)
        self.dispatched, self.request_ids, self.seen = [], {}, {}

    def call(self, method, path, body=None):
        parts = path.split("/")
        repo = "/".join(parts[1:3])
        if repo in self.missing:
            return 404, {}
        if len(parts) == 3:
            return 200, {"default_branch": "trunk"}
        if path.endswith("/dispatches"):
            workflow = parts[5]
            if (repo, workflow) in self.no_workflow:
                return 404, {}
            self.dispatched.append((repo, workflow, body))
            self.request_ids[repo] = body["inputs"].get("request_id", "")
            return 200, {}
        if "/workflows/" in path:
            title = f"platform-check {self.request_ids[repo]}" if self.title else "platform-check"
            return 200, {"workflow_runs": [{"id": 1, "display_title": "platform-check other", "status": "completed"},
                                           {"id": 7, "display_title": title, "status": "queued",
                                            "html_url": f"https://github.com/{repo}/actions/runs/7"}]}
        if path.endswith("/artifacts"):
            return 200, {"artifacts": [{"id": 3, "name": "platform-check", "expired": False}]}
        if "/runs/" in path:
            self.seen[repo] = self.seen.get(repo, 0) + 1
            if self.seen[repo] < self.polls:
                return 200, {"id": 7, "status": "in_progress"}
            return 200, {"id": 7, "status": "completed", "conclusion": self.conclusion}
        raise AssertionError(path)

    def download(self, path):
        return artifact(self.report)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


@pytest.fixture
def projects(tmp_path):
    (tmp_path / "_shared.yaml").write_text("downstream: {workflow: nope.yml}\n")
    (tmp_path / "plain.yaml").write_text("repo: o/plain\n")
    (tmp_path / "app.yaml").write_text(
        "repo: o/app\ndownstream:\n  workflow: platform-check.yml\n"
        "  apply:\n    workflow: infra.yml\n    inputs: {apply: \"true\"}\n")
    return tmp_path


def run(projects, gh, mode="check", **kw):
    clock = Clock()
    check = downstream.Check(gh, REF, kw.get("timeout", 600), 15, sleep=clock.sleep, clock=clock)
    results = check.run(downstream.load_targets(str(projects)))
    if mode == "notify":
        check.apply_changed(results)
    return results


def test_targets_are_the_projects_with_a_receiver(projects):
    assert downstream.load_targets(str(projects)) == [
        downstream.Target("app", "o/app", "platform-check.yml", "infra.yml", (("apply", "true"),))]


@pytest.mark.parametrize("text", [
    "repo: o/app\ndownstream: {workflow: ../x.yml}\n",
    "repo: not-a-repo\ndownstream: {workflow: x.yml}\n",
    "repo: o/app\ndownstream: {workflow: x.yml, apply: {workflow: 'a b.yml'}}\n",
    "repo: o/app\ndownstream: {workflow: x.yml, apply: {workflow: a.yml, inputs: {'a b': 1}}}\n",
])
def test_bad_declarations_are_refused(tmp_path, text):
    (tmp_path / "app.yaml").write_text(text)
    with pytest.raises(ValueError):
        downstream.load_targets(str(tmp_path))


def test_a_passing_project(projects):
    gh = FakeGitHub(polls=3)
    (r,) = run(projects, gh)
    assert (r.status, r.url) == ("passed", "https://github.com/o/app/actions/runs/7")
    assert r.stacks == [{"name": "infra", "exitcode": "0", "summary": "No changes."}]
    repo, workflow, body = gh.dispatched[0]
    assert (repo, workflow, body["ref"], body["inputs"]["platform_ref"]) == ("o/app", "platform-check.yml", "trunk", REF)
    assert len(body["inputs"]["request_id"]) == 16


def test_a_failing_project_blocks(projects, tmp_path, capsys):
    comment = tmp_path / "c.md"
    code = downstream.main(["check", "--ref", REF, "--projects", str(projects), "--comment", str(comment),
                            "--poll", "0"], gh=FakeGitHub(conclusion="failure"))
    assert code == 1
    assert "::error::downstream: app: failed" in capsys.readouterr().out
    text = comment.read_text()
    assert text.startswith(downstream.MARKER) and "| app | **failed**" in text and "Blocked by: app." in text


def test_a_missing_receiver_is_reported_and_does_not_block(projects, tmp_path):
    comment = tmp_path / "c.md"
    gh = FakeGitHub(no_workflow={("o/app", "platform-check.yml")})
    assert downstream.main(["check", "--ref", REF, "--projects", str(projects), "--comment", str(comment)], gh=gh) == 0
    assert "no receiver yet: platform-check.yml is not on trunk yet" in comment.read_text()


def test_an_unreachable_repo_blocks(projects):
    (r,) = run(projects, FakeGitHub(missing={"o/app"}))
    assert r.status == "unreachable" and r.status in downstream.BLOCKING


def test_a_run_that_never_appears_is_an_error(projects):
    (r,) = run(projects, FakeGitHub(title=False))
    assert r.status == "error" and "request_id" in r.detail


def test_a_run_that_never_finishes_times_out(projects):
    (r,) = run(projects, FakeGitHub(polls=10**6), timeout=120)
    assert r.status == "timeout"


def test_notify_starts_the_apply_of_changed_projects_only(projects):
    gh = FakeGitHub(stacks=[{"name": "infra", "exitcode": "2", "summary": "Plan: 1 to add, 0 to change, 0 to destroy."}])
    (r,) = run(projects, gh, mode="notify")
    assert r.applied and gh.dispatched[-1] == ("o/app", "infra.yml", {"ref": "trunk", "inputs": {"apply": "true"}})

    gh = FakeGitHub()
    (r,) = run(projects, gh, mode="notify")
    assert not r.applied and len(gh.dispatched) == 1


def test_check_never_starts_an_apply(projects):
    gh = FakeGitHub(stacks=[{"name": "infra", "exitcode": "2", "summary": "Plan: 1 to add."}])
    run(projects, gh)
    assert [d[1] for d in gh.dispatched] == ["platform-check.yml"]


@pytest.mark.parametrize("archive", [
    None, b"not a zip", artifact("not json"), artifact({"stacks": "x"}), artifact({"nothing": 1}),
    artifact({"stacks": [1]}), b"0" * (downstream.MAX_ARTIFACT + 1),
])
def test_a_malformed_report_counts_as_no_report(archive):
    assert downstream.read_stacks(archive) == []


def test_report_text_is_cleaned_for_the_comment():
    stacks = downstream.read_stacks(artifact({"stacks": [
        {"name": "infra`|<b>", "exitcode": "9", "summary": "Plan: 1 to add.\n@someone [x](http://evil) <img>" + "x" * 400}]}))
    assert stacks[0]["name"] == "infrab" and stacks[0]["exitcode"] == "?"
    assert not set("`|<>@[]\n") & set(stacks[0]["summary"]) and len(stacks[0]["summary"]) <= 160


def test_no_projects_passes(tmp_path):
    comment = tmp_path / "c.md"
    assert downstream.main(["check", "--ref", REF, "--projects", str(tmp_path), "--comment", str(comment)],
                           gh=FakeGitHub()) == 0
    assert "No project declares" in comment.read_text()


def test_the_real_declarations_load():
    repo_root = Path(__file__).resolve().parents[2]
    for t in downstream.load_targets(str(repo_root / "projects")):
        assert t.repo.startswith("michael-attias123/")
