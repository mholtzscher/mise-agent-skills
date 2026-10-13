"""Opt-in real Mise/skills CLI test; all state is isolated in a temporary home.

Run with: mise exec npm:skills@1.7.2 -- python3 tests/integration.py
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix="agent-skills-integration-") as temporary:
    root = Path(temporary)
    env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "home/.config"),
               XDG_DATA_HOME=str(root / "data"), XDG_STATE_HOME=str(root / "state"),
               MISE_DATA_DIR=str(root / "data/mise"), MISE_CONFIG_DIR=str(root / "home/.config/mise"),
               MISE_STATE_DIR=str(root / "state/mise"), MISE_CACHE_DIR=str(root / "cache"),
               MISE_HISTORY_SYNC="manual", MISE_YES="1", DISABLE_TELEMETRY="1")
    env.pop("MISE_CONFIG_FILE", None)

    def mise(*args):
        return subprocess.check_output(["mise", *args], cwd=root, env=env, text=True)

    def configure(version):
        (root / "mise.toml").write_text('[bootstrap.packages]\n"agent-skills:vercel-labs/agent-browser/agent-browser" = ' + json.dumps(version) + '\n')

    def lock():
        return json.loads((root / "state/skills/.skill-lock.json").read_text())["skills"]["agent-browser"]

    configure("latest")
    mise("plugins", "link", "agent-skills", str(Path(__file__).resolve().parents[1]))
    mise("trust")
    assert "missing" in mise("bootstrap", "packages", "status")
    mise("bootstrap", "packages", "install", "--dry-run")
    assert "missing" in mise("bootstrap", "packages", "status")
    mise("bootstrap", "packages", "install")
    assert "installed" in mise("bootstrap", "packages", "status")
    before = lock()["updatedAt"]
    manifest = root / "home/.agents/skills/agent-browser/SKILL.md"
    manifest.rename(manifest.with_name("SKILL.original.md"))
    manifest.symlink_to("SKILL.original.md")
    assert "installed" in mise("bootstrap", "packages", "status")
    mise("bootstrap", "packages", "install")
    assert lock()["updatedAt"] == before
    assert manifest.is_symlink()
    manifest.unlink()
    manifest.with_name("SKILL.original.md").rename(manifest)
    mise("bootstrap", "packages", "upgrade")
    assert lock()["updatedAt"] != before
    commit = subprocess.check_output(["git", "ls-remote", "https://github.com/vercel-labs/agent-browser", "HEAD"], text=True).split()[0]
    configure(commit)
    mise("bootstrap", "packages", "install")
    assert lock()["ref"] == commit
    assert "installed" in mise("bootstrap", "packages", "status")
    (root / "mise.toml").write_text('''[bootstrap.packages]
"agent-skills:openai/codex/codex-rs/skills/src/assets/samples/skill-creator" = "latest"
"agent-skills:cursor/plugins/unslop" = "latest"
''')
    mise("bootstrap", "packages", "install")
    result = mise("bootstrap", "packages", "status")
    assert "missing" not in result and result.count("installed") == 2, result
    entries = json.loads((root / "state/skills/.skill-lock.json").read_text())["skills"]
    assert entries["skill-creator"]["skillPath"] == "codex-rs/skills/src/assets/samples/skill-creator/SKILL.md"
    assert entries["unslop"]["source"] == "cursor/plugins"
    # Only agent-browser is undeclared; its recorded installed version is a commit.
    mise("bootstrap", "packages", "prune", "--manager", "agent-skills", "--dry-run")
    assert manifest.exists() and lock()["ref"] == commit
    mise("bootstrap", "packages", "prune", "--manager", "agent-skills", "--yes")
    assert not manifest.parent.exists()
    entries = json.loads((root / "state/skills/.skill-lock.json").read_text())["skills"]
    assert "agent-browser" not in entries and "skill-creator" in entries and "unslop" in entries
    # Default-branch installs are recorded as folder hashes, not Git refs.
    (root / "mise.toml").write_text("[bootstrap.packages]\n")
    preview = mise("bootstrap", "packages", "prune", "--manager", "agent-skills", "--dry-run")
    assert (root / "home/.agents/skills/skill-creator").exists()
    assert (root / "home/.agents/skills/unslop").exists()
    mise("bootstrap", "packages", "prune", "--manager", "agent-skills", "--yes")
    entries = json.loads((root / "state/skills/.skill-lock.json").read_text())["skills"]
    assert "skill-creator" not in entries and "unslop" not in entries
    assert not (root / "home/.agents/skills/skill-creator").exists()
    assert not (root / "home/.agents/skills/unslop").exists()
    print("Real Lua hooks: install, dry-run, status, repeat install, upgrade, commit pin, nested sources, deep discovery and prune passed.")
