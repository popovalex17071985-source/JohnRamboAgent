"""Tests for scripts/update-plan.py -- the /update planner.

Every test builds a real "origin" git repo, clones it into an agent layout
(<ws>/.claude/dashi-plugin-claude-code), lays the kit out with the REAL
agent-kit/install-kit.sh, then moves origin forward and fetches -- exactly the
state the plugin is in when the owner types /update.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "update-plan.py"
INSTALL_KIT = REPO_ROOT / "agent-kit" / "install-kit.sh"


def load_planner():
    spec = importlib.util.spec_from_file_location("update_plan", SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # dataclasses look the module up by name
    spec.loader.exec_module(mod)
    return mod


up = load_planner()

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
        return json.loads(self.run_raw(*args))

    def run_raw(self, *args: str) -> str:
        res = subprocess.run(
            ["python3", str(SCRIPT), "--repo", str(self.repo), "--claude-dir", str(self.cd),
             "--agent", "smoke", "--chat-id", "42", "--settings", str(self.settings),
             "--tz", "UTC", *args],
            capture_output=True, text=True, env=self.env())
        if res.returncode != 0:
            raise AssertionError(f"update-plan.py {args} exit {res.returncode}: {res.stderr}")
        return res.stdout

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
        for raw in ("/update всё", "/update 1", "пропусти", "my tweak", "c.py", "<code>"):
            self.assertNotIn(raw, text)
        self.assertIn("отчёт о сервере стал короче", text)  # what the update does to his part
        self.assertNotIn("Напоминание о времени", text)     # the rest: one summary line
        self.assertEqual([a for a, _ in out["buttons"]], ["keep", "all", "no"])

        saved = json.loads((self.fx.ws / "state" / "update-plan.json").read_text())
        self.assertEqual(saved["fetch_head"], git(self.fx.repo, "rev-parse", "FETCH_HEAD"))
        self.assertEqual(out["fetch_head"], saved["fetch_head"])
        self.assertEqual(sorted(saved["items"]), ["1", "2", "3"])

    def test_every_item_tweaked_offers_no_keep_button(self) -> None:
        self.fx.write_origin("agent-kit/bin/c.py", "print('c2', '__CHAT_ID__')\n")
        self.fx.commit("health: shorter report")
        with (self.fx.ws / "bin" / "c.py").open("a") as f:
            f.write("# my tweak\n")
        self.fx.fetch()
        out = self.fx.run("plan")
        self.assertEqual([a for a, _ in out["buttons"]], ["all", "no"])

    def test_plan_without_tweaks_has_no_buttons(self) -> None:
        self.fx.standard_update()
        (self.fx.ws / "bin" / "c.py").write_text("print('c1', '42')\n")  # tweak undone
        self.assertEqual(self.fx.run("plan")["buttons"], [])

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


    def test_shallow_fetch_far_behind_is_deepened_before_planning(self) -> None:
        # The plugin fetches with --depth: an agent further behind than that has
        # HEAD outside the fetched history, and HEAD..FETCH_HEAD gets cut short.
        for i in range(8):
            self.fx.write_origin("plugin/src.ts", f"export const v = {i + 10}\n")
            self.fx.commit(f"правка {i}\n\nХозяину: Правка номер {i}\n")
        git(self.fx.repo, "fetch", "-q", "--depth", "3", "origin", "main")
        self.assertEqual(git(self.fx.repo, "rev-parse", "--is-shallow-repository"), "true")
        out = self.fx.run("plan")
        self.assertEqual([i["kind"] for i in out["items"]], ["bridge"])
        self.assertEqual(out["items"][0]["notes"], [f"Правка номер {i}" for i in range(8)])
        self.assertEqual(out["items"][0]["hidden"], 0)
        saved = json.loads((self.fx.ws / "state" / "update-plan.json").read_text())
        self.assertEqual(len(saved["items"]["1"]["commits"]), 8)
        self.assertEqual(saved["fetch_head"], git(self.fx.origin, "rev-parse", "HEAD"))


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

    def test_apply_one_kit_item_without_bridge_keeps_head(self) -> None:
        shas = self.fx.standard_update()
        head = self.fx.head()
        self.fx.run("plan")
        out = self.fx.run("apply", "2")
        self.assertEqual(out["status"], "UPDATED")
        self.assertFalse(out["restart"])
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())
        self.assertEqual(self.fx.installed("hooks/a.sh"), "#!/bin/sh\necho a2 smoke\n")
        self.assertIn("# my tweak", self.fx.installed("bin/c.py"))
        applied = json.loads((self.fx.ws / "state" / "update-applied.json").read_text())
        blob = git(self.fx.repo, "rev-parse", f"{shas['a']}:agent-kit/hooks/a.sh")
        self.assertEqual(applied["agent-kit/hooks/a.sh"], blob)
        # next plan: a.sh is done, the rest is still offered
        again = self.fx.run("plan")
        self.assertEqual([i["kind"] for i in again["items"]], ["bridge", "kit"])
        self.assertTrue(again["items"][1]["target"].endswith("/bin/c.py"))

    def test_apply_tweaked_kit_item_backs_up_owner_file(self) -> None:
        self.fx.standard_update()
        self.fx.run("plan")
        self.fx.run("apply", "3")
        self.assertEqual(self.fx.installed("bin/c.py"), "print('c2', '42')\n")
        backups = list((self.fx.ws / ".kit-backup").glob("*/bin/c.py"))
        self.assertEqual(len(backups), 1)
        self.assertIn("# my tweak", backups[0].read_text())

    def test_rollback_when_bun_install_fails(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        a_before = self.fx.installed("hooks/a.sh")
        self.fx.set_bun(1)
        self.fx.run("plan")
        out = self.fx.run("apply", "all")
        self.assertEqual(out["status"], "ROLLBACK")
        self.assertFalse(out["restart"])
        self.assertIn("откатил", out["text_html"])
        self.assertEqual(self.fx.head(), head)
        self.assertEqual((self.fx.repo / "plugin" / "src.ts").read_text(), "export const v = 1\n")
        self.assertFalse(self.fx.repo.with_name(self.fx.repo.name + ".bak").exists())
        # kit files are not touched by a failed update
        self.assertEqual(self.fx.installed("hooks/a.sh"), a_before)

    def test_rollback_leaves_no_aside_copy(self) -> None:
        self.fx.standard_update()
        self.fx.set_bun(1)
        self.fx.run("plan")
        self.assertEqual(self.fx.run("apply", "all")["status"], "ROLLBACK")
        names = sorted(p.name for p in self.fx.cd.iterdir() if p.name.startswith(self.fx.repo.name))
        self.assertEqual(names, [self.fx.repo.name])

    @unittest.skipIf(os.geteuid() == 0, "root can delete a read-only folder")
    def test_rollback_restores_repo_even_if_broken_copy_cannot_be_deleted(self) -> None:
        # The failed half-update leaves something this user cannot delete. The
        # old order (delete repo, then rename the copy back) died halfway and
        # left neither; the repo must come back first, the broken copy aside.
        self.fx.standard_update()
        head = self.fx.head()
        self.fx.bun.write_text("#!/bin/sh\nmkdir -p locked && touch locked/f && chmod 500 locked\nexit 1\n")
        self.fx.run("plan")
        try:
            out = self.fx.run("apply", "all")
        finally:
            for locked in self.fx.cd.glob("*/plugin/locked"):
                locked.chmod(0o700)
        self.assertEqual(out["status"], "ROLLBACK")
        self.assertEqual(self.fx.head(), head)
        self.assertEqual((self.fx.repo / "plugin" / "src.ts").read_text(), "export const v = 1\n")
        self.assertFalse((self.fx.repo / "plugin" / "locked").exists())
        aside = [p.name for p in self.fx.cd.glob(self.fx.repo.name + ".failed-*")]
        self.assertEqual(len(aside), 1, aside)

    @unittest.skipIf(os.geteuid() == 0, "root can delete a read-only folder")
    def test_backup_failure_touches_nothing(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        # a stale .bak that this user cannot remove (left by an older root run)
        stuck = self.fx.repo.with_name(self.fx.repo.name + ".bak") / "locked"
        stuck.mkdir(parents=True)
        (stuck / "f").write_text("x")
        stuck.chmod(0o500)
        try:
            self.fx.run("plan")
            out = self.fx.run("apply", "all")
        finally:
            stuck.chmod(0o700)
        self.assertEqual(out["status"], "ROLLBACK")
        self.assertIn("копию", out["text_html"])
        self.assertFalse(out["restart"])
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())


class AutoTest(unittest.TestCase):
    """Bare /update = `auto`: show the plan; repeated while fresh = install it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_first_update_only_shows_the_plan(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        out = self.fx.run("auto")
        self.assertEqual(out["status"], "PLAN")
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())
        self.assertIn("a1", self.fx.installed("hooks/a.sh"))

    def test_repeated_update_with_tweaks_asks_again_installs_nothing(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        self.fx.run("auto")
        again = self.fx.run("auto")
        self.assertEqual(again["status"], "PLAN")
        self.assertEqual([a for a, _ in again["buttons"]], ["keep", "all", "no"])
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())

    def test_keep_button_installs_all_but_owner_tweaks(self) -> None:
        self.fx.standard_update()
        fetch_head = git(self.fx.repo, "rev-parse", "FETCH_HEAD")
        plan = self.fx.run("auto")
        out = self.fx.run("--expect", plan["fetch_head"][:12], "apply", "keep")
        self.assertEqual(out["status"], "UPDATED")
        self.assertTrue(out["restart"])
        self.assertEqual(self.fx.head(), fetch_head)
        self.assertIn("a2", self.fx.installed("hooks/a.sh"))
        self.assertIn("# my tweak", self.fx.installed("bin/c.py"))  # tweak kept

    def test_update_without_tweaks_installs_everything_at_once(self) -> None:
        self.fx.standard_update()
        (self.fx.ws / "bin" / "c.py").write_text("print('c1', '42')\n")
        out = self.fx.run("auto")
        self.assertEqual(out["status"], "UPDATED")
        self.assertTrue(out["restart"])
        self.assertEqual(out.get("buttons", []), [])
        self.assertEqual(self.fx.installed("bin/c.py"), "print('c2', '42')\n")
        self.assertEqual(self.fx.head(), git(self.fx.repo, "rev-parse", "FETCH_HEAD"))
        text = out["text_html"]
        self.assertTrue(text.startswith("Обновил. Что нового:"), text)
        self.assertIn("Карточка «работаю» закрывается сама", text)
        self.assertIn("связь моргнёт", text)
        for raw in ("<code>", "c.py", "a.sh", "п."):
            self.assertNotIn(raw, text)

    def test_stale_plan_is_shown_again_not_applied(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        self.fx.run("auto")
        self.fx.write_origin("plugin/src.ts", "export const v = 3\n")
        self.fx.commit("ещё правка")
        self.fx.fetch()
        self.assertEqual(self.fx.run("auto")["status"], "PLAN")
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())

    def test_applied_plan_is_not_applied_twice(self) -> None:
        self.fx.standard_update()
        self.fx.run("plan")
        self.fx.run("apply", "2")            # kit only: HEAD and FETCH_HEAD stay
        out = self.fx.run("auto")
        self.assertEqual(out["status"], "PLAN")
        self.assertEqual([i["n"] for i in out["items"]], [1, 2])


