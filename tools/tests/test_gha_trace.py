"""tools/gha_trace.py, on fake GitHub API answers."""

import copy
import importlib.util
from datetime import datetime
from pathlib import Path

import pytest
from opentelemetry.sdk.metrics.export import MetricExportResult
from opentelemetry.sdk.trace.export import SpanExportResult

import os

# The workflows the caller lists (house-manager's, as the example).
os.environ["GHA_TRACE_WORKFLOWS"] = "prices,venues,db-migrate,infra"
SCRIPT = Path(__file__).resolve().parents[1] / "gha_trace.py"
spec = importlib.util.spec_from_file_location("gha_trace", SCRIPT)
gha_trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gha_trace)

SHA = "4624602aa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
# Values the run carries that must never reach telemetry.
PRIVATE = [
    SHA,
    "monitoring-ingest",
    "Dana Levi",
    "dana@example.com",
    "dana-gh",
    "infra: bootstrap secrets",
    "runner-17",
]

RUN = {
    "id": 123456789,
    "name": "Supermarket prices",
    "path": ".github/workflows/prices.yml",
    "display_title": "infra: bootstrap secrets",
    "run_number": 42,
    "run_attempt": 2,
    "event": "schedule",
    "status": "completed",
    "conclusion": "failure",
    "head_branch": "monitoring-ingest",
    "head_sha": SHA,
    "created_at": "2026-11-01T03:17:00Z",
    "run_started_at": "2026-11-01T03:17:05Z",
    "updated_at": "2026-11-01T03:25:00Z",
    "actor": {"login": "dana-gh", "id": 1},
    "triggering_actor": {"login": "dana-gh", "id": 1},
    "head_commit": {
        "id": SHA,
        "message": "infra: bootstrap secrets",
        "author": {"name": "Dana Levi", "email": "dana@example.com"},
        "committer": {"name": "Dana Levi", "email": "dana@example.com"},
    },
}

JOBS = [
    {
        "id": 1,
        "name": "ingest",
        "head_branch": "monitoring-ingest",
        "head_sha": SHA,
        "runner_name": "runner-17",
        "conclusion": "failure",
        "started_at": "2026-11-01T03:17:10Z",
        "completed_at": "2026-11-01T03:24:50Z",
        "steps": [
            {"name": "Set up job", "conclusion": "success", "started_at": "2026-11-01T03:17:10Z", "completed_at": "2026-11-01T03:17:12Z"},
            {"name": "Skip until Supabase is connected", "conclusion": "skipped", "started_at": None, "completed_at": None},
            {"name": "Run actions/checkout@v5", "conclusion": "success", "started_at": "2026-11-01T03:17:12Z", "completed_at": "2026-11-01T03:17:15Z"},
            {
                "name": f"Run echo dana@example.com {SHA}\nsecond line",
                "conclusion": "failure",
                "started_at": "2026-11-01T03:17:15Z",
                "completed_at": "2026-11-01T03:24:49Z",
            },
        ],
    },
    {"id": 2, "name": "never ran", "conclusion": "skipped", "started_at": None, "completed_at": None, "steps": []},
]


def ns(stamp):
    return int(datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1e9)


def texts(span):
    yield span.name
    for k, v in span.attributes.items():
        yield f"{k}={v}"
    for k, v in span.resource.attributes.items():
        yield f"{k}={v}"


def points(metrics):
    out = {}
    for rm in metrics.resource_metrics:
        for sm in rm.scope_metrics:
            for metric in sm.metrics:
                assert metric.unit == ""
                for p in metric.data.data_points:
                    out[(metric.name, tuple(sorted(p.attributes.items())))] = p.value
    return out


def test_one_trace_with_real_times_and_only_allow_listed_attributes():
    spans, metrics, count = gha_trace.collect(RUN, JOBS)
    assert count == len(spans) == 5
    assert len({s.context.trace_id for s in spans}) == 1
    by_name = {s.name: s for s in spans}
    assert set(by_name) == {
        "Supermarket prices",
        "ingest",
        "Set up job",
        "Run actions/checkout@v5",
        "Run echo [email] [sha]",
    }
    root, job = by_name["Supermarket prices"], by_name["ingest"]
    assert root.parent is None
    assert job.parent.span_id == root.context.span_id
    assert by_name["Set up job"].parent.span_id == job.context.span_id

    assert (root.start_time, root.end_time) == (ns(RUN["run_started_at"]), ns(JOBS[0]["completed_at"]))
    assert (job.start_time, job.end_time) == (ns(JOBS[0]["started_at"]), ns(JOBS[0]["completed_at"]))
    step = by_name["Run actions/checkout@v5"]
    assert (step.start_time, step.end_time) == (ns("2026-11-01T03:17:12Z"), ns("2026-11-01T03:17:15Z"))

    assert dict(root.attributes) == {
        "workflow": "Supermarket prices",
        "run_number": 42,
        "run_attempt": 2,
        "event": "schedule",
        "conclusion": "failure",
    }
    assert dict(step.attributes) == {
        "workflow": "Supermarket prices",
        "run_number": 42,
        "run_attempt": 2,
        "event": "schedule",
        "job": "ingest",
        "step": "Run actions/checkout@v5",
        "conclusion": "success",
    }
    assert root.status.status_code.name == "ERROR"
    assert step.status.status_code.name == "UNSET"
    for s in spans:
        assert set(s.attributes) <= gha_trace.SPAN_ATTRIBUTES
        assert not s.events
        assert s.resource.attributes["service.name"] == "gha-telemetry"
        for text in texts(s):
            assert not any(p in text for p in PRIVATE), text


