"""Tests for agent-kit/hooks/turnlib.py -- gates read only the transcript tail.

19.10.2026 on the coordinator: a 108 MB session transcript, read whole by every
gate (~0.9 GB RSS per hook), OOM-killed processes on an 8 GB box. The reply gate
runs on EVERY message to the owner, so it must never read the file whole.
"""

import json
import os
import sys
import tempfile
import tracemalloc
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "agent-kit" / "hooks"))
from turnlib import TAIL_BYTES, tail_lines, turn_entries  # noqa: E402


def _write(lines: list[str]) -> Path:
    fd, p = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("".join(ln + "\n" for ln in lines))
    return Path(p)


def _entry(i: int, pad: int = 200) -> str:
    return json.dumps({"type": "assistant", "i": i,
                       "message": {"content": [{"type": "text", "text": "ж" * pad}]}},
                      ensure_ascii=False)


class TailLines(unittest.TestCase):
    def setUp(self) -> None:
        self.paths: list[Path] = []

    def tearDown(self) -> None:
        for p in self.paths:
            p.unlink(missing_ok=True)

    def file(self, lines: list[str]) -> Path:
        p = _write(lines)
        self.paths.append(p)
        return p

    def test_small_file_equals_full_read(self) -> None:
        p = self.file([_entry(i) for i in range(50)])
        self.assertEqual(tail_lines(p), p.read_text(encoding="utf-8").split("\n")[:-1])

    def test_big_file_returns_only_whole_last_lines(self) -> None:
        p = self.file([_entry(i) for i in range(5000)])
        got = tail_lines(p, max_bytes=100_000)
        self.assertTrue(0 < len(got) < 5000)
        self.assertLessEqual(len("\n".join(got).encode()), 100_000)
        idx = [json.loads(ln)["i"] for ln in got]          # every line parses
        self.assertEqual(idx, list(range(idx[0], 5000)))

    def test_cut_exactly_on_line_boundary_keeps_that_line(self) -> None:
        lines = [_entry(i, pad=10) for i in range(10)]
        p = self.file(lines)
        last3 = sum(len(ln.encode()) + 1 for ln in lines[-3:])
        self.assertEqual(tail_lines(p, max_bytes=last3), lines[-3:])

    def test_turn_entries_still_starts_at_last_prompt(self) -> None:
        p = self.file([json.dumps({"type": "user", "message": {"content": "раз"}}), _entry(1),
                       json.dumps({"type": "user", "message": {"content": "два"}}), _entry(2)])
        rows = turn_entries(p)
        self.assertEqual([r.get("i") for r in rows], [None, 2])
        self.assertEqual(rows[0]["message"]["content"], "два")

    def test_peak_memory_far_below_file_size(self) -> None:
        p = self.file([_entry(i, pad=1000) for i in range(15_000)])   # ~30 MB, Cyrillic
        size = p.stat().st_size
        self.assertGreater(size, 3 * TAIL_BYTES)
        tracemalloc.start()
        try:
            got = tail_lines(p)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(json.loads(got[-1])["i"], 14_999)
        self.assertLess(peak, size / 2)


if __name__ == "__main__":
    unittest.main()
