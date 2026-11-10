"""downstream.py against a fake GitHub: dispatch, find the run by its name, wait, read the plan notices."""
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import downstream  # noqa: E402

REF = "a" * 40
NOW = datetime(2026, 11, 10, 12, 0, 0, tzinfo=timezone.utc)
NEW, OLD = "2026-11-10T12:00:05Z", "2026-11-10T11:00:00Z"


class FakeGitHub:
    """One project repo. Records every POST."""

    def __init__(self, conclusion="success", notice="no changes", polls=1, title=None, created=NEW,
                 missing=False, no_workflow=False, refuse_event=False):
        self.conclusion, self.notice, self.polls, self.title, self.created = conclusion, notice, polls, title, created
        self.missing, self.no_workflow, self.refuse_event = missing, no_workflow, refuse_event
        self.posts, self.seen = [], 0

    def call(self, method, path, body=None):
        parts = path.split("/")
        if self.missing:
            return 404, {}
        if len(parts) == 3:
            return 200, {"default_branch": "trunk"}
        if method == "POST":
            if path.endswith("/actions/workflows/platform-check.yml/dispatches") and self.no_workflow:
                return 404, {}
            if path.endswith("/dispatches") and "/actions/" not in path and self.refuse_event:
                return 403, {}
            self.posts.append((path, body))
            return 200, {}
        if "/workflows/" in path:
            inputs = self.posts[0][1]["inputs"]
            title = self.title or downstream.run_title(inputs["platform_ref"], inputs["report_to"])
            return 200, {"workflow_runs": [
                {"id": 7, "display_title": title, "status": "queued", "created_at": self.created,
                 "html_url": "https://github.com/o/app/actions/runs/7"},
                {"id": 1, "display_title": title, "status": "completed", "conclusion": "failure", "created_at": OLD}]}
        if path.endswith("/jobs?per_page=100"):
            return 200, {"jobs": [{"id": 70}, {"id": 71}]}
        if path.endswith("/check-runs/70/annotations"):
            return 200, [{"annotation_level": "warning", "title": "infra plan", "message": "changes"},
                         {"annotation_level": "notice", "title": "Something else", "message": "changes"}]
        if path.endswith("/check-runs/71/annotations"):
            return 200, ([{"annotation_level": "notice", "title": "infra plan", "message": self.notice}]
                         if self.notice else [])
        if "/runs/" in path:
            self.seen += 1
            if self.seen < self.polls:
                return 200, {"id": 7, "status": "in_progress"}
            return 200, {"id": 7, "status": "completed", "conclusion": self.conclusion}
        raise AssertionError(path)


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
        "repo: o/app\ndownstream:\n  workflow: platform-check.yml\n  changed_event: platform-changed\n")
    return tmp_path


def run(projects, gh, mode="check", pr="12", timeout=600):
    clock = Clock()
    check = downstream.Check(gh, REF, pr, timeout, 15, sleep=clock.sleep, clock=clock, now=lambda: NOW)
    results = check.run(downstream.load_targets(str(projects)))
    if mode == "notify":
        check.notify_changed(results)
    return results


def test_targets_are_the_projects_with_a_receiver(projects):
    assert downstream.load_targets(str(projects)) == [
        downstream.Target("app", "o/app", "platform-check.yml", "platform-changed")]


@pytest.mark.parametrize("text", [
    "repo: o/app\ndownstream: {workflow: ../x.yml}\n",
    "repo: not-a-repo\ndownstream: {workflow: x.yml}\n",
    "repo: o/app\ndownstream: {workflow: x.yml, changed_event: 'a b'}\n",
])
def test_bad_declarations_are_refused(tmp_path, text):
    (tmp_path / "app.yaml").write_text(text)
    with pytest.raises(ValueError):
        downstream.load_targets(str(tmp_path))


def test_run_title_is_the_receivers_run_name():
    assert downstream.run_title("my-branch", "12") == "Platform check my-branch (shared-platform#12)"
    assert downstream.run_title("main", "") == "Platform check main"


def test_a_passing_project(projects):
    gh = FakeGitHub(polls=3)
    (r,) = run(projects, gh)
    assert (r.status, r.url) == ("passed", "https://github.com/o/app/actions/runs/7")
    assert r.stacks == [{"name": "infra", "exitcode": "0", "summary": "no changes"}]
    assert gh.posts == [("repos/o/app/actions/workflows/platform-check.yml/dispatches",
                         {"ref": "trunk", "inputs": {"platform_ref": REF, "report_to": "12"}})]


