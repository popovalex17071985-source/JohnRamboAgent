"""job-fail-watch: the same failure with new numbers is one signature (10.10.2026).

The shape regex was r'\\\\d+' (a literal backslash then d), so a line differing only in a
timestamp or a count got a fresh signature and woke the agent again on every run.
"""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("jfw", ROOT / "agent-kit/bin/job-fail-watch.py")
jfw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jfw)


class LineShape(unittest.TestCase):
    def test_numbers_become_n(self) -> None:
        self.assertEqual(jfw.line_shape("2026-10-10 08:12 failed=3"), "N-N-N N:N failed=N")

    def test_same_failure_new_time_same_shape(self) -> None:
        self.assertEqual(jfw.line_shape("08:12 СБОЙ выгрузки 41"),
                         jfw.line_shape("09:47 СБОЙ выгрузки 7"))


class QuotingLogsSkipped(unittest.TestCase):
    """10.10.2026: gorbot's memory log quoted «[СБОЙ ЗАДАНИЯ]» from a chat and the
    watchdog took the quote for a failure. Logs that mirror conversation are skipped."""

    def test_conversation_logs_not_scanned(self) -> None:
        for name in ("ov-memory.log", "tmux-pane.log", "tmux-pane.prev.log"):
            self.assertIn(name, jfw.SKIP)


if __name__ == "__main__":
    unittest.main()
