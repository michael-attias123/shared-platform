"""tofu_plan.sh with a stub tofu (outage, recovery, real error, changes) and a stub gh."""
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]

TOFU = r"""#!/bin/bash
n=$(cat "$SIM/count" 2>/dev/null || echo 0); echo $((n+1)) > "$SIM/count"
printf '%s\n' "$@" > "$SIM/args"
case "$MODE" in
  outage) echo 'Error: [GET /search] search (status 503): {}'; exit 1;;
  recover) [[ $n == 0 ]] && { echo 'Error: x (status 503): {}'; exit 1; }; echo 'No changes.'; exit 0;;
  real) echo 'Error: Invalid reference'; exit 1;;
  changes) echo 'Plan: 1 to add, 0 to change, 0 to destroy.'; exit 2;;
  none) echo 'No changes.'; exit 0;;
esac
"""

# One successful run that reached the providers, LAST ago.
GH = r"""#!/bin/bash
if [[ "$2" == *"/workflows/"* ]]; then echo "7 abc $LAST"; else
  echo '{"jobs":[{"name":"infra / tofu","steps":[{"name":"Reached the providers","conclusion":"success"}]}]}'; fi
"""


@pytest.fixture
def sim(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, text in (("tofu", TOFU), ("gh", GH), ("sleep", "#!/bin/sh\n")):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    return tmp_path


def run(sim, mode, allow_outage=False, last_hours=1.0, targets=""):
    out = sim / "out"
    out.write_text("")
    last = (datetime.now(timezone.utc) - timedelta(hours=last_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    env = {
        "PATH": f"{sim / 'bin'}:{os.environ['PATH']}",
        "SIM": str(sim), "MODE": mode, "LAST": last,
        "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(sim / "summary"), "RUNNER_TEMP": str(sim),
        "ALLOW_OUTAGE": "true" if allow_outage else "false", "WORKFLOW_FILE": "infra.yml",
        "GH_REPO": "o/r", "TARGETS": targets,
    }
    proc = subprocess.run(["bash", str(TOOLS / "tofu_plan.sh"), "tfplan"], env=env, capture_output=True, text=True)
    count = int((sim / "count").read_text()) if (sim / "count").exists() else 0
    # The exitcode line; the summary line next to it is checked by test_summary_output.
    exitcode = "\n".join(line for line in out.read_text().splitlines() if not line.startswith("summary="))
    return proc, exitcode, count


def test_changes(sim):
    proc, out, calls = run(sim, "changes")
    assert (proc.returncode, out, calls) == (0, "exitcode=2", 1)
    assert "Plan: 1 to add" in proc.stdout


def test_no_changes(sim):
    proc, out, _ = run(sim, "none")
    assert (proc.returncode, out) == (0, "exitcode=0")


def test_real_error_fails_without_retry(sim):
    proc, out, calls = run(sim, "real", allow_outage=True)
    assert (proc.returncode, calls) == (1, 1)
    assert "Invalid reference" in proc.stdout


def test_recovers_on_retry(sim):
    proc, out, calls = run(sim, "recover")
    assert (proc.returncode, out, calls) == (0, "exitcode=0", 2)


def test_short_outage_skips_when_allowed(sim):
    proc, out, calls = run(sim, "outage", allow_outage=True, last_hours=1)
    assert (proc.returncode, out, calls) == (0, "exitcode=skip", 2)
    assert "::warning::" in proc.stdout


def test_long_outage_fails(sim):
    proc, out, _ = run(sim, "outage", allow_outage=True, last_hours=7)
    assert proc.returncode == 1
    assert "over 6 hours" in proc.stdout


def test_outage_fails_when_someone_waits(sim):
    proc, _, calls = run(sim, "outage", allow_outage=False)
    assert (proc.returncode, calls) == (1, 2)


def test_targets(sim):
    run(sim, "none", targets="module.observability\n  module.uptime  \n\n")
    args = (sim / "args").read_text().splitlines()
    assert "-target=module.observability" in args and "-target=module.uptime" in args
    assert "-out=tfplan" in args


@pytest.mark.parametrize("mode, allow_outage, summary", [
    ("changes", False, "Plan: 1 to add, 0 to change, 0 to destroy."),
    ("none", False, "No changes."),
    ("outage", True, "Skipped: a provider was unavailable."),
    ("real", False, "The plan failed."),
])
def test_summary_output(sim, mode, allow_outage, summary):
    """Callers (a project's platform-check) report this line; it holds counts only."""
    run(sim, mode, allow_outage=allow_outage)
    assert f"summary={summary}" in (sim / "out").read_text().splitlines()
