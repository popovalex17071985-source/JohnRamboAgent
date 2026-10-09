"""update-notes.json -- plain-Russian notes the owner sees in /update.

Keys are commit sha prefixes (7+ hex chars), values a short line about what
changes FOR THE OWNER, or "-" to hide a commit (tests, docs, internals). The
planner (scripts/update-plan.py) reads this file from the fresh version.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
NOTES = REPO_ROOT / "update-notes.json"
SHA = re.compile(r"[0-9a-f]{7,40}")
# file names and dev jargon have no place in a note for the owner
JARGON = re.compile(r"\.(sh|py|ts|json|md)\b|\b(PR|commit|refactor|hook|cron)\b", re.I)
MAX_NOTE_CHARS = 160


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


if __name__ == "__main__":
    unittest.main()
