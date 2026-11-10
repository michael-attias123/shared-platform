"""Turns one finished GitHub Actions run into an OpenTelemetry trace and two gauges.

Run by the reusable .github/workflows/gha-telemetry.yml on `workflow_run: completed`:

    RUN_ID=<id> RUN_ATTEMPT=<n> GITHUB_TOKEN=... GITHUB_REPOSITORY=owner/repo \
    GHA_TRACE_WORKFLOWS=prices,venues,infra \
    OTEL_EXPORTER_OTLP_ENDPOINT=... OTEL_EXPORTER_OTLP_HEADERS=... \
    python tools/gha_trace.py

One trace per run: the workflow span, a span per job, a span per step, each
with the real start and end times from the API. Attributes are an allow-list:
workflow, job and step names, conclusion, run number, attempt, event. Never
the branch, commit (SHA, message or display title), actor, or any name or
email. Gauges: gha_workflow_last_duration_seconds{workflow} and
gha_workflow_last_conclusion{workflow,conclusion} (1 for the run's conclusion,
0 for the others), where workflow is the file name without .yml when it is
listed in GHA_TRACE_WORKFLOWS (comma-separated), else "other": metric labels
stay a fixed set. Pull request runs (plans) get a trace but leave the gauges
alone.

It always exits 0: a failed API call or export is a ::warning::, so it never
sends failure emails. It prints counts only, never a payload (public logs).
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import urllib.request
from datetime import datetime
from typing import Any, Callable

SERVICE_NAME = "gha-telemetry"
EXPORT_TIMEOUT_S = 10


def listed_workflows(env: dict[str, str] | None = None) -> frozenset[str]:
    """The caller's workflows, by file name (GHA_TRACE_WORKFLOWS); anything else is "other"."""
    raw = (os.environ if env is None else env).get("GHA_TRACE_WORKFLOWS") or ""
    return frozenset(w.strip() for w in raw.split(",") if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,40}", w.strip()))


WORKFLOWS = listed_workflows()

CONCLUSIONS = ("success", "failure", "cancelled", "skipped", "timed_out", "other")
SPAN_ATTRIBUTES = {"workflow", "job", "step", "conclusion", "run_number", "run_attempt", "event"}
MAX_NAME = 80

_SCRUB = [
    (re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"), "[email]"),
    (re.compile(r"\b[0-9a-f]{40}\b", re.IGNORECASE), "[sha]"),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE), "[id]"),
]


def warn(message: str) -> None:
    print(f"::warning::gha_trace: {message}")


def clean_name(name: Any) -> str:
    """A job or step name: first line, no emails or SHAs, at most MAX_NAME characters."""
    lines = [line.strip() for line in str(name or "").splitlines() if line.strip()]
    text = lines[0] if lines else "unnamed"
    for pattern, repl in _SCRUB:
        text = pattern.sub(repl, text)
    return text[:MAX_NAME]


def workflow_key(run: dict) -> str:
    """The file name when GHA_TRACE_WORKFLOWS lists it, else other."""
    stem = os.path.splitext(os.path.basename(str(run.get("path") or "")))[0]
    return stem if stem in WORKFLOWS else "other"


def conclusion(value: Any) -> str:
    value = str(value or "")
    if value == "startup_failure":
        return "failure"
    return value if value in CONCLUSIONS else "other"


def to_ns(stamp: Any) -> int | None:
    if not stamp:
        return None
    try:
        return int(datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp() * 1e9)
    except ValueError:
        return None


# --- GitHub API -------------------------------------------------------------------


