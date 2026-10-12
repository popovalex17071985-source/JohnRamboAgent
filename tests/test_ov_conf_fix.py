"""OpenViking v0.5.0 in the installers: data dir pinned in ov.conf, image pinned.

Since v0.4.21 the image runs in /app/.openviking, so ov.conf without an absolute
storage.workspace puts the store outside the appdata volume and memory
«disappears» after the container is recreated (Smith/Jarvis, 28.09-12.10.2026).
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "agent-kit" / "scripts" / "ov-conf-fix.py"
SETUP_MEMORY = REPO_ROOT / "agent-kit" / "scripts" / "setup-memory.sh"
INSTALL_AGENT = REPO_ROOT / "scripts" / "install-agent.sh"
RESTORE_AGENT = REPO_ROOT / "scripts" / "restore-agent.sh"
V050_DIGEST = "sha256:c60a83cd79cfce80db5266acb8bdd0908eee8abe8ff559a5f786aa504c251ccf"
BASE_CONF = {"embedding": {"dense": {"provider": "openai", "dimension": 384}},
             "server": {"host": "127.0.0.1"}}


def _helper():
    spec = importlib.util.spec_from_file_location("ov_conf_fix", HELPER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _store(path: Path) -> None:
    (path / "viking" / "default").mkdir(parents=True)


class EnsureWorkspaceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.ov = Path(self.tmp.name)
        (self.ov / "appdata").mkdir()
        self.conf = self.ov / "ov.conf"
        self.mod = _helper()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _write(self, cfg: dict) -> None:
        self.conf.write_text(json.dumps(cfg))
        os.chmod(self.conf, 0o600)

    def _ws(self) -> str:
        return json.loads(self.conf.read_text())["storage"]["workspace"]

    def test_old_conf_gets_appdata_and_keeps_rest(self) -> None:
        self._write(BASE_CONF)
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("set", "/app/data"))
        cfg = json.loads(self.conf.read_text())
        self.assertEqual(cfg["storage"]["workspace"], "/app/data")
        self.assertEqual(cfg["embedding"], BASE_CONF["embedding"])
        self.assertEqual(stat.S_IMODE(self.conf.stat().st_mode), 0o600)

    def test_idempotent(self) -> None:
        self._write(BASE_CONF)
        self.mod.ensure_workspace(self.ov)
        before = self.conf.read_text()
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("kept", "/app/data"))
        self.assertEqual(self.conf.read_text(), before)

    def test_explicit_absolute_is_never_touched(self) -> None:
        self._write({**BASE_CONF, "storage": {"workspace": "/srv/ov"}})
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("kept", "/srv/ov"))

    def test_relative_workspace_is_replaced(self) -> None:
        self._write({**BASE_CONF, "storage": {"workspace": "./data", "other": 1}})
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("set", "/app/data"))
        self.assertEqual(json.loads(self.conf.read_text())["storage"]["other"], 1)

    def test_store_only_in_legacy_dir_stays_there(self) -> None:
        # first started on >=0.4.21 without a pin: the whole store is in ~/.openviking/data
        _store(self.ov / "data")
        self._write(BASE_CONF)
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("set", "/app/.openviking/data"))

    def test_both_stores_prefer_appdata(self) -> None:
        _store(self.ov / "data")
        _store(self.ov / "appdata")
        self._write(BASE_CONF)
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("set", "/app/data"))

    def test_missing_conf_is_a_noop(self) -> None:
        self.assertEqual(self.mod.ensure_workspace(self.ov), ("missing", ""))
        self.assertFalse(self.conf.exists())

    def test_cli(self) -> None:
        self._write(BASE_CONF)
        r = subprocess.run([sys.executable, str(HELPER), str(self.ov)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("/app/data", r.stdout)
        self.assertEqual(self._ws(), "/app/data")


class PluginThresholdTest(unittest.TestCase):
    """Since v0.4.22 scores are (cos + 1) / 2: the plugin default 0.25 -> 0.625."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.ov = Path(self.tmp.name)
        self.cfg = self.ov / "claude-code-memory-plugin" / "config.json"
        self.cfg.parent.mkdir()
        self.mod = _helper()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _set(self, value: float) -> None:
        self.cfg.write_text(json.dumps({"agentId": "x", "scoreThreshold": value}))

    def _get(self) -> float:
        return json.loads(self.cfg.read_text())["scoreThreshold"]

    def test_new_server_moves_default_up_once(self) -> None:
        self._set(0.25)
        self.assertEqual(self.mod.align_plugin_threshold(self.ov, "v0.5.0"), (0.25, 0.625))
        self.assertIsNone(self.mod.align_plugin_threshold(self.ov, "v0.5.0"))
        self.assertEqual(self._get(), 0.625)

    def test_old_server_keeps_or_restores_raw_default(self) -> None:
        self._set(0.25)
        self.assertIsNone(self.mod.align_plugin_threshold(self.ov, "v0.4.16"))
        self._set(0.625)
        self.assertEqual(self.mod.align_plugin_threshold(self.ov, "v0.4.16"), (0.625, 0.25))

    def test_owner_value_and_unknown_version_untouched(self) -> None:
        self._set(0.3)
        self.assertIsNone(self.mod.align_plugin_threshold(self.ov, "v0.5.0"))
        self._set(0.25)
        self.assertIsNone(self.mod.align_plugin_threshold(self.ov, ""))
        self.assertIsNone(self.mod.align_plugin_threshold(self.ov, "dev"))
        self.assertEqual(self._get(), 0.25)

    def test_cli_with_version(self) -> None:
        self._set(0.25)
        r = subprocess.run([sys.executable, str(HELPER), str(self.ov), "--server-version", "v0.5.0"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._get(), 0.625)


class InstallersPinV050Test(unittest.TestCase):
    def test_setup_memory_generates_workspace_and_pins_image(self) -> None:
        text = SETUP_MEMORY.read_text()
        self.assertIn('"storage": {"workspace": "/app/data"}', text)
        self.assertIn(V050_DIGEST, text)
        self.assertNotIn("openviking:latest", text)
        self.assertIn("ov-conf-fix.py", text)

    def test_setup_memory_generator_output(self) -> None:
        # run the exact python heredoc setup-memory.sh uses to write ov.conf
        text = SETUP_MEMORY.read_text()
        m = re.search(r"<<'PY'\n(.*?)\nPY\n", text, re.S)
        self.assertIsNotNone(m)
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "ov.conf"
            env = {**os.environ, "EMBED_BASE": "http://127.0.0.1:1934/v1", "EMBED_DIM": "384",
                   "VLM_BASE": "", "VLM_MODEL": "", "VLM_KEY": ""}
            r = subprocess.run([sys.executable, "-", str(out)], input=m.group(1),
                               capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            cfg = json.loads(out.read_text())
        self.assertEqual(cfg["storage"]["workspace"], "/app/data")
        self.assertEqual(cfg["embedding"]["dense"]["dimension"], 384)

    def test_install_agent_pins_v050_and_keeps_workspace(self) -> None:
        text = INSTALL_AGENT.read_text()
        self.assertIn(f'OPENVIKING_IMAGE="ghcr.io/volcengine/openviking@{V050_DIGEST}"', text)
        self.assertIn('"storage": { "workspace": "$OV_WS" }', text)
        self.assertIn("OV_WS=/app/data", text)
        self.assertIn('"scoreThreshold": 0.625', text)
        self.assertIn("agent-kit/scripts/ov-conf-fix.py", text)

    def test_restore_pins_workspace_before_start(self) -> None:
        text = RESTORE_AGENT.read_text()
        fix = text.index("ov-conf-fix.py")
        start = text.index("docker start openviking")
        self.assertLess(fix, start)


if __name__ == "__main__":
    unittest.main()
