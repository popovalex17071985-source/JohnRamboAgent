"""Tests for agent-kit/bin/backup-tidy.py -- the weekly tidy of old backup copies.

Agents copy a file before every edit and never clean up: agent «Гор» carried 714
copies (964 MB), 688 of them `feed-*.xlsx.bak-<label>-<epoch>`. The tidy packs
the old ones into one verified archive and only then removes the originals.

What must hold:
- per (dir, original name) the newest 5 copies AND every copy younger than 14
  days stay where they are;
- files that are not copies are never touched;
- the archive is re-opened and checked BEFORE anything is removed: every member
  is re-read and its sha256 must equal the one taken while packing; a bad
  archive means nothing is removed and the run exits non-zero;
- right before each delete the copy is hashed again; one that changed since it
  was packed (even to the same size) stays where it is;
- --dry-run changes nothing;
- the owner hears one plain line only when something was archived.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import os
import sys
import tarfile
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
TIDY_PATH = REPO_ROOT / "agent-kit" / "bin" / "backup-tidy.py"
DAY = 86400


def load_tidy():
    module_name = "backup_tidy"
    loader = SourceFileLoader(module_name, str(TIDY_PATH))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


tidy = load_tidy()


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def same_size_rewrite(path: Path) -> None:
    """Change the content of `path`, keeping its size and mtime."""
    st = path.stat()
    data = bytearray(path.read_bytes())
    data[0] ^= 0xFF
    path.write_bytes(bytes(data))
    os.utime(path, (st.st_atime, st.st_mtime))


def make(path: Path, age_days: float, size: int = 1024) -> Path:
    """Create a file of `size` bytes whose mtime is `age_days` in the past."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))
    stamp = time.time() - age_days * DAY
    os.utime(path, (stamp, stamp))
    return path


