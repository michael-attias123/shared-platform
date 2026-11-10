"""Tests for transient.py."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import transient  # noqa: E402

# The 2026-11-05 run: Grafana answered 503 to every call.
OUTAGE = """\
Error: [GET /v1/provisioning/contact-points] GetContactpoints (status 503): {}

  with module.observability[0].grafana_contact_point.email_owner,

Error: error reading folder with ID`0:hm-alerts`: [GET /folders/{folder_uid}] getFolderByUID (status 503): {}

Error: [GET /search] search (status 503): {}
"""


@pytest.mark.parametrize("log", [
    OUTAGE,
    "Error: [GET /api/health] (status 502): {}\n",
    "Error: [POST /v1/provisioning/alert-rules] (status 429): rate limited\n",
    'Error: Get "https://x.grafana.net/api/folders": context deadline exceeded\n',
    'Error: Get "https://x.grafana.net/api/search": read tcp: connection reset by peer\n',
])
def test_transient(log):
    assert transient.is_transient(log)


@pytest.mark.parametrize("log", [
    "",
    "Plan: 1 to add, 0 to change, 0 to destroy.\n",
    OUTAGE + "Error: Unsupported argument\n\n  on alerting.tf line 3\n",
    "Error: [GET /search] search (status 401): {}\n",
    "Error: Error acquiring the state lock\n",
    "Error: Invalid reference\n",
])
def test_not_transient(log):
    assert not transient.is_transient(log)


def test_main(tmp_path):
    path = tmp_path / "plan.log"
    path.write_text(OUTAGE, encoding="utf-8")
    assert transient.main([str(path)]) == 0
    path.write_text("Error: Invalid reference\n", encoding="utf-8")
    assert transient.main([str(path)]) == 1