class LocalCommitsTest(unittest.TestCase):
    """HEAD carries a local commit that the shared version does not have
    (Albert, 09.10.2026: feat/group-listen-all on a shallow clone)."""

    SUBJECT = "Группа с listen_all: слушать все сообщения"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))
        git(self.fx.repo, "checkout", "-q", "-b", "feat/group-listen-all")
        (self.fx.repo / "plugin" / "local.ts").write_text("export const listenAll = true\n")
        git(self.fx.repo, "add", "-A")
        git(self.fx.repo, "commit", "-q", "-m", self.SUBJECT)
        self.local = self.fx.head()
        self.fx.standard_update()
        git(self.fx.repo, "fetch", "-q", "--depth", "2", "origin", "main")  # shallow, as live

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_plan_warns_that_the_bridge_would_remove_local_work(self) -> None:
        out = self.fx.run("plan")
        bridge = out["items"][0]
        self.assertEqual(bridge["kind"], "bridge")
        self.assertTrue(bridge["tweak"])
        self.assertEqual([t["n"] for t in out["tweaks"] if t.get("kind") == "local"], [1])
        self.assertIn(f"«{self.SUBJECT}»", out["text_html"])
        self.assertNotIn("/update", out["text_html"])
        self.assertEqual([a for a, _ in out["buttons"]], ["keep", "all", "no"])

    def test_keep_button_keeps_local_work(self) -> None:
        self.fx.run("auto")
        out = self.fx.run("apply", "keep")
        self.assertEqual(out["status"], "UPDATED")
        self.assertFalse(out["restart"])
        self.assertEqual(self.fx.head(), self.local)          # bridge not applied
        self.assertIn("a2", self.fx.installed("hooks/a.sh"))  # kit item still went

    def test_update_all_saves_local_work_before_reset(self) -> None:
        self.fx.run("plan")
        out = self.fx.run("apply", "all")
        self.assertEqual(out["status"], "UPDATED")
        self.assertEqual(self.fx.head(), git(self.fx.repo, "rev-parse", "FETCH_HEAD"))
        refs = git(self.fx.repo, "for-each-ref", "--format=%(refname) %(objectname)",
                   "refs/dashi-backup/").splitlines()
        self.assertEqual(len(refs), 1)
        self.assertTrue(refs[0].endswith(self.local))
        patches = list((self.fx.ws / ".kit-backup").glob("*/local-commits.patch"))
        self.assertEqual(len(patches), 1)
        self.assertIn("+export const listenAll = true", patches[0].read_text())  # the diff itself
        text = out["text_html"]
        self.assertIn("доработку сохранил", text)
        self.assertNotIn("local-commits.patch", text)  # the owner gets words...
        log = (self.fx.ws / "logs" / "update.log").read_text()
        self.assertIn("local-commits.patch", log)      # ...whoever repairs gets the paths
        self.assertIn(refs[0].split()[0], log)


class StaleTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_apply_and_skip_refuse_when_fetch_head_moved(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        self.fx.run("plan")
        self.fx.write_origin("plugin/src.ts", "export const v = 3\n")
        self.fx.commit("ещё правка")
        self.fx.fetch()
        for args in (("apply", "all"), ("skip", "2")):
            out = self.fx.run(*args)
            self.assertEqual(out["status"], "STALE", args)
            self.assertIn("Обновление уже поменялось", out["text_html"])
            self.assertIn("/update", out["text_html"])
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())
        self.assertFalse((self.fx.ws / "state" / "update-skipped.json").exists())

    def test_button_press_on_another_plan_is_refused(self) -> None:
        self.fx.standard_update()
        head = self.fx.head()
        plan = self.fx.run("plan")
        for args in (("--expect", "0" * 12, "apply", "all"), ("--expect", "0" * 12, "apply", "keep")):
            out = self.fx.run(*args)
            self.assertEqual(out["status"], "STALE")
            self.assertEqual(out["text_html"], "Обновление уже поменялось, нажмите /update ещё раз.")
        self.assertEqual(self.fx.head(), head)
        (self.fx.ws / "state" / "update-plan.json").unlink()   # plan missing
        out = self.fx.run("--expect", plan["fetch_head"][:12], "apply", "all")
        self.assertEqual(out["text_html"], "Обновление уже поменялось, нажмите /update ещё раз.")
        self.assertFalse(self.fx.bun_log.exists())

    def test_apply_without_a_plan_asks_for_update_first(self) -> None:
        self.fx.standard_update()
        out = self.fx.run("apply", "all")
        self.assertEqual(out["status"], "STALE")
        self.assertIn("Сначала", out["text_html"])


class SkipTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def targets(self, out: dict) -> list[str]:
        return [i.get("target", "bridge").rpartition("/")[2] for i in out["items"]]

    def test_skip_hides_item_and_new_upstream_change_brings_it_back(self) -> None:
        self.fx.standard_update()
        self.fx.run("plan")
        out = self.fx.run("skip", "2")
        self.assertEqual(out["status"], "SKIPPED")
        self.assertIn("правила поведения агента", out["text_html"])
        self.assertNotIn("a.sh", out["text_html"])
        plan = self.fx.run("plan")
        self.assertEqual(self.targets(plan), ["bridge", "c.py"])
        self.assertNotIn("/update пропущенные", plan["text_html"])  # power users only
        listed = self.fx.run("skipped")
        self.assertIn("правила поведения агента", listed["text_html"])
        self.assertNotIn("a.sh", listed["text_html"])
        # a bridge apply must not lay the skipped file out either
        self.fx.run("apply", "1")
        self.assertIn("a1", self.fx.installed("hooks/a.sh"))
        # upstream changes the same file again -> offered again, new version
        self.fx.write_origin("agent-kit/hooks/a.sh", "#!/bin/sh\necho a3 __AGENT__\n")
        self.fx.commit("a.sh снова")
        self.fx.fetch()
        plan = self.fx.run("plan")
        self.assertIn("a.sh", self.targets(plan))

    def test_skip_bridge_then_unskip(self) -> None:
        self.fx.standard_update()
        self.fx.run("plan")
        self.fx.run("skip", "1")
        plan = self.fx.run("plan")
        self.assertNotIn("bridge", [i["kind"] for i in plan["items"]])
        out = self.fx.run("unskip", "all")
        self.assertEqual(out["status"], "UNSKIPPED")
        plan = self.fx.run("plan")
        self.assertEqual(plan["items"][0]["kind"], "bridge")


class NotifyTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_notify_plain_once_per_plan_and_without_skipped(self) -> None:
        self.fx.standard_update()
        text = self.fx.run_raw("notify")
        self.assertIn("Карточка «работаю» закрывается сама", text)
        self.assertIn("Напоминание о времени теперь по часам хозяина", text)
        self.assertIn("/update", text)
        self.assertNotIn("Заметки для хозяина", text)
        self.assertEqual(self.fx.run_raw("notify"), text)   # not marked until sent
        self.assertEqual(self.fx.run_raw("notify", "--sent"), "")
        self.assertEqual(self.fx.run_raw("notify"), "")      # same plan -> silence
        # the owner skips a.sh -> the plan changed, a.sh is no longer mentioned
        self.fx.run("plan")
        self.fx.run("skip", "2")
        text = self.fx.run_raw("notify")
        self.assertNotIn("Напоминание о времени", text)
        self.assertIn("Отчёт о сервере стал короче", text)

    def test_unannotated_bridge_commit_is_never_silent(self) -> None:
        # No trailer, no update-notes.json entry: the owner must still hear.
        # Only an explicit "-" hides a commit.
        self.fx.write_origin("plugin/src.ts", "export const v = 2\n")
        sha_plain = self.fx.commit("Очередь: гонка при двух сообщениях подряд")
        self.fx.write_origin("plugin/src.ts", "export const v = 3\n")
        git(self.fx.origin, "add", "-A")
        git(self.fx.origin, "commit", "-q", "--allow-empty-message", "-m", "")
        sha_empty = git(self.fx.origin, "rev-parse", "HEAD")
        self.fx.fetch()
        plan = self.fx.run("plan")
        self.assertEqual(plan["items"][0]["kind"], "bridge")
        for text in (self.fx.run_raw("notify"), plan["text_html"]):
            self.assertIn("Очередь: гонка при двух сообщениях подряд", text)
            self.assertIn("Мелкие исправления в работе агента", text)  # instead of a bare sha
            self.assertNotIn(sha_empty[:7], text)
            self.assertNotIn(sha_plain[:7], text)
            self.assertIn("/update", text)

    def test_notify_silent_when_only_hidden_changes(self) -> None:
        self.fx.write_origin("tests/x.txt", "x\n")
        self.fx.commit("tests: fixture\n\nХозяину: -\n")
        self.fx.fetch()
        self.assertEqual(self.fx.run_raw("notify"), "")

