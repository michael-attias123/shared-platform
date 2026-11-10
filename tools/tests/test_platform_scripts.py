"""The platform's own CI hooks, with stub gh and tofu: scripts/ci-backend.sh,
stacks/github/scripts/repo-security.sh and tools/pr_comment.sh."""
import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]

# Repos are on or off by name; every call is logged.
GH = r"""#!/bin/bash
echo "$GH_TOKEN $*" >> "$SIM/gh.log"
cat > "$SIM/stdin" 2>/dev/null < /dev/stdin &
wait
path="$*"
if [[ "$path" == *"-X PATCH"* ]]; then
  [[ "$path" == *refuses* ]] && exit 1
  exit 0
fi
if [[ "$path" == *"/comments"* ]]; then cat "$SIM/comments.json"; exit 0; fi
status=enabled; [[ "$path" == *off* || "$path" == *refuses* ]] && status=disabled
private=false; [[ "$path" == *private* ]] && private=true
echo "{\"private\": $private, \"security_and_analysis\": {\"secret_scanning\": {\"status\": \"$status\"},
      \"secret_scanning_push_protection\": {\"status\": \"$status\"}}}"
"""
TOFU = '#!/bin/bash\ncat "$SIM/repos.json"\n'


@pytest.fixture
def sim(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, text in (("gh", GH), ("tofu", TOFU)):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    (tmp_path / "gh.log").write_text("")
    return tmp_path


def run(sim, script, *args, repos=(), **env):
    (sim / "repos.json").write_text(json.dumps(list(repos)))
    full = {"PATH": f"{sim / 'bin'}:{os.environ['PATH']}", "SIM": str(sim), "RUNNER_TEMP": str(sim),
            "GITHUB_ENV": str(sim / "env"), "GH_TOKEN": "job-token", **env}
    return subprocess.run(["bash", str(ROOT / script), *args], env=full, capture_output=True, text=True, stdin=subprocess.DEVNULL)


SECURITY = "stacks/github/scripts/repo-security.sh"


def test_security_turns_on_what_is_off(sim):
    proc = run(sim, SECURITY, repos=["o/on", "o/off"], GITHUB_TOKEN="app-token")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    log = (sim / "gh.log").read_text().splitlines()
    assert [line for line in log if "PATCH" in line] == ["app-token api -X PATCH repos/o/off --input -"]
    # The App's token, never the job's (the hook step sets GH_TOKEN to the job's).
    assert all(line.startswith("app-token ") for line in log)


def test_security_drift_only_checks(sim):
    proc = run(sim, SECURITY, repos=["o/on", "o/off"], GITHUB_TOKEN="app-token", DRIFT_EXITCODE="0")
    assert proc.returncode == 1 and "o/off: secret scanning or push protection is off" in proc.stdout
    assert "PATCH" not in (sim / "gh.log").read_text()


def test_security_drift_passes_when_all_on_and_skips_an_outage(sim):
    assert run(sim, SECURITY, repos=["o/on"], GITHUB_TOKEN="t", DRIFT_EXITCODE="2").returncode == 0
    assert run(sim, SECURITY, repos=["o/off"], GITHUB_TOKEN="t", DRIFT_EXITCODE="skip").returncode == 0


def test_security_refusal_fails_but_a_private_repo_warns(sim):
    assert run(sim, SECURITY, repos=["o/refuses"], GITHUB_TOKEN="t").returncode == 1
    proc = run(sim, SECURITY, repos=["o/private-refuses"], GITHUB_TOKEN="t")
    assert proc.returncode == 0 and "::warning::" in proc.stdout


def test_security_needs_the_app_token(sim):
    assert run(sim, SECURITY, repos=["o/on"]).returncode != 0


def test_backend_config(sim):
    proc = run(sim, "scripts/ci-backend.sh", STATE_BUCKET="b-1", STATE_NAMESPACE="ns", STATE_REGION="eu-x-1")
    assert proc.returncode == 0, proc.stderr
    assert (sim / "env").read_text() == f"TF_CLI_ARGS_init=-backend-config={sim}/backend.hcl\n"
    hcl = (sim / "backend.hcl").read_text()
    assert 'bucket    = "b-1"' in hcl and "https://ns.compat.objectstorage.eu-x-1.oci.customer-oci.com" in hcl


def test_backend_refuses_odd_values(sim):
    assert run(sim, "scripts/ci-backend.sh", STATE_BUCKET='b"\nx', STATE_NAMESPACE="ns", STATE_REGION="r").returncode == 1
    assert run(sim, "scripts/ci-backend.sh", STATE_BUCKET="b").returncode != 0


@pytest.mark.parametrize("existing, verb", [
    ([], "api repos/o/r/issues/7/comments --input -"),
    ([{"id": 5, "user": {"login": "someone"}, "body": "<!-- m -->\nold"}], "api repos/o/r/issues/7/comments --input -"),
    ([{"id": 9, "user": {"login": "github-actions[bot]"}, "body": "<!-- m -->\nold"}],
     "api -X PATCH repos/o/r/issues/comments/9 --input -"),
])
def test_pr_comment_posts_or_updates_its_own(sim, existing, verb):
    (sim / "comments.json").write_text(json.dumps(existing))
    body = sim / "c.md"
    body.write_text("<!-- m -->\nnew\n")
    proc = run(sim, "tools/pr_comment.sh", "<!-- m -->", str(body), PR="7", GH_REPO="o/r")
    assert proc.returncode == 0, proc.stderr
    assert (sim / "gh.log").read_text().splitlines()[-1] == f"job-token {verb}"


def test_pr_comment_needs_the_marker_first(sim):
    body = sim / "c.md"
    body.write_text("hello\n")
    assert run(sim, "tools/pr_comment.sh", "<!-- m -->", str(body), PR="7", GH_REPO="o/r").returncode == 1
