#!/usr/bin/env python3
"""What REALLY runs on a topic: cron lines, systemd units, log freshness -- one command.

Born from a class of mistakes: a subsystem's status taken from a neighbouring log,
from a function existing in the code or from a file header, while the rule is
simple -- look at the cron and at the time of the last run.

    bin/whatruns.py price
    bin/whatruns.py --selftest
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("__WORKSPACE__")
CLAUDE_DIR = Path("__CLAUDE_DIR__")
STALE_H = 26          # a log older than a day (with margin) is a reason to doubt
# A commented-out line that still looks like a schedule ("#40 19 * * * cmd").
DISABLED_JOB = re.compile(r"#.*\d+\s+\S+\s+\*")


def classify(lines: list[str], word: str) -> list[tuple[bool, str]]:
    """[(enabled, text)] -- a commented-out job does NOT run; a pure comment is skipped."""
    rows = []
    for ln in lines:
        s = ln.strip()
        if not s or word.lower() not in s.lower():
            continue
        if s.startswith("#") and not DISABLED_JOB.search(s):
            continue
        rows.append((not s.startswith("#"), s))
    return rows


def cron_lines(word: str) -> list[tuple[bool, str]]:
    out = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    return classify(out.splitlines(), word)


def _units_out(user: bool) -> str:
    cmd = ["systemctl"] + (["--user"] if user else []) + \
          ["list-units", "--all", "--no-legend", "--plain"]
    env = dict(os.environ)
    # The agent session and cron start with a stripped env: without the runtime
    # dir `systemctl --user` cannot reach the user manager.
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    try:
        return subprocess.run(cmd, capture_output=True, text=True, env=env,
                              timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def units(word: str) -> list[str]:
    res = []
    for user in (False, True):
        tag = "user" if user else "system"
        for ln in _units_out(user).splitlines():
            parts = ln.split()
            if len(parts) >= 4 and word.lower() in parts[0].lower():
                res.append(f"[{tag}] {parts[0]} — {parts[2]}/{parts[3]}")
    return res


def logs(word: str) -> list[str]:
    res = []
    for p in sorted((ROOT / "logs").glob(f"*{word}*")):
        age_h = (time.time() - p.stat().st_mtime) / 3600
        mark = " -- давно" if age_h > STALE_H else ""
        res.append(f"{p.name} — {age_h:.1f} ч назад, {p.stat().st_size} б{mark}")
    return res


def _wired_text() -> str:
    """Hooks are wired in settings.json, not in cron -- read it so they are not orphans."""
    out = []
    for p in (CLAUDE_DIR / "settings.json", Path.home() / ".claude/settings.json"):
        try:
            out.append(p.read_text(errors="replace"))
        except OSError:
            pass
    return "\n".join(out)


def orphans(word: str, cron_text: str) -> list[str]:
    """Topic scripts that appear in no cron line (nor in settings.json for hooks)."""
    wired = cron_text + "\n" + _wired_text()
    res = []
    for d in (ROOT / "bin", ROOT / "hooks", CLAUDE_DIR / "hooks"):
        if not d.is_dir():
            continue
        for p in d.glob(f"*{word}*"):
            if p.is_file() and p.name not in wired:
                res.append(str(p))
    return res


def report(word: str) -> str:
    cr = cron_lines(word)
    cron_text = "\n".join(t for _, t in cr)
    L = [f"== что бежит по теме «{word}»"]
    L.append("-- крон:")
    L += [f"   {'ВКЛ ' if on else 'ВЫКЛ'} {t[:110]}" for on, t in cr] or ["   ничего"]
    L.append("-- сервисы (system и --user):")
    L += [f"   {u}" for u in units(word)] or ["   ничего"]
    L.append("-- логи:")
    L += [f"   {x}" for x in logs(word)] or ["   ничего"]
    orp = orphans(word, cron_text)
    if orp:
        L.append("-- нет в кроне напрямую (может звать другой скрипт — проверь, "
                 "прежде чем звать мёртвым):")
        L += [f"   {x}" for x in orp]
    return "\n".join(L)


def selftest() -> None:
    # A disabled job must not read as running; a header comment is not a job.
    lines = ["#(pilot over) 40 19 * * * /usr/bin/python3 bin/pilot/daily.py",
             "*/2 * * * * bin/pilot-cycle.sh --if-new",
             "# pilot: header comment"]
    got = classify(lines, "pilot")
    assert len(got) == 2, got
    assert got[0][0] is False and got[1][0] is True, got
    assert classify(lines, "nothing-here") == []
    assert STALE_H > 24
    # Units listing must not crash even where systemctl is absent.
    assert isinstance(units("zz-no-such-unit-zz"), list)
    print("whatruns selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif len(sys.argv) < 2:
        print(__doc__)
    else:
        print(report(sys.argv[1]))