LOCAL_SUBJECT = "Группа с listen_all: агент берёт каждое сообщение без @-тега"
BRIDGE_NOTES = [
    "Резервная копия может забирать и дополнительные папки вне рабочей папки агента — в тот же архив",
    "Шкала заполнения разговора в закреплённом сообщении считается до точки автосжатия, а не до полного предела",
    "В закреплённом сообщении видно, сколько осталось лимита подписки на 5 часов и на неделю",
    "Долгая память на ключе OpenAI: перед сжатием разговора всё нужное теперь сохраняется",
    "Агент больше не замазывает звёздочками обычные имена файлов и настроек в сообщениях",
    "Карточка «работаю…» появляется только в том чате, откуда пришло сообщение",
    "Перед долгой паузой агент сам сжимает разговор — следующий ответ будет быстрее и дешевле",
]
API_NOTE = "Сторож внешних сервисов не тревожит из-за резервной копии, которая дошла со второй попытки"
AUTH_NOTE = "Сторож входа больше не пугает «слетел вход», когда просто кончился лимит подписки"
HEALTH_NOTE = ("Утренняя самопроверка смотрит размер текущего разговора, а не самого большого "
               "старого — меньше ложных тревог")
NOTIFY_NOTES = [
    "Если проверка обновлений не может достучаться до хранилища кода, агент сам напишет вам "
    "об этом, а не будет молчать",
    "Если ключ к закрытому хранилищу кода протух, еженедельный советник напишет вам, "
    "а не остановит обновления молча",
]


def kit_item(n: int, name: str, notes: list[str], tweak: bool = False) -> dict:
    path = f"agent-kit/bin/{name}"
    return {"n": n, "kind": "kit", "path": path, "target": f"/home/a/ws/bin/{name}",
            "blob": "b" * 40, "title": up.kit_title(path), "notes": notes,
            "new_file": False, "tweak": tweak}


def real_plan(tweaks: bool = True) -> "up.Plan":
    """The plan the test agent got on 09.10.2026 (5 items)."""
    items = [
        {"n": 1, "kind": "bridge", "title": "Основное обновление агента",
         "notes": list(BRIDGE_NOTES), "hidden": 4, "earlier_skipped": 0,
         "commits": ["c" * 40], "local": 1 if tweaks else 0, "tweak": tweaks},
        kit_item(2, "api-fail-watch.py", [API_NOTE]),
        kit_item(3, "auth-alive-watch.sh", [AUTH_NOTE]),
        kit_item(4, "health-check.sh", [HEALTH_NOTE], tweak=tweaks),
        kit_item(5, "update-notify.sh", list(NOTIFY_NOTES)),
    ]
    tw = []
    if tweaks:
        tw = [{"n": 1, "kind": "local", "target": "abc1234", "subject": LOCAL_SUBJECT,
               "added": 0, "removed": 0, "deleted": False, "lines": []},
              {"n": 4, "target": "bin/health-check.sh", "added": 3, "removed": 1,
               "deleted": False, "lines": ["+ MAX=900", "- MAX=300"]}]
    return up.Plan("f" * 40, "h" * 40, items, tw, [], {}, 0, 0)


RAW_MARKERS = ("<code>", ".py", ".sh", ".md", "/update всё", "/update 1", "пропусти",
               "строк", "п.", "bin/", "hooks/")


