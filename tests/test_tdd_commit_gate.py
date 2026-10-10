"""Tests for agent-kit/hooks/tdd-commit-gate.py: a code commit must carry a test.

The kit ships the gate to every agent as a PreToolUse/Bash hook; exit 2 blocks
the `git commit`. Ported from the coordinator's live copy together with its
tests, plus checks that the kit actually wires the gate and states the rule.

Run: python3 -m unittest discover -s tests -p 'test_tdd_commit_gate.py'
"""
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
KIT = REPO_ROOT / "agent-kit"
HOOK = KIT / "hooks" / "tdd-commit-gate.py"


def sh(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin"})


def write(repo: Path, rel: str, text: str = "x\n") -> None:
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def run_hook(command: str, cwd: Path) -> subprocess.CompletedProcess:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(cwd)})
    return subprocess.run(["python3", str(HOOK)], input=payload, capture_output=True, text=True)


class TddCommitGate(unittest.TestCase):
    def setUp(self) -> None:
        # A missing hook file makes python3 exit 2 -- the same code as «blocked»,
        # so every blocking assertion would pass vacuously without this.
        self.assertTrue(HOOK.is_file(), f"no hook at {HOOK}")
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        sh(self.repo, "init", "-q", "-b", "main")
        write(self.repo, "README.md")
        write(self.repo, "lib/app.py", "a = 1\n")
        sh(self.repo, "add", ".")
        sh(self.repo, "commit", "-qm", "init")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_code_without_test_is_blocked(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        r = run_hook('git commit -m "Поменял app"', self.repo)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("Без теста:", r.stderr)

    def test_code_with_test_in_same_commit_passes(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        write(self.repo, "tests/test_app.py", "def test(): pass\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "app + тест"', self.repo).returncode, 0)

    def test_explicit_reason_passes(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        r = run_hook('git commit -m "Поменял app\n\nБез теста: разовый скрипт выгрузки"', self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_empty_reason_does_not_count(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "x\n\nБез теста:"', self.repo).returncode, 2)

    def test_docs_and_config_only_pass(self) -> None:
        write(self.repo, "README.md", "new\n")
        write(self.repo, "conf/settings.json", "{}\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "доки"', self.repo).returncode, 0)

    def test_not_a_commit_passes(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook("git status && git log -1", self.repo).returncode, 0)

    def test_test_earlier_on_feature_branch_passes(self) -> None:
        sh(self.repo, "switch", "-qc", "feature/x")
        write(self.repo, "tests/test_app.py", "def test(): assert False\n")
        sh(self.repo, "add", ".")
        sh(self.repo, "commit", "-qm", "Тест: app")
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "app"', self.repo).returncode, 0)

    def test_unpushed_test_commit_on_trunk_passes(self) -> None:
        # 10.10.2026: the Jarvis repo commits straight to master -- «test commit,
        # then code commit» was blocked because the branch IS the trunk.
        remote = Path(self.tmp.name) / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        sh(self.repo, "remote", "add", "origin", str(remote))
        sh(self.repo, "push", "-q", "-u", "origin", "main")
        write(self.repo, "tests/test_app.py", "def test(): assert False\n")
        sh(self.repo, "add", ".")
        sh(self.repo, "commit", "-qm", "Тест: app")
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "app"', self.repo).returncode, 0)

    def test_old_unpushed_test_does_not_cover_code_on_trunk(self) -> None:
        # The Jarvis master carries ~950 unpushed commits: «any test since the
        # upstream» would wave everything through. Only recent ones count.
        remote = Path(self.tmp.name) / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        sh(self.repo, "remote", "add", "origin", str(remote))
        sh(self.repo, "push", "-q", "-u", "origin", "main")
        write(self.repo, "tests/test_app.py", "def test(): pass\n")
        sh(self.repo, "add", ".")
        old = {"GIT_AUTHOR_DATE": "2026-01-01T10:00:00", "GIT_COMMITTER_DATE": "2026-01-01T10:00:00"}
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "Тест: давний"], check=True,
                       capture_output=True, env={**old, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                                 "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                                                 "PATH": "/usr/bin:/bin"})
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "app"', self.repo).returncode, 2)

    def test_pushed_test_does_not_cover_new_code_on_trunk(self) -> None:
        remote = Path(self.tmp.name) / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        sh(self.repo, "remote", "add", "origin", str(remote))
        write(self.repo, "tests/test_app.py", "def test(): pass\n")
        sh(self.repo, "add", ".")
        sh(self.repo, "commit", "-qm", "Тест: app")
        sh(self.repo, "push", "-q", "-u", "origin", "main")
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "app"', self.repo).returncode, 2)

    def test_git_dash_c_from_other_cwd_is_checked(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        sh(self.repo, "add", ".")
        r = run_hook(f'git -C {self.repo} commit -m "app"', Path(self.tmp.name))
        self.assertEqual(r.returncode, 2)

    def test_cd_into_repo_before_commit_is_checked(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        r = run_hook(f'cd {self.repo} && git add lib/app.py && git -c user.name=x commit -qm "app"',
                     Path(self.tmp.name))
        self.assertEqual(r.returncode, 2)

    def test_commit_all_flag_counts_unstaged_code(self) -> None:
        write(self.repo, "lib/app.py", "a = 2\n")
        self.assertEqual(run_hook('git commit -am "app"', self.repo).returncode, 2)

    def test_commit_with_pathspec_is_checked(self) -> None:
        # Review 10.10.2026: `git commit lib/app.py -m …` skipped `git add`, so the
        # index was empty and the gate saw no code.
        write(self.repo, "lib/app.py", "a = 2\n")
        self.assertEqual(run_hook('git commit lib/app.py -m "app"', self.repo).returncode, 2)
        self.assertEqual(run_hook('git commit -m "app" -- lib/app.py', self.repo).returncode, 2)

    def test_shell_and_ts_count_as_code(self) -> None:
        write(self.repo, "bin/run.sh", "echo\n")
        write(self.repo, "src/x.ts", "export {}\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "скрипты"', self.repo).returncode, 2)

    def test_ts_spec_file_counts_as_test(self) -> None:
        write(self.repo, "src/x.ts", "export {}\n")
        write(self.repo, "src/x.test.ts", "test('x', () => {})\n")
        sh(self.repo, "add", ".")
        self.assertEqual(run_hook('git commit -m "x + тест"', self.repo).returncode, 0)


class KitWiring(unittest.TestCase):
    """The hook file alone does nothing: install-kit.sh must register it."""

    def test_install_kit_registers_gate_on_bash(self) -> None:
        text = (KIT / "install-kit.sh").read_text()
        self.assertRegex(text, r'\("PreToolUse",\s*"Bash",\s*"tdd-commit-gate\.py",\s*\d+\)')

    def test_constitution_states_rule_and_escape(self) -> None:
        text = (KIT / "core" / "constitution.md").read_text()
        self.assertIn("tdd-commit-gate.py", text)
        self.assertIn("Без теста:", text)

    def test_verify_agent_expects_gate(self) -> None:
        text = (KIT / "tests" / "verify-agent.sh").read_text()
        self.assertTrue(re.search(r"\btdd-commit-gate\.py\b", text))


if __name__ == "__main__":
    unittest.main()
