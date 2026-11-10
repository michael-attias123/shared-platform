"""Tests for plan_guard.py: the module allow-list and the destroy guard."""
import io
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import plan_guard  # noqa: E402

SCOPE = ["--allow", "module.observability", "--allow", "module.uptime"]
ALLOWED = ("module.observability", "module.uptime")


def rtype(address):
    """The resource type in an address: the second-to-last dotted part."""
    return address.split(".")[-2].split("[")[0]


def plan(*changes, **extra):
    return {
        "format_version": "1.2",
        "resource_changes": [
            {"address": address, "type": rtype(address),
             "change": {"actions": actions, "after": {"secret": "never-printed"}}}
            for address, actions in changes
        ],
        **extra,
    }


def run(tmp_path, doc, capsys, *args):
    path = tmp_path / "plan.json"
    path.write_text(json.dumps(doc), encoding="utf-8")
    code = plan_guard.main([*args, str(path)])
    return code, capsys.readouterr().out


@pytest.mark.parametrize("address", [
    "module.observability.grafana_rule_group.this[\"availability\"]",
    "module.observability.module.inner.grafana_folder.this",
    "module.uptime.grafana_synthetic_monitoring_check.app[0]",
    "module.uptime[0].grafana_synthetic_monitoring_check.app",
])
def test_in_scope(address):
    assert plan_guard.in_scope(address, ALLOWED)


@pytest.mark.parametrize("address", [
    "module.backend.supabase_project.this",
    "module.observability_extra.thing.x",
    "module.uptimes.thing.x",
    "grafana_folder.root",
])
def test_out_of_scope(address):
    assert not plan_guard.in_scope(address, ALLOWED)


def test_no_allow_list_means_everything_in_scope():
    assert plan_guard.in_scope("anything.at_all", ())


def test_changes_inside_pass(tmp_path, capsys):
    code, out = run(tmp_path, plan(
        ("module.observability.grafana_rule_group.this[\"budget\"]", ["update"]),
        ("module.uptime.grafana_synthetic_monitoring_check.app", ["delete", "create"]),
    ), capsys, *SCOPE)
    assert code == 0
    assert "2 change(s), all inside module.observability and module.uptime" in out
    assert "delete-create module.uptime" in out
    assert "never-printed" not in out


def test_change_outside_refused(tmp_path, capsys):
    code, out = run(tmp_path, plan(
        ("module.observability.grafana_rule_group.this[\"budget\"]", ["update"]),
        ("module.backend.supabase_settings.this", ["update"]),
    ), capsys, *SCOPE)
    assert code == 1
    assert "module.backend.supabase_settings.this is outside" in out
    assert "never-printed" not in out


@pytest.mark.parametrize("actions", [["delete"], ["delete", "create"], ["create", "delete"]])
def test_protected_delete_refused(tmp_path, capsys, actions):
    code, out = run(tmp_path, plan(("vault_mount.kv", actions)), capsys, "--protect", "vault_mount")
    assert code == 1
    assert "vault_mount is protected" in out


def test_protected_delete_allowed_with_flag(tmp_path, capsys):
    code, _ = run(tmp_path, plan(("vault_mount.kv", ["delete"])), capsys,
                  "--protect", "vault_mount", "--allow-destroy")
    assert code == 0


def test_protected_update_passes(tmp_path, capsys):
    code, _ = run(tmp_path, plan(("vault_mount.kv", ["update"])), capsys, "--protect", "vault_mount")
    assert code == 0


def test_unprotected_delete_passes(tmp_path, capsys):
    code, _ = run(tmp_path, plan(("vault_policy.x", ["delete"])), capsys, "--protect", "vault_mount")
    assert code == 0


def test_reads_and_no_ops_ignored(tmp_path, capsys):
    code, out = run(tmp_path, plan(
        ("module.secrets.data.vault_kv_secret_v2.app", ["read"]),
        ("module.backend.supabase_project.this", ["no-op"]),
    ), capsys, *SCOPE)
    assert code == 0
    assert "0 change(s)" in out


def test_no_resource_changes_key(tmp_path, capsys):
    code, _ = run(tmp_path, {"format_version": "1.2"}, capsys)
    assert code == 0


def test_errored_plan_refused(tmp_path, capsys):
    code, out = run(tmp_path, plan(errored=True), capsys)
    assert code == 1
    assert "errored" in out


def test_not_a_plan_refused(tmp_path, capsys):
    code, _ = run(tmp_path, {"resource_changes": []}, capsys)
    assert code == 1


def test_unreadable_file(tmp_path):
    (tmp_path / "plan.json").write_text("{oops", encoding="utf-8")
    assert plan_guard.main([str(tmp_path / "plan.json")]) == 1
    assert plan_guard.main([str(tmp_path / "missing.json")]) == 1


def test_stdin(monkeypatch):
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(plan(
        ("module.observability.grafana_mute_timing.this[\"x\"]", ["create"])))))
    assert plan_guard.main([*SCOPE, "-"]) == 0


def test_usage():
    with pytest.raises(SystemExit):
        plan_guard.main([])