def test_an_older_run_with_the_same_name_is_not_taken(projects):
    (r,) = run(projects, FakeGitHub(created=OLD))
    assert r.status == "error" and "its run didn't appear" in r.detail


def test_a_failing_project_blocks(projects, tmp_path, capsys):
    comment = tmp_path / "c.md"
    code = downstream.main(["check", "--ref", REF, "--pr", "12", "--projects", str(projects), "--comment", str(comment),
                            "--poll", "0"], gh=FakeGitHub(conclusion="failure", created="9999-01-01T00:00:00Z"))
    assert code == 1
    assert "::error::downstream: app: failed" in capsys.readouterr().out
    text = comment.read_text()
    assert text.startswith(downstream.MARKER) and "| app | **failed**" in text and "Blocked by: app." in text


def test_a_missing_receiver_is_reported_and_does_not_block(projects, tmp_path):
    comment = tmp_path / "c.md"
    gh = FakeGitHub(no_workflow=True)
    assert downstream.main(["check", "--ref", REF, "--projects", str(projects), "--comment", str(comment)], gh=gh) == 0
    assert "no receiver yet: platform-check.yml is not on trunk yet" in comment.read_text()


def test_an_unreachable_repo_blocks(projects):
    (r,) = run(projects, FakeGitHub(missing=True))
    assert r.status == "unreachable" and r.status in downstream.BLOCKING


def test_a_run_with_another_name_is_an_error(projects):
    (r,) = run(projects, FakeGitHub(title="Platform check"))
    assert r.status == "error"


def test_a_run_that_never_finishes_times_out(projects):
    (r,) = run(projects, FakeGitHub(polls=10**6), timeout=120)
    assert r.status == "timeout"


@pytest.mark.parametrize("notice, exitcode", [
    ("no changes", "0"), ("changes (see the plan job's log)", "2"),
    ("not planned: a provider was down", "skip"), ("unknown (9)", "?"),
])
def test_plan_notices(projects, notice, exitcode):
    (r,) = run(projects, FakeGitHub(notice=notice))
    assert [s["exitcode"] for s in r.stacks] == [exitcode] and r.changed == (exitcode == "2")


def test_no_plan_notice_is_fine(projects):
    (r,) = run(projects, FakeGitHub(notice=""))
    assert r.status == "passed" and r.stacks == []


def test_notify_tells_changed_projects_only(projects):
    gh = FakeGitHub(notice="changes")
    (r,) = run(projects, gh, mode="notify", pr="")
    assert r.notified and gh.posts[-1] == ("repos/o/app/dispatches", {"event_type": "platform-changed"})
    assert gh.posts[0][1]["inputs"]["report_to"] == ""

    gh = FakeGitHub()
    (r,) = run(projects, gh, mode="notify", pr="")
    assert not r.notified and len(gh.posts) == 1


def test_a_refused_event_is_an_error(projects):
    (r,) = run(projects, FakeGitHub(notice="changes", refuse_event=True), mode="notify", pr="")
    assert r.status == "error" and "platform-changed was refused (HTTP 403)" in r.detail


def test_check_never_sends_the_event(projects):
    gh = FakeGitHub(notice="changes")
    run(projects, gh)
    assert len(gh.posts) == 1


def test_notice_text_is_cleaned_for_the_comment():
    stacks = downstream.read_stacks([{"annotation_level": "notice", "title": "infra`|<b> plan",
                                      "message": "changes\n@someone [x](http://evil) <img>" + "x" * 400}])
    assert stacks[0]["name"] == "infrab" and stacks[0]["exitcode"] == "2"
    assert not set("`|<>@[]\n") & set(stacks[0]["summary"]) and len(stacks[0]["summary"]) <= 160
    assert downstream.read_stacks({"not": "a list"}) == [] and downstream.read_stacks([1, None]) == []


@pytest.mark.parametrize("argv", [["check", "--ref", "a b"], ["check", "--ref", REF, "--pr", "12; rm"]])
def test_bad_arguments(argv, projects):
    assert downstream.main(argv + ["--projects", str(projects)], gh=FakeGitHub()) == 1


def test_no_projects_passes(tmp_path):
    comment = tmp_path / "c.md"
    assert downstream.main(["check", "--ref", REF, "--projects", str(tmp_path), "--comment", str(comment)],
                           gh=FakeGitHub()) == 0
    assert "No project declares" in comment.read_text()


def test_the_real_declarations_load():
    repo_root = Path(__file__).resolve().parents[2]
    targets = downstream.load_targets(str(repo_root / "projects"))
    assert {t.project for t in targets} >= {"house-manager", "smoke"}
    assert all(t.repo.startswith("michael-attias123/") for t in targets)