def test_gauges():
    _, metrics, _ = gha_trace.collect(RUN, JOBS)
    got = points(metrics)
    assert got[("gha_workflow_last_duration_seconds", (("workflow", "prices"),))] == 465.0
    assert got[("gha_workflow_last_conclusion", (("conclusion", "failure"), ("workflow", "prices")))] == 1
    assert got[("gha_workflow_last_conclusion", (("conclusion", "success"), ("workflow", "prices")))] == 0
    assert {name for name, _ in got} == {"gha_workflow_last_duration_seconds", "gha_workflow_last_conclusion"}
    assert len(got) == 1 + len(gha_trace.CONCLUSIONS)


def test_pull_request_runs_leave_the_gauges_alone():
    run = {**RUN, "event": "pull_request", "path": ".github/workflows/infra.yml", "name": "Infrastructure"}
    spans, metrics, _ = gha_trace.collect(run, JOBS)
    assert spans
    assert metrics is None or not points(metrics)


def test_unknown_workflows_and_conclusions_are_folded():
    run = {**RUN, "path": ".github/workflows/something-else.yml", "conclusion": "action_required"}
    _, metrics, _ = gha_trace.collect(run, JOBS)
    got = points(metrics)
    assert got[("gha_workflow_last_conclusion", (("conclusion", "other"), ("workflow", "other")))] == 1
    assert gha_trace.conclusion("startup_failure") == "failure"
    assert gha_trace.conclusion(None) == "other"


class Exporter:
    def __init__(self, result=None, error=None):
        self.result, self.error, self.calls = result, error, 0

    def export(self, data, **kwargs):
        self.calls += 1
        if self.error:
            raise self.error
        return self.result

    def shutdown(self, **kwargs):
        pass


ENV = {
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otlp.example.com/otlp",
    "GITHUB_REPOSITORY": "owner/repo",
    "RUN_ID": "123456789",
    "RUN_ATTEMPT": "2",
    "GITHUB_TOKEN": "ghs_not_a_real_token",
}


def fake_fetch(api, repo, run_id, attempt, token):
    assert (api, repo, run_id, attempt) == ("https://api.github.com", "owner/repo", "123456789", "2")
    return copy.deepcopy(RUN), copy.deepcopy(JOBS)


def test_exports_once_and_prints_no_payload(capsys):
    spans, metrics = Exporter(SpanExportResult.SUCCESS), Exporter(MetricExportResult.SUCCESS)
    assert gha_trace.main(ENV, fake_fetch, lambda: (spans, metrics)) == 0
    assert (spans.calls, metrics.calls) == (1, 1)
    out = capsys.readouterr().out
    assert out == "gha_trace: exported 5 spans for workflow prices\n"


@pytest.mark.parametrize(
    "span_exporter, metric_exporter",
    [
        (Exporter(SpanExportResult.FAILURE), Exporter(MetricExportResult.FAILURE)),
        (Exporter(error=ConnectionError("refused")), Exporter(error=TimeoutError())),
    ],
)
def test_export_failures_exit_0_with_a_warning(capsys, span_exporter, metric_exporter):
    assert gha_trace.main(ENV, fake_fetch, lambda: (span_exporter, metric_exporter)) == 0
    out = capsys.readouterr().out
    assert "::warning::gha_trace: trace export failed" in out
    assert "::warning::gha_trace: metric export failed" in out
    assert "refused" not in out


def test_api_failure_and_bad_data_exit_0(capsys):
    def broken_fetch(*args):
        raise OSError("HTTP Error 404")

    assert gha_trace.main(ENV, broken_fetch, lambda: (None, None)) == 0
    assert "::warning::gha_trace: could not read the run (OSError)" in capsys.readouterr().out

    def no_times(*args):
        return {**RUN, "run_started_at": None, "created_at": None}, []

    assert gha_trace.main(ENV, no_times, lambda: (None, None)) == 0
    assert "could not build the trace" in capsys.readouterr().out


def test_noop_without_endpoint(capsys):
    def no_fetch(*args):
        raise AssertionError("fetched without an endpoint")

    assert gha_trace.main({**ENV, "OTEL_EXPORTER_OTLP_ENDPOINT": ""}, no_fetch) == 0
    assert "nothing to do" in capsys.readouterr().out


def test_clean_name():
    assert gha_trace.clean_name(None) == "unnamed"
    assert gha_trace.clean_name("\n  Run tofu plan\nmore") == "Run tofu plan"
    assert len(gha_trace.clean_name("x" * 300)) == gha_trace.MAX_NAME
