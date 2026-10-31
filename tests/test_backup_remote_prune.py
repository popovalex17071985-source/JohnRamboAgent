"""Tests for scripts/backup-remote-prune.py -- room in the cloud before the upload.

17.10.2026, agent Albert: the owner's Drive was full, the nightly upload failed with
403 storageQuotaExceeded, and agent-backup.sh deleted old cloud copies only AFTER a
successful upload -- so the Drive never freed itself and no fresh copy left the box.

What must hold:
- only our archives (<agent>-YYYYMMDD-HHMM.tar.gz.gpg) are ever deleted; foreign
  files, other agents' archives (even «<agent>-x-...») and stray names stay;
- first the extra copies of a past day (the newest of each day stays), today's
  copies are never extras;
- then the oldest copies, while free < archive + 1 GiB, never below 2 copies;
- a remote that cannot report free space (about fails / no "free") -> nothing is
  deleted and the run still exits 0 (the upload proceeds as before);
- deletes skip the trash (--drive-use-trash=false); --dry deletes nothing;
- agent-backup.sh calls the helper BEFORE `rclone copy` and keeps its age rule after.
"""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
PRUNE_PATH = REPO_ROOT / "scripts" / "backup-remote-prune.py"
BACKUP_SH = REPO_ROOT / "scripts" / "agent-backup.sh"
G = 10**9
GIB = 1 << 30
AGENT = "albert"
TODAY = "20261019"


def load_prune():
    module_name = "backup_remote_prune"
    loader = SourceFileLoader(module_name, str(PRUNE_PATH))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


prune = load_prune()


def n(stamp: str, agent: str = AGENT) -> str:
    return f"{agent}-{stamp}.tar.gz.gpg"


DRIVE = [
    (n("20261012-0340"), G),
    (n("20261016-0340"), G),
    (n("20261016-1916"), G),
    (n("20261016-2125"), 2 * G),
    (n("20261018-0340"), 2 * G),
    ("notes.txt", 5 * G),
    (n("20261001-0340", "albert-x"), G),  # another agent sharing the folder
    (n("20261001-0340", "bob"), G),
    (f"{AGENT}-20261001-0340.tar.gz", G),  # not encrypted: not ours
]


class PlanTest(unittest.TestCase):
    def test_room_enough_drops_only_past_day_extras(self) -> None:
        drop = prune.plan(DRIVE, AGENT, free=10 * G, need=2 * G, today=TODAY)
        self.assertEqual(drop, [n("20261016-0340"), n("20261016-1916")])

    def test_full_drive_drops_oldest_after_extras(self) -> None:
        drop = prune.plan(DRIVE, AGENT, free=0, need=2 * G, today=TODAY)
        # extras free 2 GB; 2 GB + 1 GiB margin is still short -> the oldest daily goes
        self.assertEqual(drop, [n("20261016-0340"), n("20261016-1916"), n("20261012-0340")])

    def test_never_below_two_and_foreign_untouched(self) -> None:
        drop = prune.plan(DRIVE, AGENT, free=0, need=100 * G, today=TODAY)
        kept = {name for name, _ in DRIVE} - set(drop)
        self.assertEqual(kept, {
            n("20261016-2125"), n("20261018-0340"), "notes.txt",
            n("20261001-0340", "albert-x"), n("20261001-0340", "bob"),
            f"{AGENT}-20261001-0340.tar.gz",
        })

    def test_todays_copies_are_not_extras(self) -> None:
        files = [(n("20261019-0300"), G), (n("20261019-0340"), G), (n("20261019-1200"), G)]
        self.assertEqual(prune.plan(files, AGENT, free=10 * G, need=G, today=TODAY), [])

    def test_extras_stop_at_two_copies(self) -> None:
        files = [(n("20261017-0100"), G), (n("20261017-0200"), G), (n("20261017-0300"), G)]
        drop = prune.plan(files, AGENT, free=10 * G, need=G, today=TODAY)
        self.assertEqual(drop, [n("20261017-0100")])

    def test_margin_is_one_gib(self) -> None:
        files = [(n("20261010-0340"), G), (n("20261011-0340"), G), (n("20261012-0340"), G)]
        need = 3 * G
        self.assertEqual(prune.plan(files, AGENT, free=need + GIB, need=need, today=TODAY), [])
        self.assertEqual(prune.plan(files, AGENT, free=need + GIB - 1, need=need, today=TODAY),
                         [n("20261010-0340")])

    def test_agent_name_is_literal_not_regex(self) -> None:
        files = [(n("20261010-0340", "a.b"), G), (n("20261011-0340", "a.b"), G),
                 (n("20261012-0340", "a.b"), G), (n("20261009-0340", "axb"), G)]
        drop = prune.plan(files, "a.b", free=0, need=G, today=TODAY)
        self.assertEqual(drop, [n("20261010-0340", "a.b")])

    def test_nothing_of_ours(self) -> None:
        self.assertEqual(prune.plan([("notes.txt", G)], AGENT, free=0, need=G, today=TODAY), [])


