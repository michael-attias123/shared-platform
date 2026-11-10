"""Tests for changes.py: each path wakes only its own areas."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import changes  # noqa: E402

CONFIG = """
all = [".github/workflows/ci.yml", ".platform/"]

[areas]
web = ["web/"]
database = ["supabase/migrations/", "ingest/"]
functions = ["supabase/functions/"]
"""


@pytest.fixture
def config(tmp_path):
    path = tmp_path / "changes.toml"
    path.write_text(CONFIG, encoding="utf-8")
    return changes.load(str(path))


def only(config, *areas):
    return {a: a in areas for a in config.areas}


@pytest.mark.parametrize("files, expected", [
    (["web/src/app/Layout.tsx"], ("web",)),
    (["supabase/migrations/2026_x.sql"], ("database",)),
    (["ingest/house_ingest/parse.py"], ("database",)),
    (["supabase/functions/send-push/index.ts"], ("functions",)),
    (["README.md", ".github/workflows/infra.yml"], ()),
    (["web/a.ts", "supabase/functions/x.ts"], ("web", "functions")),
    ([".github/workflows/ci.yml"], ("web", "database", "functions")),
    ([".platform/changes.toml"], ("web", "database", "functions")),
    ([], ()),
])
def test_areas(config, files, expected):
    assert changes.areas_for(config, files) == only(config, *expected)


def test_unknown_runs_everything(config):
    assert changes.areas_for(config, None) == only(config, *config.areas)
    assert changes.changed_files("workflow_dispatch", "main", "") is None
    assert changes.changed_files("pull_request", "feature", "") is None
    assert changes.changed_files("push", "main", "0" * 40) is None
    assert changes.changed_files("push", "main", "f" * 40) is None  # not a commit here


def test_no_all_key(tmp_path):
    path = tmp_path / "c.toml"
    path.write_text('[areas]\nweb = ["web/"]\n', encoding="utf-8")
    cfg = changes.load(str(path))
    assert changes.areas_for(cfg, [".github/workflows/ci.yml"]) == {"web": False}


@pytest.mark.parametrize("text", [
    "",
    "[areas]\n",
    '[areas]\nweb = "web/"\n',
    '[areas]\nweb = [""]\n',
    'all = "x"\n[areas]\nweb = ["web/"]\n',
])
def test_bad_config(tmp_path, text):
    path = tmp_path / "c.toml"
    path.write_text(text, encoding="utf-8")
    with pytest.raises(ValueError):
        changes.load(str(path))


def test_main_prints_outputs(tmp_path, capsys, monkeypatch):
    path = tmp_path / "c.toml"
    path.write_text(CONFIG, encoding="utf-8")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "workflow_dispatch")
    assert changes.main(["--config", str(path)]) == 0
    assert capsys.readouterr().out.splitlines() == ["web=true", "database=true", "functions=true"]


def test_main_bad_config(tmp_path):
    assert changes.main(["--config", str(tmp_path / "missing.toml")]) == 1
