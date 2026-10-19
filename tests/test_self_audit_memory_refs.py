"""audit_memory_refs (agent-kit/bin/self-audit.py): which script notes point at nothing.

15.10.2026: the morning self-audit flagged ~/dkpbu/scripts/backup.sh as «НЕТ ФАЙЛА».
The note named another project's script by its full path, the audit cut it down to
scripts/backup.sh and looked for it in the agent's workspace. A path written from
~ or / is now checked as is; a bare bin/…, hooks/…, scripts/… path still resolves
from the workspace and the plugin checkout.

  python3 -m unittest discover -s tests -p test_self_audit_memory_refs.py
"""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "agent-kit" / "bin" / "self-audit.py"


class MemoryRefsTest(unittest.TestCase):
    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("self_audit_memory_refs", SCRIPT)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.ws = self.tmp / "workspace"
        self.ws.mkdir()
        self.note = self.tmp / "LEARNINGS.md"
        self.mod.MEMORY_FILES = [self.note]
        self.mod.ROOT = self.ws

    def refs(self) -> list[str]:
        return [r["ref"] for r in self.mod.audit_memory_refs()]

    def put(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n", encoding="utf-8")
        return path

    def test_existing_script_of_another_project_is_not_flagged(self) -> None:
        script = self.put(self.tmp / "dkpbu" / "scripts" / "backup.sh")
        self.note.write_text(f"- DKPbu `{script}` затирал копию дня\n", encoding="utf-8")

        self.assertEqual(self.refs(), [])

    def test_missing_absolute_script_is_flagged_with_its_full_path(self) -> None:
        self.note.write_text(f"- см. {self.tmp}/gone/bin/nope.py\n", encoding="utf-8")

        self.assertEqual(self.refs(), [f"{self.tmp}/gone/bin/nope.py"])

    def test_home_relative_path_is_expanded(self) -> None:
        self.note.write_text("- ~/surely-no-such-dir-3f9a/scripts/x.sh\n", encoding="utf-8")

        self.assertEqual(self.refs(), ["~/surely-no-such-dir-3f9a/scripts/x.sh"])

    def test_absolute_path_is_not_rescued_by_a_workspace_copy(self) -> None:
        # Same tail exists in the workspace, but the note names another place.
        self.put(self.ws / "bin" / "tool.py")
        self.note.write_text(f"- {self.tmp}/other/bin/tool.py\n", encoding="utf-8")

        self.assertEqual(self.refs(), [f"{self.tmp}/other/bin/tool.py"])

    def test_bare_paths_still_resolve_from_the_workspace(self) -> None:
        self.put(self.ws / "bin" / "here.py")
        self.note.write_text(
            "- `bin/here.py`, `bin/missing.py` и `scripts/also.sh`\n", encoding="utf-8"
        )

        self.assertEqual(self.refs(), ["bin/missing.py", "scripts/also.sh"])

    def test_relative_path_into_the_plugin_checkout_stays_relative(self) -> None:
        # The middle of a relative path is not an absolute one: this note must
        # resolve as bin/remind-at.sh in the plugin's agent-kit, as before.
        self.put(self.ws / ".claude" / "dashi-plugin-claude-code" / "agent-kit" / "bin"
                 / "remind-at.sh")
        self.note.write_text(
            "- `.claude/dashi-plugin-claude-code/agent-kit/bin/remind-at.sh`\n", encoding="utf-8"
        )

        self.assertEqual(self.refs(), [])

    def test_each_reference_is_reported_once(self) -> None:
        self.note.write_text("- bin/missing.py\n- снова bin/missing.py\n", encoding="utf-8")

        self.assertEqual(self.refs(), ["bin/missing.py"])


if __name__ == "__main__":
    unittest.main()
