"""Tests for scripts/update-plan.py -- the /update planner.

Every test builds a real "origin" git repo, clones it into an agent layout
(<ws>/.claude/dashi-plugin-claude-code), lays the kit out with the REAL
agent-kit/install-kit.sh, then moves origin forward and fetches -- exactly the
state the plugin is in when the owner types /update.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "update-plan.py"
INSTALL_KIT = REPO_ROOT / "agent-kit" / "install-kit.sh"

GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
}

BASE_FILES = {
    "README.md": "readme\n",
    "plugin/package.json": '{"name": "fixture"}\n',
    "plugin/src.ts": "export const v = 1\n",
    "agent-kit/hooks/a.sh": "#!/bin/sh\necho a1 __AGENT__\n",
    "agent-kit/hooks/b.sh": "#!/bin/sh\necho b1 __WORKSPACE__\n",
    "agent-kit/bin/c.py": "print('c1', '__CHAT_ID__')\n",
    "agent-kit/agents/rev.md": "reviewer v1\n",
    "agent-kit/core/constitution.md": "rules v1 __CLAUDE_DIR__\n",
    "agent-kit/core/SOURCES.md": "sources\n",
    "agent-kit/core/open-threads.md": "threads\n",
    "agent-kit/docs/agent-self-audit.md": "audit\n",
}


def git(cwd: Path, *args: str) -> str:
    res = subprocess.run(["git", "-C", str(cwd), *args], check=True,
                         capture_output=True, text=True, env=GIT_ENV)
    return res.stdout.strip()


class Fixture:
    """origin repo + an agent that has the origin's first commit installed."""

    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        self.origin = tmp / "origin"
        self.ws = tmp / "ws"
        self.cd = self.ws / ".claude"
        self.repo = self.cd / "dashi-plugin-claude-code"
        self.settings = tmp / "settings.json"
        self.bun = tmp / "bun"
        self.bun_log = tmp / "bun.log"
        self.set_bun(0)

        self.origin.mkdir()
        git(self.origin, "init", "-q", "-b", "main")
        for rel, body in BASE_FILES.items():
            self.write_origin(rel, body)
        kit = self.origin / "agent-kit" / "install-kit.sh"
        shutil.copy(INSTALL_KIT, kit)
        self.commit("База")
        self.cd.mkdir(parents=True)
        git(self.ws, "clone", "-q", str(self.origin), str(self.repo))
        self.install()

    # -- origin side -------------------------------------------------------
    def write_origin(self, rel: str, body: str) -> None:
        path = self.origin / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)

    def commit(self, message: str) -> str:
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-q", "-m", message)
        return git(self.origin, "rev-parse", "HEAD")

    def fetch(self) -> str:
        git(self.repo, "fetch", "-q", "origin", "main")
        return git(self.repo, "rev-parse", "FETCH_HEAD")

    # -- agent side --------------------------------------------------------
    def env(self) -> dict[str, str]:
        return {**GIT_ENV, "KIT_NO_CRON": "1", "KIT_NO_MEMORY": "1",
                "DASHI_BUN": str(self.bun)}

    def install(self) -> None:
        subprocess.run(
            ["bash", str(self.repo / "agent-kit" / "install-kit.sh"),
             "--claude-dir", str(self.cd), "--chat-id", "42", "--agent", "smoke",
             "--settings", str(self.settings), "--tz", "UTC"],
            check=True, capture_output=True, env=self.env())

    def set_bun(self, code: int) -> None:
        self.bun.write_text(f"#!/bin/sh\necho \"$@\" >> '{self.bun_log}'\nexit {code}\n")
        self.bun.chmod(0o755)

    def head(self) -> str:
        return git(self.repo, "rev-parse", "HEAD")

    def run(self, *args: str) -> dict:
        res = subprocess.run(
            ["python3", str(SCRIPT), "--repo", str(self.repo), "--claude-dir", str(self.cd),
             "--agent", "smoke", "--chat-id", "42", "--settings", str(self.settings),
             "--tz", "UTC", *args],
            capture_output=True, text=True, env=self.env())
        if res.returncode != 0:
            raise AssertionError(f"update-plan.py {args} exit {res.returncode}: {res.stderr}")
        return json.loads(res.stdout)

    def installed(self, rel: str) -> str:
        """rel like 'hooks/a.sh' (under .claude) or 'bin/c.py' (under workspace)."""
        base = self.ws if rel.startswith("bin/") else self.cd
        return (base / rel).read_text()

    def standard_update(self) -> dict[str, str]:
        """Bridge commit + two kit changes + notes file; owner tweaked bin/c.py."""
        shas: dict[str, str] = {}
        self.write_origin("plugin/src.ts", "export const v = 2\n")
        shas["bridge"] = self.commit(
            "Мост: внутренняя правка карточки\n\n"
            "Хозяину: Карточка «работаю» закрывается сама, когда ответ ушёл\n")
        self.write_origin("agent-kit/hooks/a.sh", "#!/bin/sh\necho a2 __AGENT__\n")
        shas["a"] = self.commit("tz-guard: refactor of the clock helper")
        self.write_origin("agent-kit/bin/c.py", "print('c2', '__CHAT_ID__')\n")
        shas["c"] = self.commit("health: shorter report")
        self.write_origin("update-notes.json", json.dumps({
            shas["a"][:7]: "Напоминание о времени теперь по часам хозяина",
            shas["c"][:9]: "Отчёт о сервере стал короче",
        }, ensure_ascii=False))
        shas["notes"] = self.commit("Заметки для хозяина\n\nХозяину: -\n")
        with (self.ws / "bin" / "c.py").open("a") as f:
            f.write("# my tweak\n")
        self.fetch()
        return shas


class PlanTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_plan_bridge_two_kit_changes_and_owner_tweak(self) -> None:
        self.fx.standard_update()
        out = self.fx.run("plan")
        self.assertEqual(out["status"], "PLAN")
        items = out["items"]
        self.assertEqual([i["n"] for i in items], [1, 2, 3])
        bridge, a, c = items
        self.assertEqual(bridge["kind"], "bridge")
        self.assertIn("Карточка «работаю» закрывается сама, когда ответ ушёл", bridge["notes"])
        joined = " ".join(bridge["notes"])
        self.assertNotIn("Заметки для хозяина", joined)  # trailer "-" hides
        self.assertNotIn("внутренняя правка", joined)    # trailer beats subject
        self.assertEqual(a["kind"], "kit")
        self.assertTrue(a["target"].endswith("/.claude/hooks/a.sh"))
        self.assertEqual(a["notes"], ["Напоминание о времени теперь по часам хозяина"])
        self.assertFalse(a["tweak"])
        self.assertTrue(c["target"].endswith("/bin/c.py"))
        self.assertEqual(c["notes"], ["Отчёт о сервере стал короче"])
        self.assertTrue(c["tweak"])
        self.assertFalse(bridge["tweak"])
        # b.sh did not change upstream -> not offered
        self.assertFalse(any(i.get("target", "").endswith("b.sh") for i in items))

        self.assertEqual(len(out["tweaks"]), 1)
        tw = out["tweaks"][0]
        self.assertEqual(tw["n"], 3)
        self.assertIn("my tweak", " ".join(tw["lines"]))

        text = out["text_html"]
        for cmd in ("/update всё", "/update своё", "/update 1 3", "/update пропусти"):
            self.assertIn(cmd, text)
        self.assertIn("Отчёт о сервере стал короче", text)
        self.assertIn("my tweak", text)

        saved = json.loads((self.fx.ws / "state" / "update-plan.json").read_text())
        self.assertEqual(saved["fetch_head"], git(self.fx.repo, "rev-parse", "FETCH_HEAD"))
        self.assertEqual(out["fetch_head"], saved["fetch_head"])
        self.assertEqual(sorted(saved["items"]), ["1", "2", "3"])

    def test_repo_file_identical_to_fetch_head_is_not_a_tweak(self) -> None:
        self.fx.standard_update()
        # Owner (or a previous half-update) already has the upstream content.
        (self.fx.repo / "plugin" / "src.ts").write_text("export const v = 2\n")
        out = self.fx.run("plan")
        self.assertEqual(out["tweaks"][0]["n"], 3)
        self.assertEqual(len(out["tweaks"]), 1)
        self.assertFalse(out["items"][0]["tweak"])
        # A real local edit to a repo file IS a tweak of the bridge item.
        (self.fx.repo / "README.md").write_text("readme with my notes\n")
        out = self.fx.run("plan")
        self.assertTrue(out["items"][0]["tweak"])
        names = [t["target"] for t in out["tweaks"]]
        self.assertIn("README.md", names)
        self.assertNotIn("plugin/src.ts", names)

    def test_uptodate_when_nothing_pending(self) -> None:
        self.fx.fetch()
        out = self.fx.run("plan")
        self.assertEqual(out["status"], "UPTODATE")
        self.assertEqual(out["items"], [])



class ApplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_apply_keep_moves_head_and_leaves_tweaked_file(self) -> None:
        self.fx.standard_update()
        fetch_head = git(self.fx.repo, "rev-parse", "FETCH_HEAD")
        self.fx.run("plan")
        out = self.fx.run("apply", "keep")
        self.assertEqual(out["status"], "UPDATED")
        self.assertTrue(out["restart"])
        self.assertEqual(self.fx.head(), fetch_head)
        self.assertIn("install --silent", self.fx.bun_log.read_text())
        # the owner's tweak survived, the untweaked kit change landed
        self.assertIn("# my tweak", self.fx.installed("bin/c.py"))
        self.assertIn("c1", self.fx.installed("bin/c.py"))
        self.assertEqual(self.fx.installed("hooks/a.sh"), "#!/bin/sh\necho a2 smoke\n")
        # the kept item is offered again next time, still marked as the owner's
        again = self.fx.run("plan")
        self.assertEqual([i["kind"] for i in again["items"]], ["kit"])
        self.assertTrue(again["items"][0]["target"].endswith("/bin/c.py"))
        self.assertTrue(again["items"][0]["tweak"])


if __name__ == "__main__":
    unittest.main()
