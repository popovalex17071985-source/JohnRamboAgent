#!/usr/bin/env python3
"""Провал конвейера -> я сам иду чинить, не жду вопроса хозяина.

Хозяин 13.09.2026: «лучше сделать так чтобы ошибок не было никогда нигде, а
если есть -- ты сам смотрел что есть, шёл чинил и потом объяснял». Поводом был
кроновый пуш: в чат ушло «ошибок 6» без причины, и разбор начался только после
его вопроса.

Сторож читает хвосты логов конвейеров, ищет следы провала и впечатывает задание
в мою живую панель. Одна тревога на подпись в сутки -- чтобы не долбить одним и
тем же, пока правка едет.

  bin/job-fail-watch.py            # проверить
  bin/job-fail-watch.py --dry-run  # показать, панель не трогать
  bin/job-fail-watch.py --selftest
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path("__WORKSPACE__")
STATE = ROOT / "state/job-fail-watch.json"
PANE = ROOT / "bin/pane-send-when-idle.sh"
TAIL_LINES = 300
FRESH_SEC = 3 * 3600      # лог не менялся 3 часа -- прогон давно прошёл, не дёргаем

# Набор логов у каждого агента свой -- смотрим все, кроме собственного и тех,
# где «ошибка» это нормальный отчёт сторожей.
# ov-memory / tmux-pane logs quote conversation text: a quoted «[СБОЙ ЗАДАНИЯ]»
# is not a failure (10.10.2026, false alarm on gorbot).
SKIP = {"job-fail-watch.log", "self-audit.log", "health-daily.log",
        "ov-memory.log", "tmux-pane.log", "tmux-pane.prev.log"}


def log_files() -> list[str]:
    out = []
    for p in sorted((ROOT / "logs").glob("*.log")):
        if p.name not in SKIP:
            out.append(f"logs/{p.name}")
    return out

# Следы провала. Счётчики со значением 0 -- норма, ловим только ненулевые.
FAIL_RX = [
    re.compile(r"\bfailed=([1-9]\d*)"),
    re.compile(r"ошибок[:\s]+([1-9]\d*)"),
    re.compile(r"сбоев[:\s]+([1-9]\d*)"),
    re.compile(r"\bСБОЙ\b"),
    re.compile(r"Traceback \(most recent call last\)"),
    # Kit scripts' own failure lines, anchored to the line start, a «[stamp] » /
    # «[name] » prefix or a «HH:MM:SS » stamp -- not FAILURES or «no FAIL here».
    # 11.10.2026: Albert's off-site backup failed 2 days, «[..] FAIL: off-site не
    # уехал» matched nothing. ОШИБКА: backup-tidy; ERROR: ov-session-sync.
    re.compile(r"(?:^|\]\s|\d\d:\d\d:\d\d\s)(?:FAIL|ОШИБКА):\s"),
    re.compile(r"\]\sERROR:\s"),
]


def hits(text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        if any(rx.search(line) for rx in FAIL_RX):
            out.append(line.strip()[:200])
    return out


def line_shape(line: str) -> str:
    """The line with every number replaced by N: the same failure with a new
    timestamp or count is one signature (was r'\\\\d+' -- matched a backslash).
    Kept outside the f-string: Python 3.10 on agents forbids a backslash there."""
    return re.sub(r'\d+', 'N', line)


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    state = load_state()
    offsets = state.setdefault("_offsets", {})
    today = time.strftime("%Y-%m-%d")
    found = []
    for rel in log_files():
        path = ROOT / rel
        if not path.exists() or time.time() - path.stat().st_mtime > FRESH_SEC:
            continue
        # Читаем ТОЛЬКО прирост с прошлого прогона: иначе давно починенная
        # ошибка в хвосте лога будит меня заново (13.09.2026, первый же вызов
        # сторожа поднял трейсбек трёхчасовой давности).
        size = path.stat().st_size
        start = offsets.get(rel, 0)
        if start > size:          # лог усекли или перезалили
            start = 0
        with path.open(errors="replace") as fh:
            fh.seek(start)
            fresh = fh.read()
        offsets[rel] = size
        if start == 0 and len(fresh.splitlines()) > TAIL_LINES:
            # первый прогон по этому логу: не разгребаем всю историю
            fresh = "\n".join(fresh.splitlines()[-TAIL_LINES:])
        for line in hits(fresh):
            shape = line_shape(line)
            sig = hashlib.sha1(f"{rel}|{shape}".encode()).hexdigest()[:12]
            if state.get(sig) == today:
                continue
            state[sig] = today
            found.append((rel, line))

    STATE.parent.mkdir(parents=True, exist_ok=True)
    if not args.dry_run:
        STATE.write_text(json.dumps(state))
    if not found:
        print("провалов нет")
        return 0

    lines = ["Сторож поймал провал в конвейере. Разберись и почини сам, потом объясни хозяину:"]
    lines += [f"  {rel}: {line}" for rel, line in found[:8]]
    task = " ".join(lines)
    print(task)
    if args.dry_run:
        return 0
    session = os.environ.get("DASHI_TMUX_SESSION") or _guess_session()
    if session:
        subprocess.run([str(PANE), session, task], check=False, timeout=30)
    STATE.write_text(json.dumps(state))
    return 0


def _guess_session() -> str:
    out = subprocess.run(["tmux", "ls", "-F", "#{session_name}"],
                         capture_output=True, text=True, check=False).stdout.split()
    return next((s for s in out if "__AGENT__" in s), out[0] if out else "")


def _selftest() -> None:
    assert hits("Done. pushed=6 failed=0") == []
    assert hits("Done. pushed=0 failed=6")
    assert hits("готово: 76, сбоев: 0") == []
    assert hits("готово: 70, сбоев: 6")
    assert hits("  #3 СБОЙ: на сайте 0 кнопок")
    assert hits("обычная строка лога") == []
    assert hits("[2026-10-11 03:41:49 +10] FAIL: off-site не уехал")
    assert hits("FAILURES: 0") == []
    print("job-fail-watch selftest: OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        sys.exit(main())
