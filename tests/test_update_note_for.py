"""note_for: what the owner reads for each commit in «Что нового»."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "update-plan.py"


def _load():
    spec = importlib.util.spec_from_file_location("update_plan_notes", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


M = _load()


class NoteForTest(unittest.TestCase):
    def test_test_only_commit_is_hidden_from_owner(self) -> None:
        # Smith 10.10.2026: «Что нового» listed «Тест: незакреплённые правки…».
        c = M.Commit(sha="a" * 40, merge=False, body="Тест: незакреплённые правки ядра не теряются")
        self.assertIsNone(M.note_for(c, {}))

    def test_plain_subject_still_shown_when_not_annotated(self) -> None:
        c = M.Commit(sha="b" * 40, merge=False, body="Агент шлёт отчёт списком")
        self.assertEqual(M.note_for(c, {}), "Агент шлёт отчёт списком")

    def test_annotation_wins(self) -> None:
        c = M.Commit(sha="c" * 40, merge=False, body="Тест: что-то")
        self.assertEqual(M.note_for(c, {"ccccccc": "Понятная фраза"}), "Понятная фраза")


if __name__ == "__main__":
    unittest.main()
