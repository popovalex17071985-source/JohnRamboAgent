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
        for cmd in ("/update всё", "/update 1 3", "/update пропусти"):
            self.assertIn(cmd, text)
        self.assertIn("Отчёт о сервере стал короче", text)
        self.assertIn("my tweak", text)

        saved = json.loads((self.fx.ws / "state" / "update-plan.json").read_text())
        self.assertEqual(saved["fetch_head"], git(self.fx.repo, "rev-parse", "FETCH_HEAD"))
        self.assertEqual(out["fetch_head"], saved["fetch_head"])
        self.assertEqual(sorted(saved["items"]), ["1", "2", "3"])

    def answer_block(self, text: str) -> str:
        return text[text.index("<b>Как ответить</b>"):]

    def test_answer_hint_with_owner_tweak(self) -> None:
        self.fx.standard_update()  # item 3 carries the owner's tweak
        block = self.answer_block(self.fx.run("plan")["text_html"])
        self.assertEqual(block, "\n".join([
            "<b>Как ответить</b>",
            "<code>/update</code> ещё раз — поставить всё, кроме п.3 (там ваша правка)",
            "<code>/update всё</code> — и п.3 тоже (вашу правку перезапишу, копия останется)",
            "<code>/update 1 3</code> — только выбранные",
            "<code>/update пропусти 3</code> — не ставить и больше не предлагать",
        ]))
        self.assertNotIn("своё", self.fx.run("plan")["text_html"])

    def test_answer_hint_without_tweaks(self) -> None:
        self.fx.standard_update()
        (self.fx.ws / "bin" / "c.py").write_text("print('c1', '42')\n")  # tweak undone
        block = self.answer_block(self.fx.run("plan")["text_html"])
        self.assertEqual(block, "\n".join([
            "<b>Как ответить</b>",
            "<code>/update</code> ещё раз — поставить всё",
            "<code>/update 1 3</code> — только выбранные",
            "<code>/update пропусти 3</code> — не ставить и больше не предлагать",
        ]))

    def test_answer_hint_when_every_item_is_tweaked(self) -> None:
        self.fx.write_origin("agent-kit/bin/c.py", "print('c2', '__CHAT_ID__')\n")
        self.fx.commit("health: shorter report")
        with (self.fx.ws / "bin" / "c.py").open("a") as f:
            f.write("# my tweak\n")
        self.fx.fetch()
        block = self.answer_block(self.fx.run("plan")["text_html"])
        self.assertEqual(block, "\n".join([
            "<b>Как ответить</b>",
            "<code>/update всё</code> — поставить (вашу правку перезапишу, копия останется)",
            "<code>/update 1</code> — только выбранные",
            "<code>/update пропусти 1</code> — не ставить и больше не предлагать",
        ]))

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
            self.assertIn("вышло ещё обновление", out["text_html"])
            self.assertIn("/update", out["text_html"])
        self.assertEqual(self.fx.head(), head)
        self.assertFalse(self.fx.bun_log.exists())
        self.assertFalse((self.fx.ws / "state" / "update-skipped.json").exists())

    def test_apply_without_a_plan_asks_for_update_first(self) -> None:
        self.fx.standard_update()
        out = self.fx.run("apply", "all")
        self.assertEqual(out["status"], "STALE")
        self.assertIn("сначала", out["text_html"])


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
        self.assertIn("a.sh", out["text_html"])
        plan = self.fx.run("plan")
        self.assertEqual(self.targets(plan), ["bridge", "c.py"])
        self.assertIn("/update пропущенные", plan["text_html"])
        listed = self.fx.run("skipped")
        self.assertIn("a.sh", listed["text_html"])
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


if __name__ == "__main__":
    unittest.main()