def _get(url: str, token: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_run(api: str, repo: str, run_id: str, attempt: str | None, token: str) -> tuple[dict, list[dict]]:
    """The run and its jobs (with steps) for one attempt."""
    run = _get(f"{api}/repos/{repo}/actions/runs/{run_id}", token)
    attempt = attempt or str(run.get("run_attempt") or 1)
    jobs: list[dict] = []
    for page in range(1, 6):
        body = _get(f"{api}/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}", token)
        jobs += body.get("jobs") or []
        if len(jobs) >= int(body.get("total_count") or 0) or not body.get("jobs"):
            break
    return run, jobs


# --- telemetry --------------------------------------------------------------------


def _status(span: Any, value: str) -> None:
    from opentelemetry.trace import Status, StatusCode

    if value in ("failure", "timed_out"):
        span.set_status(Status(StatusCode.ERROR))


def record(run: dict, jobs: list[dict], tracer: Any, meter: Any) -> int:
    """Creates the spans and sets the gauges. Returns the number of spans."""
    from opentelemetry import trace

    run_conclusion = conclusion(run.get("conclusion"))
    common = {
        "workflow": clean_name(run.get("name")),
        "run_number": int(run.get("run_number") or 0),
        "run_attempt": int(run.get("run_attempt") or 1),
        "event": clean_name(run.get("event")),
    }
    job_times = [(to_ns(j.get("started_at")), to_ns(j.get("completed_at"))) for j in jobs]
    start = to_ns(run.get("run_started_at")) or to_ns(run.get("created_at"))
    ends = [end for _, end in job_times if end]
    end = max(ends) if ends else to_ns(run.get("updated_at"))
    if start is None or end is None or end < start:
        raise ValueError("run without usable start and end times")

    count = 1
    root = tracer.start_span(common["workflow"], start_time=start, attributes={**common, "conclusion": run_conclusion})
    _status(root, run_conclusion)
    root_ctx = trace.set_span_in_context(root)
    for job, (job_start, job_end) in zip(jobs, job_times):
        if not job_start or not job_end:
            continue  # never started (skipped or cancelled while queued)
        job_conclusion = conclusion(job.get("conclusion"))
        job_name = clean_name(job.get("name"))
        job_span = tracer.start_span(
            job_name,
            context=root_ctx,
            start_time=job_start,
            attributes={**common, "job": job_name, "conclusion": job_conclusion},
        )
        _status(job_span, job_conclusion)
        job_ctx = trace.set_span_in_context(job_span)
        count += 1
        for step in job.get("steps") or []:
            step_start, step_end = to_ns(step.get("started_at")), to_ns(step.get("completed_at"))
            if not step_start or not step_end:
                continue
            step_conclusion = conclusion(step.get("conclusion"))
            step_name = clean_name(step.get("name"))
            step_span = tracer.start_span(
                step_name,
                context=job_ctx,
                start_time=step_start,
                attributes={**common, "job": job_name, "step": step_name, "conclusion": step_conclusion},
            )
            _status(step_span, step_conclusion)
            step_span.end(end_time=max(step_end, step_start))
            count += 1
        job_span.end(end_time=max(job_end, job_start))
    root.end(end_time=end)

    if run.get("event") != "pull_request":
        workflow = workflow_key(run)
        duration = meter.create_gauge(
            "gha_workflow_last_duration_seconds", unit="", description="Duration of the workflow's last run"
        )
        last = meter.create_gauge(
            "gha_workflow_last_conclusion", unit="", description="1 for the last run's conclusion, 0 for the others"
        )
        duration.set(round((end - start) / 1e9, 1), {"workflow": workflow})
        for c in CONCLUSIONS:
            last.set(1 if c == run_conclusion else 0, {"workflow": workflow, "conclusion": c})
    return count


def collect(run: dict, jobs: list[dict], service_name: str = SERVICE_NAME) -> tuple[list, Any, int]:
    """(spans, metrics data, span count), built in memory."""
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import InMemoryMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    resource = Resource.create({"service.name": service_name})
    memory = InMemorySpanExporter()
    tracer_provider = TracerProvider(resource=resource, shutdown_on_exit=False)
    tracer_provider.add_span_processor(SimpleSpanProcessor(memory))
    reader = InMemoryMetricReader()
    meter_provider = MeterProvider(resource=resource, metric_readers=[reader], shutdown_on_exit=False)
    count = record(run, jobs, tracer_provider.get_tracer("gha_trace"), meter_provider.get_meter("gha_trace"))
    return list(memory.get_finished_spans()), reader.get_metrics_data(), count


def otlp_exporters() -> tuple[Any, Any]:
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

    # The exporters' retry warnings name the collector host; the logs are public.
    logging.getLogger("opentelemetry").setLevel(logging.ERROR)
    # Both read OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_EXPORTER_OTLP_HEADERS.
    return OTLPSpanExporter(timeout=EXPORT_TIMEOUT_S), OTLPMetricExporter(timeout=EXPORT_TIMEOUT_S)


def export(spans: list, metrics: Any, span_exporter: Any, metric_exporter: Any) -> bool:
    from opentelemetry.sdk.metrics.export import MetricExportResult
    from opentelemetry.sdk.trace.export import SpanExportResult

    ok = True
    try:
        if span_exporter.export(spans) != SpanExportResult.SUCCESS:
            warn("trace export failed")
            ok = False
    except Exception as error:
        warn(f"trace export failed ({type(error).__name__})")
        ok = False
    try:
        if metrics is not None and metric_exporter.export(metrics) != MetricExportResult.SUCCESS:
            warn("metric export failed")
            ok = False
    except Exception as error:
        warn(f"metric export failed ({type(error).__name__})")
        ok = False
    for exporter in (span_exporter, metric_exporter):
        try:
            exporter.shutdown()
        except Exception:
            pass
    return ok


def main(
    env: dict[str, str] | None = None,
    fetch: Callable[..., tuple[dict, list[dict]]] = fetch_run,
    exporters: Callable[[], tuple[Any, Any]] = otlp_exporters,
) -> int:
    env = os.environ if env is None else env
    if not (env.get("OTEL_EXPORTER_OTLP_ENDPOINT") or "").strip():
        print("gha_trace: OTEL_EXPORTER_OTLP_ENDPOINT is not set; nothing to do.")
        return 0
    try:
        run, jobs = fetch(
            env.get("GITHUB_API_URL") or "https://api.github.com",
            env["GITHUB_REPOSITORY"],
            env["RUN_ID"],
            env.get("RUN_ATTEMPT") or None,
            env["GITHUB_TOKEN"],
        )
    except Exception as error:
        warn(f"could not read the run ({type(error).__name__})")
        return 0
    try:
        spans, metrics, count = collect(run, jobs, (env.get("OTEL_SERVICE_NAME") or "").strip() or SERVICE_NAME)
        span_exporter, metric_exporter = exporters()
    except Exception as error:
        warn(f"could not build the trace ({type(error).__name__})")
        return 0
    if export(spans, metrics, span_exporter, metric_exporter):
        print(f"gha_trace: exported {count} spans for workflow {workflow_key(run)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