class FakeRclone:
    """Stands in for prune._rclone: serves about/lsjson, records every call."""

    def __init__(self, about: object, files: list[tuple[str, int]],
                 about_fails: bool = False, lsjson_fails: bool = False) -> None:
        self.about, self.files = about, files
        self.about_fails, self.lsjson_fails = about_fails, lsjson_fails
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, rclone: str, *args: str) -> str:
        self.calls.append(args)
        if args[0] == "about":
            if self.about_fails:
                raise subprocess.CalledProcessError(1, [rclone, *args])
            return json.dumps(self.about)
        if args[0] == "lsjson":
            if self.lsjson_fails:
                raise subprocess.CalledProcessError(1, [rclone, *args])
            return json.dumps([{"Name": nm, "Size": sz, "IsDir": False} for nm, sz in self.files])
        if args[0] == "deletefile":
            return ""
        raise AssertionError(f"unexpected rclone call: {args}")

    def deleted(self) -> list[str]:
        return [c[-1] for c in self.calls if c[0] == "deletefile"]


class MainTest(unittest.TestCase):
    TARGET = "gdrive:dashi-albert-backups"

    def run_main(self, fake: FakeRclone, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with patch.object(prune, "_rclone", fake), redirect_stdout(out):
            code = prune.main([self.TARGET, AGENT, str(2 * G), *args])
        return code, out.getvalue()

    def test_full_drive_deletes_our_oldest_without_trash(self) -> None:
        fake = FakeRclone({"total": 15 * G, "used": 15 * G, "free": 0}, DRIVE)
        code, out = self.run_main(fake)
        self.assertEqual(code, 0)
        self.assertEqual(fake.deleted(), [f"{self.TARGET}/{x}" for x in
                                          (n("20261016-0340"), n("20261016-1916"), n("20261012-0340"))])
        for c in fake.calls:
            if c[0] == "deletefile":
                self.assertIn("--drive-use-trash=false", c)
        self.assertEqual(fake.calls[0], ("about", "gdrive:", "--json"))
        self.assertIn("удалено копий: 3", out)

    def test_about_fails_deletes_nothing(self) -> None:
        fake = FakeRclone({}, DRIVE, about_fails=True)
        code, out = self.run_main(fake)
        self.assertEqual((code, fake.deleted()), (0, []))
        self.assertIn("не сообщает свободное место", out)
        self.assertFalse(any(c[0] == "lsjson" for c in fake.calls))

    def test_about_without_free_deletes_nothing(self) -> None:
        fake = FakeRclone({"total": 0, "used": 5 * G}, DRIVE)
        code, _ = self.run_main(fake)
        self.assertEqual((code, fake.deleted()), (0, []))

    def test_listing_fails_deletes_nothing(self) -> None:
        fake = FakeRclone({"free": 0}, DRIVE, lsjson_fails=True)
        code, _ = self.run_main(fake)
        self.assertEqual((code, fake.deleted()), (0, []))

    def test_dry_run_deletes_nothing(self) -> None:
        fake = FakeRclone({"free": 0}, DRIVE)
        code, out = self.run_main(fake, "--dry")
        self.assertEqual((code, fake.deleted()), (0, []))
        self.assertIn("удалил бы", out)

    def test_bad_arguments_exit_2(self) -> None:
        with redirect_stdout(io.StringIO()), patch("sys.stderr", io.StringIO()):
            self.assertEqual(prune.main(["no-colon", AGENT, "5"]), 2)
            self.assertEqual(prune.main([self.TARGET, AGENT, "lots"]), 2)
            self.assertEqual(prune.main([self.TARGET, AGENT]), 2)

    def test_real_rclone_missing_is_quiet_skip(self) -> None:
        out = io.StringIO()
        with patch.dict("os.environ", {"RCLONE_BIN": "/nonexistent/rclone"}), redirect_stdout(out):
            code = prune.main([self.TARGET, AGENT, "5"])
        self.assertEqual(code, 0)
        self.assertIn("не сообщает свободное место", out.getvalue())


class WiringTest(unittest.TestCase):
    def setUp(self) -> None:
        self.src = BACKUP_SH.read_text(encoding="utf-8")

    def test_prune_runs_before_upload(self) -> None:
        self.assertLess(self.src.index("backup-remote-prune.py"),
                        self.src.index('"$RCLONE_BIN" copy --tpslimit 2 --drive-chunk-size 64M "$ARCHIVE"'))

    def test_prune_gets_our_agent_and_archive_size(self) -> None:
        call = self.src[self.src.index("backup-remote-prune.py"):]
        call = call[:call.index("\n      ||")]
        self.assertIn('"$AGENT"', call)
        self.assertIn('"$size_b"', call)
        self.assertIn('"${RCLONE_REMOTE}:${RCLONE_PATH}"', call)

    def test_age_rule_kept_after_upload(self) -> None:
        after = self.src[self.src.index('"$RCLONE_BIN" copy --tpslimit 2 --drive-chunk-size 64M "$ARCHIVE"'):]
        self.assertIn('--drive-use-trash=false --min-age "${RETAIN}d"', after)

    def test_prune_ships_next_to_backup(self) -> None:
        self.assertIn('"$SCRIPT_DIR/backup-remote-prune.py"', self.src)
        self.assertTrue(PRUNE_PATH.is_file())


if __name__ == "__main__":
    unittest.main()
