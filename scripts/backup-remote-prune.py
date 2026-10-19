#!/usr/bin/env python3
"""Make room in the cloud for tonight's backup BEFORE uploading it.

agent-backup.sh deleted old cloud copies (age rule, DASHI_BACKUP_RETAIN days) only
AFTER a successful upload. When the owner's Drive filled up, the upload failed with
403 storageQuotaExceeded, nothing old was ever deleted, and the agent stayed stuck
with no fresh off-site copy (agent Albert, 17.10.2026). Jarvis hit the same dead end
on 19.10.2026.

Before the upload this helper deletes, among OUR archives only
(<agent>-YYYYMMDD-HHMM.tar.gz.gpg, exactly as agent-backup.sh names them):
  1. extra copies of a past day (all but the newest of that day);
  2. the oldest copies, while free space < tonight's archive + MARGIN,
never leaving fewer than KEEP_MIN of our copies. Anything else in the folder is
never touched. The age rule after a successful upload stays in agent-backup.sh.

If the remote cannot report free space (`rclone about` fails or has no "free"),
nothing is deleted: the upload goes ahead exactly as before this helper existed.

Usage: backup-remote-prune.py <remote:path> <agent> <need_bytes> [--dry]
Always exits 0 on remote trouble (the nightly run must go on); 2 on bad arguments.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime

KEEP_MIN = 2
MARGIN = 1 << 30  # 1 GiB left free for whatever else lives on that Drive
RCLONE_TIMEOUT_SEC = 300
GIB = float(1 << 30)


def archive_pattern(agent: str) -> re.Pattern[str]:
    """Our archive name, anchored: agent «foo» never matches «foo-bar-...» or a stray file."""
    return re.compile(rf"^{re.escape(agent)}-(\d{{8}})-(\d{{4}})\.tar\.gz\.gpg$")


def plan(names_sizes: list[tuple[str, int]], agent: str, free: int, need: int,
         today: str) -> list[str]:
    """Names to delete, in deletion order. Pure: no rclone, no clock."""
    rx = archive_pattern(agent)
    ours = sorted((m.group(1) + m.group(2), name, size)
                  for name, size in names_sizes if (m := rx.match(name)))
    newest_of_day: dict[str, str] = {}
    for stamp, name, _ in ours:
        newest_of_day[stamp[:8]] = name  # ascending order: the last one of a day wins
    left = list(ours)
    drop: list[str] = []
    for item in ours:
        stamp, name, size = item
        if len(left) <= KEEP_MIN:
            break
        if stamp[:8] != today and newest_of_day[stamp[:8]] != name:
            left.remove(item)
            drop.append(name)
            free += size
    while free < need + MARGIN and len(left) > KEEP_MIN:
        _, name, size = left.pop(0)
        drop.append(name)
        free += size
    return drop


def _rclone(rclone: str, *args: str) -> str:
    return subprocess.run([rclone, *args], check=True, capture_output=True, text=True,
                          timeout=RCLONE_TIMEOUT_SEC).stdout


def _free_bytes(rclone: str, remote: str) -> int | None:
    """Free space of the remote, or None when the remote does not report it."""
    try:
        free = json.loads(_rclone(rclone, "about", remote, "--json")).get("free")
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return None
    return int(free) if isinstance(free, (int, float)) and free >= 0 else None


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--dry"]
    dry = len(args) != len(argv)
    if len(args) != 3 or ":" not in args[0] or not args[1] or not args[2].isdigit():
        print("usage: backup-remote-prune.py <remote:path> <agent> <need_bytes> [--dry]",
              file=sys.stderr)
        return 2
    target, agent, need = args[0].rstrip("/"), args[1], int(args[2])
    rclone = os.environ.get("RCLONE_BIN") or "rclone"
    remote = target.split(":", 1)[0] + ":"
    free = _free_bytes(rclone, remote)
    if free is None:
        print(f"облако: {remote} не сообщает свободное место -- место не освобождаю, заливаю как раньше")
        return 0
    try:
        listing = json.loads(_rclone(rclone, "lsjson", "--files-only", target))
        files = [(str(f["Name"]), int(f["Size"])) for f in listing]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as e:
        print(f"облако: не смог прочитать список копий ({type(e).__name__}) -- ничего не удаляю")
        return 0
    drop = plan(files, agent, free, need, datetime.now().strftime("%Y%m%d"))
    deleted = 0
    for name in drop:
        if dry:
            print(f"облако: удалил бы {name}")
            continue
        try:
            _rclone(rclone, "deletefile", "--drive-use-trash=false", f"{target}/{name}")
        except (OSError, subprocess.SubprocessError) as e:
            print(f"облако: не смог удалить {name} ({type(e).__name__})")
            continue
        deleted += 1
        print(f"облако: удалил старую копию {name}")
    if drop or free < need + MARGIN:
        print(f"облако: свободно было {free / GIB:.1f} ГБ, архиву нужно {need / GIB:.1f} ГБ "
              f"+ запас 1 ГБ; удалено копий: {deleted}{' (пробный прогон)' if dry else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
