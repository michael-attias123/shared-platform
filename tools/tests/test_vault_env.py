"""The vault-env action's script against a fake GitHub OIDC endpoint and a fake Vault."""
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / ".github" / "actions" / "vault-env" / "vault-env.sh"
JWT = "jwt-from-github"
TOKEN = "hvs.vault-token"
KV = {
    "/v1/kv/data/app/providers": {"cloudflare_api_token": "cf-secret", "multi": "line one\nline two"},
    "/v1/kv/data/app/state": {"passphrase": "pass-secret", "number": 42},
}


class Fake(BaseHTTPRequestHandler):
    failures_left = 0  # 503s before answering, to test the retries
    seen: list[str] = []

    def log_message(self, *args):
        pass

    def reply(self, code, doc):
        data = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def flaky(self):
        if Fake.failures_left > 0:
            Fake.failures_left -= 1
            self.reply(503, {"errors": ["sealed"]})
            return True
        return False

    def do_GET(self):
        Fake.seen.append(f"GET {self.path}")
        if self.path.startswith("/token"):
            ok = self.headers.get("Authorization") == "bearer request-token" and "audience=vault" in self.path
            return self.reply(200 if ok else 403, {"value": JWT} if ok else {})
        if self.flaky():
            return
        if self.headers.get("X-Vault-Token") != TOKEN:
            return self.reply(403, {"errors": ["permission denied"]})
        if self.path in KV:
            return self.reply(200, {"data": {"data": KV[self.path], "metadata": {"version": 1}}})
        return self.reply(404, {"errors": []})

    def do_POST(self):
        Fake.seen.append(f"POST {self.path}")
        if self.flaky():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/auth/jwt-github/login" and body == {"role": "app-main", "jwt": JWT}:
            return self.reply(200, {"auth": {"client_token": TOKEN}})
        return self.reply(400, {"errors": ["role not found"]})


@pytest.fixture
def server():
    Fake.failures_left = 0
    Fake.seen = []
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def run(server, tmp_path, secrets, role="app-main", export_token="false"):
    env_file = tmp_path / "github_env"
    env_file.write_text("")
    env = {
        "PATH": os.environ["PATH"],
        "GITHUB_ENV": str(env_file),
        "ACTIONS_ID_TOKEN_REQUEST_URL": f"{server}/token?x=1",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request-token",
        "VE_ADDR": server,
        "VE_ROLE": role,
        "VE_SECRETS": secrets,
        "VE_EXPORT_TOKEN": export_token,
        "VE_INSECURE_TEST_ONLY": "1",
        "VE_RETRY_DELAY": "0",
    }
    proc = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    return proc, env_file.read_text()


def parse_env(text):
    """GITHUB_ENV heredoc entries: NAME<<DELIM / value / DELIM."""
    out, lines, i = {}, text.split("\n"), 0
    while i < len(lines):
        if "<<" in lines[i]:
            name, delim = lines[i].split("<<", 1)
            j = lines.index(delim, i + 1)
            out[name] = "\n".join(lines[i + 1:j])
            i = j
        i += 1
    return out


SECRETS = """
# providers
kv/data/app/providers cloudflare_api_token | CLOUDFLARE_API_TOKEN
kv/data/app/providers multi | MULTI
kv/data/app/state number|NUMBER
"""


def test_exports_values_masked_and_never_printed(server, tmp_path):
    proc, env_text = run(server, tmp_path, SECRETS)
    assert proc.returncode == 0, proc.stderr
    env = parse_env(env_text)
    assert env == {"CLOUDFLARE_API_TOKEN": "cf-secret", "MULTI": "line one\nline two", "NUMBER": "42"}
    for value in ("cf-secret", "line one", "line two", JWT, TOKEN):
        assert f"::add-mask::{value}" in proc.stdout
    printed = proc.stdout.replace("::add-mask::", "MASK ")
    assert "exported CLOUDFLARE_API_TOKEN" in printed
    assert "3 value(s)" in printed
    # Each path read once.
    assert sum(1 for s in Fake.seen if s == "GET /v1/kv/data/app/providers") == 1
    for value in ("cf-secret", "pass-secret"):
        assert value not in proc.stderr


def test_export_token(server, tmp_path):
    proc, env_text = run(server, tmp_path, "", export_token="true")
    assert proc.returncode == 0, proc.stderr
    env = parse_env(env_text)
    assert env["VAULT_TOKEN"] == TOKEN
    assert env["VAULT_ADDR"] == server


def test_retries_a_waking_vault(server, tmp_path):
    Fake.failures_left = 2
    proc, env_text = run(server, tmp_path, "kv/data/app/state passphrase | P")
    assert proc.returncode == 0, proc.stderr
    assert parse_env(env_text) == {"P": "pass-secret"}
    assert "retrying" in proc.stderr


def test_gives_up_after_four_tries(server, tmp_path):
    Fake.failures_left = 10
    proc, _ = run(server, tmp_path, "")
    assert proc.returncode == 1
    assert "login" in proc.stderr and "503" in proc.stderr


def test_tofu_variable_names_keep_their_case(server, tmp_path):
    """TF_VAR_<name> carries the variable's own lower-case name (the state passphrase of every stack)."""
    proc, env_text = run(server, tmp_path, "kv/data/app/providers cloudflare_api_token | TF_VAR_state_passphrase")
    assert proc.returncode == 0, proc.stderr
    assert parse_env(env_text) == {"TF_VAR_state_passphrase": "cf-secret"}


@pytest.mark.parametrize("secrets, message", [
    ("kv/data/app/providers missing | X", "has no value for 'missing'"),
    ("kv/data/app/nothing key | X", "cannot read kv/data/app/nothing (HTTP 404"),
    ("kv/data/app/providers cloudflare_api_token CLOUDFLARE", "bad line"),
    ("kv/data/app/providers cloudflare_api_token | BAD-NAME", "bad variable name"),
    ("kv/data/app/providers cloudflare_api_token | 1X", "bad variable name"),
    ("kv/data/../sys key | X", "bad path"),
])
def test_bad_input_fails_without_values(server, tmp_path, secrets, message):
    proc, _ = run(server, tmp_path, secrets)
    assert proc.returncode == 1
    assert message in proc.stderr
    assert "cf-secret" not in proc.stderr + proc.stdout


def test_wrong_role(server, tmp_path):
    proc, _ = run(server, tmp_path, "", role="other")
    assert proc.returncode == 1
    assert "login as role 'other'" in proc.stderr and "role not found" in proc.stderr
    # A 4xx is not retried.
    assert sum(1 for s in Fake.seen if s.startswith("POST")) == 1


def test_requires_https(server, tmp_path):
    env = {"PATH": os.environ["PATH"], "GITHUB_ENV": str(tmp_path / "e"), "VE_ADDR": "http://vault",
           "VE_ROLE": "r", "ACTIONS_ID_TOKEN_REQUEST_URL": "x"}
    proc = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    assert proc.returncode == 1
    assert "https://" in proc.stderr
