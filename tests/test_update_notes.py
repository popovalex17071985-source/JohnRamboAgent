"""update-notes.json -- plain-Russian notes the owner sees in /update.

Keys are commit sha prefixes (7+ hex chars), values a short line about what
changes FOR THE OWNER, or "-" to hide a commit (tests, docs, internals). The
planner (scripts/update-plan.py) reads this file from the fresh version.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
NOTES = REPO_ROOT / "update-notes.json"
SHA = re.compile(r"[0-9a-f]{7,40}")
# file names and dev jargon have no place in a note for the owner
JARGON = re.compile(r"\.(sh|py|ts|json|md)\b|\b(PR|commit|refactor|hook|cron)\b", re.I)
MAX_NOTE_CHARS = 160
# From here on every commit /update would show carries a note. 11.10.2026: sixteen
# commits after it reached owners as raw subjects («scan: blob каждого
# незакреплённого файла…», «передаю ветку явно (--branch)»).
NOTES_BASELINE = "c40644b"


def _planner():
    spec = importlib.util.spec_from_file_location("update_plan_for_notes",
                                                  REPO_ROOT / "scripts" / "update-plan.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(REPO_ROOT), *args], capture_output=True, text=True)


class UpdateNotesTest(unittest.TestCase):
    def test_shape_and_plain_words(self) -> None:
        notes = json.loads(NOTES.read_text())
        self.assertIsInstance(notes, dict)
        self.assertGreaterEqual(len(notes), 60)
        for key, text in notes.items():
            self.assertRegex(key, SHA, key)
            self.assertIsInstance(text, str, key)
            self.assertTrue(text.strip(), key)
            if text == "-":
                continue
            self.assertLessEqual(len(text), MAX_NOTE_CHARS, key)
            self.assertIsNone(JARGON.search(text), f"{key}: {text}")
            self.assertRegex(text, "[А-Яа-яЁё]", key)

    def test_prefixes_are_unambiguous(self) -> None:
        keys = list(json.loads(NOTES.read_text()))
        for a in keys:
            for b in keys:
                if a != b:
                    self.assertFalse(b.startswith(a), f"{a} is a prefix of {b}")


class EveryShownCommitHasNoteTest(unittest.TestCase):
    """note_for falls back to the raw subject -- dev jargon in «Что нового». Every
    non-merge commit since NOTES_BASELINE needs a «Хозяину:» line, a key in
    update-notes.json (text or "-"), or a «Тест:» subject."""

    def test_no_commit_falls_back_to_subject(self) -> None:
        if _git("cat-file", "-e", f"{NOTES_BASELINE}^{{commit}}").returncode != 0:
            self.skipTest("history too shallow: baseline commit absent")
        if _git("merge-base", "--is-ancestor", NOTES_BASELINE, "HEAD").returncode != 0:
            self.skipTest("baseline is not an ancestor of HEAD")
        plan = _planner()
        notes = {k.lower(): v for k, v in json.loads(NOTES.read_text()).items()}
        log = _git("log", "--no-merges", "--format=%H%x1f%B%x1e", f"{NOTES_BASELINE}..HEAD")
        self.assertEqual(log.returncode, 0, log.stderr)
        missing = []
        for chunk in log.stdout.split("\x1e"):
            sha, sep, body = chunk.strip("\n").partition("\x1f")
            if not sep:
                continue
            commit = plan.Commit(sha=sha, merge=False, body=body.strip())
            annotated = (any(ln.strip().startswith(plan.TRAILER) for ln in commit.body.splitlines())
                         or any(sha.startswith(key) for key in notes))
            if not annotated and plan.note_for(commit, notes) is not None:
                missing.append(f"{sha[:7]} {commit.body.splitlines()[0][:80]}")
        self.assertEqual(missing, [], "add «Хозяину: …» to the message or a key to "
                                      "update-notes.json (\"-\" hides):\n" + "\n".join(missing))


if __name__ == "__main__":
    unittest.main()
