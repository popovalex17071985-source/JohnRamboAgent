#!/usr/bin/env python3
"""Bring an agent's OpenViking config up to v0.5.0 -- idempotent, run as root or owner.

1. ov.conf: pin the data dir (storage.workspace). Until v0.4.20 the image ran in
   /app, so the default relative "./data" was /app/data -- the appdata volume
   every installer mounts. Since v0.4.21 the image runs in /app/.openviking,
   "./data" became /app/.openviking/data and the server started on an empty
   store: memory «disappeared» after the upgrade (Smith and Jarvis, 28.09 and
   05.10.2026; root cause found 12.10.2026).
   An explicit absolute workspace is never touched. Otherwise it is set to where
   the store actually lives, so the change never moves an agent off its data:
     /app/data              -- the appdata volume (default, every <=0.4.20 store);
     /app/.openviking/data  -- only when the store sits there and appdata is empty
                               (an agent first started on >=0.4.21 with no pin).

2. With --server-version: the memory plugin's scoreThreshold follows the server's
   score scale. Since v0.4.22 similarity is (cos + 1) / 2, so the old default 0.25
   let everything through; it maps to 0.625. Only our two defaults are swapped
   (0.25 <-> 0.625) -- an owner's own value stays.

Files keep their mode and owner. Prints one line per change.

Usage: ov-conf-fix.py OV_DIR [--server-version vX.Y.Z]
       (OV_DIR = the host dir mounted at /app/.openviking, e.g. ~/.openviking)
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

APPDATA_WS = "/app/data"                # host: OV_DIR/appdata (the data volume)
LEGACY_WS = "/app/.openviking/data"     # host: OV_DIR/data (unpinned >=0.4.21 store)
STORE_MARKER = "viking"                 # OpenViking keeps its file tree here
PLUGIN_CONF = "claude-code-memory-plugin/config.json"
NEW_SCALE_SINCE = (0, 4, 22)
OLD_SCALE_THRESHOLD = 0.25              # plugin default on raw cosine
NEW_SCALE_THRESHOLD = 0.625             # the same on (cos + 1) / 2


def has_store(path: Path) -> bool:
    marker = path / STORE_MARKER
    return marker.is_dir() and any(marker.iterdir())


def pick_workspace(ov_dir: Path) -> str:
    if has_store(ov_dir / "data") and not has_store(ov_dir / "appdata"):
        return LEGACY_WS
    return APPDATA_WS


def write_json_like(path: Path, data: dict) -> None:
    """Atomic rewrite that keeps the file's mode and owner."""
    st = path.stat()
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.chmod(tmp, st.st_mode & 0o777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass  # not root: the file is ours already
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def ensure_workspace(ov_dir: Path) -> tuple[str, str]:
    """Returns (status, workspace): status is kept | set | missing."""
    conf = ov_dir / "ov.conf"
    if not conf.is_file() or conf.stat().st_size == 0:
        return "missing", ""
    cfg = json.loads(conf.read_text(encoding="utf-8"))
    storage = cfg.get("storage") if isinstance(cfg.get("storage"), dict) else {}
    current = storage.get("workspace")
    if isinstance(current, str) and current.startswith("/"):
        return "kept", current
    ws = pick_workspace(ov_dir)
    cfg["storage"] = {**storage, "workspace": ws}
    write_json_like(conf, cfg)
    return "set", ws


def server_scale(version: str) -> str:
    """new | old | "" (unknown -- leave thresholds alone)."""
    nums = tuple(int(x) for x in re.findall(r"\d+", version or "")[:3])
    if not nums:
        return ""
    return "new" if nums >= NEW_SCALE_SINCE else "old"


def align_plugin_threshold(ov_dir: Path, version: str) -> tuple[float, float] | None:
    """Swap the plugin's default scoreThreshold to the server's scale; (old, new) if changed."""
    path = ov_dir / PLUGIN_CONF
    scale = server_scale(version)
    if not scale or not path.is_file():
        return None
    cfg = json.loads(path.read_text(encoding="utf-8"))
    want, other = ((NEW_SCALE_THRESHOLD, OLD_SCALE_THRESHOLD) if scale == "new"
                   else (OLD_SCALE_THRESHOLD, NEW_SCALE_THRESHOLD))
    if cfg.get("scoreThreshold") != other:
        return None
    cfg["scoreThreshold"] = want
    write_json_like(path, cfg)
    return other, want


def main(argv: list[str]) -> int:
    args = argv[1:]
    version = ""
    if "--server-version" in args:
        i = args.index("--server-version")
        version = args[i + 1] if i + 1 < len(args) else ""
        del args[i:i + 2]
    if len(args) != 1:
        print("Usage: ov-conf-fix.py OV_DIR [--server-version vX.Y.Z]", file=sys.stderr)
        return 2
    ov_dir = Path(args[0])
    try:
        status, ws = ensure_workspace(ov_dir)
        moved = align_plugin_threshold(ov_dir, version)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ov.conf: не смог прочитать/записать ({type(exc).__name__})", file=sys.stderr)
        return 1
    if status == "set":
        print(f"ov.conf: папка данных закреплена -> {ws}")
        if ws == APPDATA_WS and has_store(ov_dir / "data"):
            print(f"ov.conf: ! в {ov_dir / 'data'} тоже лежит память (записи с образа без "
                  "закрепления) -- не трогаю, разобрать вручную")
    elif status == "kept":
        print(f"ov.conf: папка данных уже закреплена ({ws})")
    if moved:
        print(f"плагин памяти: порог {moved[0]} -> {moved[1]} (сервер {version})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