class PlainTextTest(unittest.TestCase):
    """What a shop owner reads: no file names, no diffs, no typed commands."""

    def assert_plain(self, text: str) -> None:
        for marker in RAW_MARKERS:
            self.assertNotIn(marker, text, f"{marker!r} leaked into:\n{text}")

    def test_plain_names_for_kit_files(self) -> None:
        self.assertEqual(up.plain_name("agent-kit/bin/health-check.sh"), "утренняя самопроверка")
        self.assertEqual(up.plain_name("agent-kit/bin/update-notify.sh"),
                         "сообщения об обновлениях")
        self.assertEqual(up.plain_name("agent-kit/bin/auth-alive-watch.sh"), "сторож входа")
        self.assertEqual(up.plain_name("agent-kit/bin/api-fail-watch.py"),
                         "сторож внешних сервисов")
        self.assertEqual(up.plain_name("agent-kit/hooks/tz-guard.sh"), "правила поведения агента")
        self.assertEqual(up.plain_name("agent-kit/core/constitution.md"), "основные правила агента")
        self.assertEqual(up.plain_name("agent-kit/bin/never-heard-of.sh"), "служебная часть")

    def test_tweak_plan_explains_only_the_owners_own_parts(self) -> None:
        text = up.plan_text(real_plan())
        self.assert_plain(text)
        self.assertIn("утренняя самопроверка", text.lower())
        self.assertIn(HEALTH_NOTE.split(" — ")[0].lower()[len("утренняя самопроверка "):], text)
        self.assertIn(f"«{LOCAL_SUBJECT}»", text)
        self.assertIn("копию сохраню", text)
        # the other notes are NOT listed -- one summary line instead
        for note in [*BRIDGE_NOTES, API_NOTE, AUTH_NOTE, *NOTIFY_NOTES]:
            self.assertNotIn(note, text)
        self.assertIn("Остальное", text)

    def test_buttons_depend_on_tweaks(self) -> None:
        self.assertEqual([a for a, _ in up.plan_buttons(real_plan())], ["keep", "all", "no"])
        labels = dict(up.plan_buttons(real_plan()))
        self.assertEqual(labels["keep"], "Обновить, своё не трогать")
        self.assertEqual(labels["all"], "Обновить всё, даже своё (копию сохраню)")
        self.assertEqual(labels["no"], "Не сейчас")
        self.assertEqual(up.plan_buttons(real_plan(tweaks=False)), [])
        # every item is the owner's: «своё не трогать» would install nothing
        only_tweaked = real_plan()
        only_tweaked.items = [i for i in only_tweaked.items if i["tweak"]]
        self.assertEqual([a for a, _ in up.plan_buttons(only_tweaked)], ["all", "no"])

    def test_result_after_installing_everything(self) -> None:
        plan = real_plan(tweaks=False)
        text = up.result_text(plan.items, [], restart=True)
        self.assert_plain(text)
        self.assertTrue(text.startswith("Обновил. Что нового:"))
        self.assertEqual(text.count("• "), 4)
        self.assertIn("и ещё 8 мелочей", text)
        self.assertIn("связь моргнёт", text)

    def test_result_after_keep_names_what_was_left(self) -> None:
        plan = real_plan()
        chosen = [i for i in plan.items if not i["tweak"]]
        left = [i for i in plan.items if i["tweak"]]
        text = up.result_text(chosen, left, restart=False, local=[LOCAL_SUBJECT])
        self.assert_plain(text)
        self.assertIn("утренняя самопроверка", text)
        self.assertIn(f"«{LOCAL_SUBJECT}»", text)
        self.assertNotIn("связь моргнёт", text)

    def test_notify_is_a_short_heads_up(self) -> None:
        text = up.notify_text(real_plan(tweaks=False))
        self.assert_plain(text)
        self.assertTrue(text.startswith("Вышло обновление"))
        self.assertEqual(text.count("• "), 3)
        self.assertIn("Нажмите /update", text)
        self.assertNotIn("у вас своё", text)
        self.assertIn("Есть место, где у вас своё — при /update объясню",
                      up.notify_text(real_plan()))


if __name__ == "__main__":
    unittest.main()
