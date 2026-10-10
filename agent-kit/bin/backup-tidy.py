#!/usr/bin/env python3
"""Weekly tidy of old backup copies an agent leaves behind.

Agents copy a file before every edit (`x.py.bak-20.09`, `feed.xlsx.bak-names-
1790878214`, `y.sh.orig`) and never clean up: agent «Гор» carried 714 copies,
964 MB, 688 of them old copies of one price feed.

Per (directory, original name) the tidy KEEPS the newest KEEP_NEWEST copies and
every copy younger than KEEP_YOUNGER_DAYS. Everything older is packed into ONE
archive per run, `archive/old-copies/old-copies-YYYYMMDD-HHMM.tar.gz`; the
sha256 of every copy is taken from the very bytes packed; the archive is then
re-opened and every member re-read to the end and checked (present, same
sha256) and ONLY THEN the originals are removed. A failed check removes nothing
and exits non-zero. Right before each delete the copy is hashed again: one that
changed since it was packed (even to the same size) stays and is logged. Files
that are not copies are never touched.

The owner hears one plain line only when something was archived.

Usage: backup-tidy.py [--workspace DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import stat
import subprocess
import sys
import tarfile
import time
import zlib
from collections import defaultdict
from datetime import datetime
from pathlib import Path

KEEP_NEWEST = 5
KEEP_YOUNGER_DAYS = 14
SECONDS_PER_DAY = 86400
MB = 1024 * 1024
WHOLE_MB_FROM = 10  # below this many MB the message shows one decimal
TOP_GROUPS = 10  # groups listed by --dry-run
NOTIFY_TIMEOUT_S = 30
READ_CHUNK = 1024 * 1024

ARCHIVE_REL = Path("archive") / "old-copies"
LOG_REL = Path("logs") / "backup-tidy.log"
# Never descend into these by name: VCS internals, dependency trees, caches and
# toolchains. A package cache may ship its own *.orig files; they are not ours.
SKIP_DIR_NAMES = frozenset({
    ".git", "node_modules", "__pycache__",
    ".cache", ".npm", ".bun", ".cargo", ".rustup", ".local",
    ".venv", "venv", "site-packages", "dist-packages",
})
# Workspace-relative trees that are not ours to tidy: our own archive, and the
# third-party plugin cache of Claude Code.
SKIP_REL = (ARCHIVE_REL, Path(".claude") / "plugins")
# hooks/protect-archive.sh guards */core/archive/ (COLD memory) and keeps its own
# snapshots in core/archive/.bak/ -- that directory is never ours to prune.
PROTECTED_TAIL = ("core", "archive")

# `<orig>.bak<anything not a letter>` or `<orig>.orig`. `.bak` must not run on
# into a word: `notes.bakery` is a real file, not a copy.
COPY_RE = re.compile(r"^(?P<orig>.+?)\.(?:bak(?:[^A-Za-z].*)?|orig)$", re.DOTALL)

RENDERED_WORKSPACE = "__WORKSPACE__"


def workspace_default() -> Path:
    """The rendered workspace, or the dir above bin/ when run from the kit tree."""
    if not RENDERED_WORKSPACE.startswith("__"):
        return Path(RENDERED_WORKSPACE)
    return Path(__file__).resolve().parent.parent


def original_name(name: str) -> str | None:
    """Name of the file this one is a copy of, or None if it is not a copy."""
    match = COPY_RE.match(name)
    return match.group("orig") if match else None


def _skip_dir(ws: Path, path: Path) -> bool:
    if path.name in SKIP_DIR_NAMES:
        return True
    if (path.parent.name, path.name) == PROTECTED_TAIL:
        return True
    rel = path.relative_to(ws)
    return any(rel == skip for skip in SKIP_REL)


def find_copies(ws: Path) -> dict[tuple[Path, str], list[Path]]:
    """Regular-file copies under the workspace, grouped by (dir, original name)."""
    groups: dict[tuple[Path, str], list[Path]] = defaultdict(list)
    for root, dirnames, filenames in os.walk(ws, followlinks=False):
        here = Path(root)
        dirnames[:] = [d for d in dirnames if not _skip_dir(ws, here / d)]
        for name in filenames:
            orig = original_name(name)
            if orig is None:
                continue
            path = here / name
            try:
                if not stat.S_ISREG(path.lstat().st_mode):
                    continue
            except OSError:
                continue
            groups[(here, orig)].append(path)
    return dict(groups)


def select_old(groups: dict[tuple[Path, str], list[Path]], now: float) -> list[Path]:
    """Copies beyond the newest KEEP_NEWEST of their group AND older than the cut."""
    cut = now - KEEP_YOUNGER_DAYS * SECONDS_PER_DAY
    picked: list[Path] = []
    for files in groups.values():
        dated = []
        for path in files:
            try:
                dated.append((path.lstat().st_mtime, path))
            except OSError:
                continue
        dated.sort(key=lambda pair: pair[0], reverse=True)
        picked.extend(path for mtime, path in dated[KEEP_NEWEST:] if mtime < cut)
    return sorted(picked)


class _HashingReader:
    """File reader that feeds every byte it hands out into a sha256."""

    def __init__(self, fh: io.BufferedReader) -> None:
        self._fh = fh
        self.digest = hashlib.sha256()

    def read(self, size: int = -1) -> bytes:
        data = self._fh.read(size)
        self.digest.update(data)
        return data


def _open_regular(path: Path) -> io.BufferedReader:
    """Open `path` for reading without following a symlink swapped in for it."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    return os.fdopen(fd, "rb")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with _open_regular(path) as fh:
        while chunk := fh.read(READ_CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def build_archive(ws: Path, files: list[Path], dest: Path) -> dict[str, str]:
    """Pack `files` (paths relative to the workspace) into a new tar.gz at `dest`.

    Returns {archive name: sha256} of the exact bytes packed for each file.
    Created 0600: copies of config files may carry credentials.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    digests: dict[str, str] = {}
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as raw, tarfile.open(fileobj=raw, mode="w:gz") as tar:
        for path in files:
            name = path.relative_to(ws).as_posix()
            with _open_regular(path) as fh:
                info = tar.gettarinfo(arcname=name, fileobj=fh)
                if not info.isfile():
                    raise OSError(f"не обычный файл: {path}")
                reader = _HashingReader(fh)
                tar.addfile(info, reader)
            digests[name] = reader.digest.hexdigest()
    return digests


def verify_archive(ws: Path, files: list[Path], archive: Path,
                   digests: dict[str, str]) -> list[str]:
    """Problems found re-reading the archive; an empty list means it is sound.

    Every member is read to the end and its sha256 compared with `digests`,
    taken while packing: a same-size change does not slip through.
    """
    want: dict[str, str] = {}
    for path in files:
        name = path.relative_to(ws).as_posix()
        if name not in digests:
            return [f"нет контрольной суммы: {name}"]
        want[name] = digests[name]
    seen: dict[str, str] = {}
    try:
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar:
                if not member.isfile():
                    return [f"в архиве не файл: {member.name}"]
                handle = tar.extractfile(member)
                if handle is None:
                    return [f"в архиве не читается: {member.name}"]
                read = 0
                digest = hashlib.sha256()
                while chunk := handle.read(READ_CHUNK):
                    read += len(chunk)
                    digest.update(chunk)
                if read != member.size:
                    return [f"в архиве обрезан: {member.name}"]
                seen[member.name] = digest.hexdigest()
    except (tarfile.TarError, OSError, EOFError, zlib.error) as exc:
        return [f"архив не открывается: {exc}"]
    problems = [f"нет в архиве: {name}" for name in sorted(set(want) - set(seen))]
    problems += [
        f"содержимое не совпало: {name}"
        for name, sha in sorted(want.items())
        if name in seen and seen[name] != sha
    ]
    return problems


def fmt_mb(size: int) -> str:
    """Bytes -> «3», «0,5», «964»: whole MB from WHOLE_MB_FROM up, else one decimal."""
    mb = size / MB
    if mb >= WHOLE_MB_FROM:
        return str(round(mb))
    text = f"{mb:.1f}".replace(".", ",")
    return text[:-2] if text.endswith(",0") else text


def owner_message(count: int, freed: int) -> str:
    return (
        f"Прибрал {count} старых копий файлов, освободил {fmt_mb(freed)} МБ. "
        "Они в архиве, если понадобятся — скажите."
    )


def log(ws: Path, line: str) -> None:
    path = ws / LOG_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(f"{stamp} {line}\n")


def notify(ws: Path, text: str) -> None:
    sender = ws / "bin" / "tg-send.py"
    if not sender.exists():
        log(ws, f"нет {sender} -- хозяину не отправлено")
        return
    try:
        subprocess.run([sys.executable, str(sender), text], check=False, timeout=NOTIFY_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError) as exc:
        log(ws, f"не смог отправить хозяину: {exc}")


def archive_path(ws: Path, now: float) -> Path:
    base = f"old-copies-{datetime.fromtimestamp(now).strftime('%Y%m%d-%H%M')}"
    folder = ws / ARCHIVE_REL
    dest = folder / f"{base}.tar.gz"
    n = 2
    while dest.exists():
        dest = folder / f"{base}-{n}.tar.gz"
        n += 1
    return dest


def sizes_of(files: list[Path]) -> dict[Path, int]:
    out: dict[Path, int] = {}
    for path in files:
        try:
            out[path] = path.lstat().st_size
        except OSError:
            continue
    return out


def dry_run(ws: Path, groups: dict[tuple[Path, str], list[Path]], old: list[Path]) -> int:
    sizes = sizes_of(old)
    total = sum(len(files) for files in groups.values())
    print("Пробный прогон -- ничего не меняю.")
    print(
        f"В архив ушли бы {len(old)} копий, {fmt_mb(sum(sizes.values()))} МБ; "
        f"остались бы {total - len(old)} копий."
    )
    per_group: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for path, size in sizes.items():
        key = (path.parent / original_name(path.name)).relative_to(ws).as_posix()
        per_group[key][0] += 1
        per_group[key][1] += size
    top = sorted(per_group.items(), key=lambda kv: (-kv[1][1], -kv[1][0], kv[0]))
    for name, (count, size) in top[:TOP_GROUPS]:
        print(f"  {name}: копий {count}, {fmt_mb(size)} МБ")
    return 0


def run(ws: Path, now: float) -> int:
    groups = find_copies(ws)
    old = select_old(groups, now)
    if not old:
        total = sum(len(files) for files in groups.values())
        log(ws, f"нечего убирать: копий {total}, все свежие или в пятёрке новых")
        return 0

    dest = archive_path(ws, now)
    part = dest.with_name(f".{dest.name}.part")
    try:
        digests = build_archive(ws, old, part)
        problems = verify_archive(ws, old, part, digests)
    except (OSError, tarfile.TarError) as exc:
        problems = [f"архив не собрался: {exc}"]
    if problems:
        part.unlink(missing_ok=True)
        msg = (
            f"ОШИБКА: архив старых копий не прошёл проверку, ничего не удалено "
            f"({len(problems)} проблем; первая: {problems[0]})"
        )
        log(ws, msg)
        print(msg, file=sys.stderr)
        return 1
    part.rename(dest)

    removed = 0
    removed_bytes = 0
    for path, size in sizes_of(old).items():
        rel = path.relative_to(ws).as_posix()
        try:
            changed = file_sha256(path) != digests[rel]
        except OSError as exc:
            log(ws, f"не смог перепроверить {rel}: {exc} -- оставил на месте")
            continue
        if changed:
            log(ws, f"{rel} изменился после упаковки -- оставил на месте, в архиве прежняя версия")
            continue
        try:
            path.unlink()
        except OSError as exc:
            log(ws, f"не смог удалить {path}: {exc} (копия есть в архиве)")
            continue
        removed += 1
        removed_bytes += size
    freed = max(0, removed_bytes - dest.stat().st_size)
    log(
        ws,
        f"убрал {removed} копий ({fmt_mb(removed_bytes)} МБ) в "
        f"{dest.relative_to(ws).as_posix()}, освобождено {fmt_mb(freed)} МБ",
    )
    if removed:
        notify(ws, owner_message(removed, freed))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Уборка старых копий файлов")
    ap.add_argument("--workspace", default=None)
    ap.add_argument("--dry-run", action="store_true", help="показать, ничего не менять")
    args = ap.parse_args(argv)
    ws = Path(args.workspace) if args.workspace else workspace_default()
    if not ws.is_dir():
        print(f"нет рабочей папки {ws}", file=sys.stderr)
        return 2
    now = time.time()
    if args.dry_run:
        groups = find_copies(ws)
        return dry_run(ws, groups, select_old(groups, now))
    return run(ws, now)


if __name__ == "__main__":
    sys.exit(main())
