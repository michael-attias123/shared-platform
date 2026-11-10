"""scripts/seed.sh with fake vault, sops and tofu: what it writes, keeps and never prints."""
import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]

VAULT = r"""#!/usr/bin/env python3
import json, os, sys
store = os.environ["FAKE_VAULT"]
args = sys.argv[1:]
def path_of(p): return os.path.join(store, p.replace("/", "__") + ".json")
if args[:2] == ["token", "lookup"]:
    sys.exit(0)
if args[:2] == ["kv", "get"]:
    f = path_of(args[-1])
    if not os.path.exists(f):
        sys.exit(2)
    print(json.dumps({"data": {"data": json.load(open(f))}}))
    sys.exit(0)
if args[:2] == ["kv", "put"]:
    src = args[-1][1:]  # @file
    json.dump(json.load(open(src)), open(path_of(args[-2]), "w"))
    sys.exit(0)
sys.exit(3)
"""

# Reads `jsonencode(yamldecode(file("X")))` and prints the JSON as a quoted string, like tofu console.
TOFU = r"""#!/usr/bin/env python3
import json, re, sys, yaml
path = re.search(r'file\("([^"]+)"\)', sys.stdin.read()).group(1)
print(json.dumps(json.dumps(yaml.safe_load(open(path)))))
"""

SOPS = r"""#!/bin/sh
cat "$FAKE_SOPS_JSON"
"""


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, text in (("vault", VAULT), ("tofu", TOFU), ("sops", SOPS)):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    store = tmp_path / "vault"
    store.mkdir()
    return {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(tmp_path),
        "PLATFORM_CONFIG_DIR": str(tmp_path / "platform"),
        "VAULT_ADDR": "https://vault.test",
        "FAKE_VAULT": str(store),
    }


def run(env, *args):
    return subprocess.run(["bash", str(ROOT / "scripts" / "seed.sh"), *args], env=env,
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)


def stored(env, path):
    f = Path(env["FAKE_VAULT"]) / (path.replace("/", "__") + ".json")
    return json.loads(f.read_text()) if f.exists() else None


SOPS_VALUES = {
    "vapid_public_key": "pub-SECRET", "vapid_private_key": "priv-SECRET", "vapid_subject": "https://x.example",
    "push_secret": "push-SECRET", "google_client_id": "gid", "google_client_secret": "gsec-SECRET",
    "supabase_db_password": "dbpw-SECRET", "supabase_db_url": "postgresql://u:p@h/db",
    "grafana_reader_password": "gr-SECRET", "alert_webhook_secret": "aw-SECRET",
    "alert_email": "owner@example.com", "gitsync_github_token": "gs-SECRET",
}


def test_from_sops_fills_app_and_monitoring(env, tmp_path):
    sops_json = tmp_path / "sops.json"
    sops_json.write_text(json.dumps(SOPS_VALUES))
    env["FAKE_SOPS_JSON"] = str(sops_json)
    proc = run(env, "house-manager", "--from-sops", str(tmp_path / "secrets.enc.yaml"))
    assert proc.returncode == 0, proc.stderr
    app = stored(env, "house-manager/app")
    assert app["vapid_private_key"] == "priv-SECRET" and len(app) == 8
    assert stored(env, "house-manager/monitoring")["alert_email"] == "owner@example.com"
    # No trailing newline crept into a value.
    assert app["supabase_db_url"] == "postgresql://u:p@h/db"
    # providers and state had no source and no terminal: skipped, reported, not written.
    assert stored(env, "house-manager/providers") is None
    assert "still missing" in proc.stderr
    for v in SOPS_VALUES.values():
        if "SECRET" in v:
            assert v not in proc.stdout + proc.stderr
    assert "vapid_private_key: added (sops)" in proc.stdout
    # The work files are gone.
    assert not any((tmp_path / "platform").glob("seed.*"))


def test_never_overwrites(env, tmp_path):
    store = Path(env["FAKE_VAULT"])
    (store / "house-manager__app.json").write_text(json.dumps({"vapid_private_key": "kept"}))
    sops_json = tmp_path / "sops.json"
    sops_json.write_text(json.dumps(SOPS_VALUES))
    env["FAKE_SOPS_JSON"] = str(sops_json)
    proc = run(env, "house-manager", "--from-sops", str(tmp_path / "s.yaml"))
    assert proc.returncode == 0, proc.stderr
    app = stored(env, "house-manager/app")
    assert app["vapid_private_key"] == "kept"
    assert app["push_secret"] == "push-SECRET"
    assert "vapid_private_key: in Vault" in proc.stdout


def test_from_env_for_platform(env, tmp_path):
    oci = tmp_path / "oci.env"
    oci.write_text("# comment\nAWS_ACCESS_KEY_ID=akid\nAWS_SECRET_ACCESS_KEY=sak-SECRET\n"
                   "QOPS_OCI_NAMESPACE=ns\nQOPS_OCI_REGION=il-jerusalem-1\nQOPS_STATE_BUCKET=qops-tofu-state\n")
    tofu_env = tmp_path / "tofu.env"
    tofu_env.write_text("TF_VAR_state_passphrase=pass-SECRET\n")
    proc = run(env, "_platform", "--from-env", str(oci), "--from-env", str(tofu_env))
    state = stored(env, "platform/state")
    assert state == {"aws_access_key_id": "akid", "aws_secret_access_key": "sak-SECRET", "passphrase": "pass-SECRET",
                     "bucket": "qops-tofu-state", "namespace": "ns", "region": "il-jerusalem-1"}
    assert "sak-SECRET" not in proc.stdout + proc.stderr
    # github-app has no source here: reported missing.
    assert stored(env, "platform/github-app") is None
    assert "app_id: skipped" in proc.stderr


def test_check_lists_missing_and_fails(env):
    proc = run(env, "_shared", "--check")
    assert proc.returncode == 1
    assert "access_token: missing" in proc.stderr
    assert stored(env, "shared/supabase") is None


def test_unknown_project(env):
    proc = run(env, "nope")
    assert proc.returncode == 1
    assert "no " in proc.stderr
