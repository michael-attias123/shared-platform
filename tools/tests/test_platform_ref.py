"""platform_ref.sh rewrites only shared-platform sources pinned to main."""
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "platform_ref.sh"
URL = "git::https://github.com/michael-attias123/shared-platform.git"

MAIN_TF = f'''
module "secrets" {{
  source = "{URL}//modules/secrets-vault?ref=main"
}}
module "pinned" {{
  source = "{URL}//modules/x?ref=abc123"
}}
module "other" {{
  source = "git::https://github.com/someone/else.git//m?ref=main"
}}
module "local" {{
  source = "./modules/local"
}}
'''


def run(*args):
    return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True)


def test_rewrites_main_sources_only(tmp_path):
    (tmp_path / "main.tf").write_text(MAIN_TF)
    (tmp_path / ".terraform").mkdir()
    (tmp_path / ".terraform" / "cached.tf").write_text(MAIN_TF)
    proc = run("feature/x", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    text = (tmp_path / "main.tf").read_text()
    assert f'{URL}//modules/secrets-vault?ref=feature/x"' in text
    assert f'{URL}//modules/x?ref=abc123"' in text
    assert 'else.git//m?ref=main"' in text
    assert "now uses ref=feature/x" in proc.stdout
    assert (tmp_path / ".terraform" / "cached.tf").read_text() == MAIN_TF


def test_main_is_a_no_op(tmp_path):
    (tmp_path / "main.tf").write_text(MAIN_TF)
    assert run("main", str(tmp_path)).returncode == 0
    assert (tmp_path / "main.tf").read_text() == MAIN_TF


def test_bad_ref(tmp_path):
    proc = run("x;rm -rf /", str(tmp_path))
    assert proc.returncode == 1
    assert "bad ref" in proc.stderr