class Fixture(unittest.TestCase):
    """A temp workspace shaped like Гор's: a feed with a pile of old copies."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)
        data = self.ws / "projects" / "avito-pricing" / "data"
        self.feed = make(data / "feed-1.xlsx", 0)
        # 12 copies, ages 1..12 days -> all younger than 14 days: all kept
        self.young = [
            make(data / f"feed-1.xlsx.bak-price-{1790000000 + i}", i) for i in range(1, 13)
        ]
        # 9 copies of another file, ages 20..28 days -> newest 5 kept, 4 archived
        self.old = [make(data / f"feed-2.xlsx.bak-names-{i}", 20 + i) for i in range(9)]
        # bin: 7 old copies of tg-send.py in assorted styles, ages 30..36 -> 2 archived
        bin_dir = self.ws / "bin"
        self.script = make(bin_dir / "tg-send.py", 40)
        styles = ["bak-20.09", "bak", "bak-25-09", "bak.1", "bak_old", "bak-1789832488", "orig"]
        self.tg_copies = [make(bin_dir / f"tg-send.py.{s}", 30 + i) for i, s in enumerate(styles)]
        # not copies: must never be touched whatever their age
        self.bystanders = [
            make(bin_dir / "bakery.txt", 400),
            make(bin_dir / "notes.bakery", 400),
            make(bin_dir / "x.original", 400),
            make(bin_dir / "bak", 400),
        ]
        self.now = time.time()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def expected_archived(self) -> set[Path]:
        old_sorted = sorted(self.old, key=lambda p: p.stat().st_mtime, reverse=True)
        tg_sorted = sorted(self.tg_copies, key=lambda p: p.stat().st_mtime, reverse=True)
        return set(old_sorted[5:]) | set(tg_sorted[5:])

    def run_tidy(self, *args: str) -> tuple[int, str, list[str]]:
        sent: list[str] = []
        out = io.StringIO()
        with patch.object(tidy, "notify", side_effect=lambda ws, text: sent.append(text)):
            with redirect_stdout(out):
                code = tidy.main(["--workspace", str(self.ws), *args])
        return code, out.getvalue(), sent

    def archives(self) -> list[Path]:
        return sorted((self.ws / "archive" / "old-copies").glob("old-copies-*.tar.gz"))


class CopyDetectionTest(Fixture):
    def test_copy_names(self) -> None:
        for name, orig in [
            ("feed-1.xlsx.bak-price-1790000001", "feed-1.xlsx"),
            ("tg-send.py.bak-20.09", "tg-send.py"),
            ("x.sh.bak-25-09", "x.sh"),
            ("job-report.py.bak-names-1790878214", "job-report.py"),
            ("remind-at.sh.bak-1789832488", "remind-at.sh"),
            ("a.py.bak", "a.py"),
            ("a.py.orig", "a.py"),
        ]:
            self.assertEqual(tidy.original_name(name), orig, name)
        for name in ["bakery.txt", "notes.bakery", "x.original", "bak", ".bak", "a.orig.py"]:
            self.assertIsNone(tidy.original_name(name), name)

    def test_groups_by_dir_and_original(self) -> None:
        groups = tidy.find_copies(self.ws)
        data = self.ws / "projects" / "avito-pricing" / "data"
        self.assertEqual(len(groups[(data, "feed-1.xlsx")]), 12)
        self.assertEqual(len(groups[(data, "feed-2.xlsx")]), 9)
        self.assertEqual(len(groups[(self.ws / "bin", "tg-send.py")]), 7)
        self.assertEqual(len(groups), 3)

    def test_skips_service_and_protected_dirs(self) -> None:
        for rel in [
            ".git/objects/a.py.bak",
            "node_modules/pkg/index.js.bak",
            "bin/__pycache__/x.pyc.bak",
            "archive/old-copies/y.py.bak",
            ".claude/core/archive/2026-05.md.bak",
            ".claude/core/archive/.bak/2026-05.md.bak-1",
        ]:
            make(self.ws / rel, 100)
        found = {p for files in tidy.find_copies(self.ws).values() for p in files}
        for rel in [".git", "node_modules", "__pycache__", "archive/old-copies", "core/archive"]:
            self.assertFalse(any(rel in str(p) for p in found), rel)

    def test_symlink_is_not_a_copy(self) -> None:
        link = self.ws / "bin" / "link.py.bak"
        link.symlink_to(self.script)
        os.utime(link, (0, 0), follow_symlinks=False)
        found = {p for files in tidy.find_copies(self.ws).values() for p in files}
        self.assertNotIn(link, found)


class SelectionTest(Fixture):
    def test_keeps_newest_five_and_young(self) -> None:
        picked = set(tidy.select_old(tidy.find_copies(self.ws), self.now))
        self.assertEqual(picked, self.expected_archived())
        self.assertTrue(set(self.young).isdisjoint(picked))

    def test_constants_are_named(self) -> None:
        self.assertEqual(tidy.KEEP_NEWEST, 5)
        self.assertEqual(tidy.KEEP_YOUNGER_DAYS, 14)


class RunTest(Fixture):
    def test_archives_verifies_then_removes(self) -> None:
        expected = self.expected_archived()
        self.assertEqual(len(expected), 6)
        sizes = {p.relative_to(self.ws).as_posix(): p.stat().st_size for p in expected}
        code, _, sent = self.run_tidy()
        self.assertEqual(code, 0)
        archives = self.archives()
        self.assertEqual(len(archives), 1)
        self.assertRegex(archives[0].name, r"^old-copies-\d{8}-\d{4}\.tar\.gz$")
        with tarfile.open(archives[0], "r:gz") as tar:
            members = {m.name: m.size for m in tar.getmembers()}
        self.assertEqual(members, sizes)
        for p in expected:
            self.assertFalse(p.exists(), p)
        for p in [*self.young, self.feed, self.script, *self.bystanders]:
            self.assertTrue(p.exists(), p)
        self.assertEqual(len(sent), 1)
        log = (self.ws / "logs" / "backup-tidy.log").read_text(encoding="utf-8")
        self.assertIn("6 копий", log)

    def test_message_text(self) -> None:
        self.assertEqual(
            tidy.owner_message(6, 3 * 1024 * 1024),
            "Прибрал 6 старых копий файлов, освободил 3 МБ. "
            "Они в архиве, если понадобятся — скажите.",
        )
        self.assertIn("освободил 0,5 МБ", tidy.owner_message(2, 512 * 1024))

    def test_silent_when_nothing_to_do(self) -> None:
        for p in self.expected_archived():
            p.unlink()
        code, _, sent = self.run_tidy()
        self.assertEqual(code, 0)
        self.assertEqual(sent, [])
        self.assertEqual(self.archives(), [])

    def test_second_run_is_noop(self) -> None:
        self.run_tidy()
        code, _, sent = self.run_tidy()
        self.assertEqual(code, 0)
        self.assertEqual(sent, [])
        self.assertEqual(len(self.archives()), 1)

    def test_corrupt_archive_removes_nothing(self) -> None:
        expected = self.expected_archived()

        def broken(ws: Path, files: list[Path], dest: Path) -> None:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(b"\x1f\x8b\x08\x00garbage")
            return {}

        with patch.object(tidy, "build_archive", side_effect=broken):
            code, _, sent = self.run_tidy()
        self.assertNotEqual(code, 0)
        for p in expected:
            self.assertTrue(p.exists(), p)
        self.assertEqual(sent, [])
        leftovers = list((self.ws / "archive" / "old-copies").glob("*"))
        self.assertEqual(leftovers, [], "a broken archive must not be left behind")
        log = (self.ws / "logs" / "backup-tidy.log").read_text(encoding="utf-8")
        self.assertIn("ничего не удалено", log)

    def test_archive_missing_member_removes_nothing(self) -> None:
        expected = self.expected_archived()
        real = tidy.build_archive

        def short(ws: Path, files: list[Path], dest: Path) -> dict[str, str]:
            return real(ws, files[1:], dest)

        with patch.object(tidy, "build_archive", side_effect=short):
            code, _, _ = self.run_tidy()
        self.assertNotEqual(code, 0)
        for p in expected:
            self.assertTrue(p.exists(), p)

    def test_build_archive_returns_sha256_of_what_it_packed(self) -> None:
        files = sorted(self.expected_archived())
        dest = self.ws / "check.tar.gz"
        digests = tidy.build_archive(self.ws, files, dest)
        self.assertEqual(digests, {f.relative_to(self.ws).as_posix(): sha(f) for f in files})
        self.assertEqual(tidy.verify_archive(self.ws, files, dest, digests), [])

    def test_same_size_content_mismatch_fails_verification(self) -> None:
        files = sorted(self.expected_archived())
        digests = tidy.build_archive(self.ws, files, self.ws / "good.tar.gz")
        same_size_rewrite(files[0])
        bad = self.ws / "bad.tar.gz"
        tidy.build_archive(self.ws, files, bad)
        problems = tidy.verify_archive(self.ws, files, bad, digests)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(files[0].relative_to(self.ws).as_posix(), problems[0])

    def test_member_without_recorded_sha_fails_verification(self) -> None:
        files = sorted(self.expected_archived())
        dest = self.ws / "check.tar.gz"
        digests = tidy.build_archive(self.ws, files, dest)
        digests.pop(files[0].relative_to(self.ws).as_posix())
        self.assertTrue(tidy.verify_archive(self.ws, files, dest, digests))

    def test_archive_content_differs_from_packed_removes_nothing(self) -> None:
        """Packed content (same size) is not what was hashed: no delete, exit 1."""
        expected = self.expected_archived()
        real = tidy.build_archive

        def drifted(ws: Path, files: list[Path], dest: Path) -> dict[str, str]:
            before = {f.relative_to(ws).as_posix(): sha(f) for f in files}
            same_size_rewrite(files[0])
            real(ws, files, dest)
            return before

        with patch.object(tidy, "build_archive", side_effect=drifted):
            code, _, sent = self.run_tidy()
        self.assertNotEqual(code, 0)
        for p in expected:
            self.assertTrue(p.exists(), p)
        self.assertEqual(sent, [])
        self.assertEqual(list((self.ws / "archive" / "old-copies").glob("*")), [])

    def test_copy_changed_after_packing_is_kept(self) -> None:
        """Archive is sound, but one copy changed (same size) before its delete."""
        expected = sorted(self.expected_archived())
        changed = expected[0]
        real = tidy.build_archive

        def then_change(ws: Path, files: list[Path], dest: Path) -> dict[str, str]:
            digests = real(ws, files, dest)
            same_size_rewrite(changed)
            return digests

        with patch.object(tidy, "build_archive", side_effect=then_change):
            code, _, sent = self.run_tidy()
        self.assertEqual(code, 0)
        self.assertTrue(changed.exists(), "a copy changed after packing must stay")
        for p in expected[1:]:
            self.assertFalse(p.exists(), p)
        self.assertEqual(len(sent), 1)
        self.assertIn("Прибрал 5 ", sent[0])
        log = (self.ws / "logs" / "backup-tidy.log").read_text(encoding="utf-8")
        self.assertIn(changed.relative_to(self.ws).as_posix(), log)
        self.assertIn("оставил", log)

    def test_dry_run_changes_nothing(self) -> None:
        before = {p: p.stat().st_mtime for p in self.ws.rglob("*")}
        code, out, sent = self.run_tidy("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(sent, [])
        after = {p: p.stat().st_mtime for p in self.ws.rglob("*")}
        self.assertEqual(before, after)
        self.assertIn("6 копий", out)
        self.assertIn("feed-2.xlsx", out)
        self.assertIn("tg-send.py", out)


if __name__ == "__main__":
    unittest.main()
