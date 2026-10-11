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


class KitFailureLines(unittest.TestCase):
    """11.10.2026: on Albert the cloud backup failed two days running (Google token
    expired) and nothing alerted -- the backup script writes «[stamp] FAIL: ...»,
    which no pattern matched. The kit's other failure lines are covered too."""

    def test_backup_fail_line_caught(self) -> None:
        line = ("[2026-10-11 03:41:49 +10] FAIL: off-site не уехал ни через rclone, "
                "ни через gws (локальная копия цела)")
        self.assertTrue(jfw.hits(line))

    def test_backup_other_fail_lines_caught(self) -> None:
        for msg in ("нет пароля: /w/secrets/backup.pass", "tar|gpg упал (tar=2 gpg=0)",
                    "self-check: свежий архив не расшифровался/не читается — удалён"):
            self.assertTrue(jfw.hits(f"[2026-10-11 03:40:02 +05] FAIL: {msg}"), msg)

    def test_backup_tidy_error_caught(self) -> None:
        msg = "ОШИБКА: архив старых копий не прошёл проверку, ничего не удалено (1 проблем)"
        self.assertTrue(jfw.hits(f"2026-10-11 04:10:00 {msg}"))   # its own log line
        self.assertTrue(jfw.hits(msg))                            # the same on stderr

    def test_memory_sync_error_caught(self) -> None:
        self.assertTrue(jfw.hits("[ov-session-sync] ERROR: temp_upload failed: {}"))

    def test_fail_inside_words_or_prose_ignored(self) -> None:
        for line in ("FAILURES: 0", "tests: 12 passed, no FAIL here", "PASS/FAIL: see report",
                     "[2026-10-11 03:41:49 +10] OK off-site: gdrive:x/a.tar.gz.gpg",
                     "[2026-10-11 03:41:49 +10] WARN: нет rclone-remote 'gdrive'",
                     "найдено 0 ошибок, ОШИБКА не обнаружена"):
            self.assertEqual(jfw.hits(line), [], line)


if __name__ == "__main__":
    unittest.main()
