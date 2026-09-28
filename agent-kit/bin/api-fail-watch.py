#!/usr/bin/env python3
"""Сторож отказов внешних API по логам.

Раз в полчаса просматривает хвосты логов за последние N минут и, если один
источник подряд >=3 раза получил HTTP 401/403 или «пустой ответ» (пустая
таблица, квота, сетка), пишет хозяину в личку. Одна тревога на источник в день
(состояние в state/api-fail-watch.json) — иначе источник с тысячами отказов за
неделю засыпал бы чат.

  bin/api-fail-watch.py                 # все logs/*.log за 60 мин
  bin/api-fail-watch.py --minutes 180   # окно шире
  bin/api-fail-watch.py --logs logs/a.log logs/b.log
  bin/api-fail-watch.py --dry-run       # показать, что бы отправили, без Telegram и без записи состояния
  bin/api-fail-watch.py --selftest      # синтетический лог: тревога есть, второй раз в день — нет

Логи без штампа времени читаются по mtime файла: файл менялся в окне ->
смотрим последние TAIL_LINES строк.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = pathlib.Path("__WORKSPACE__")
CLAUDE_DIR = pathlib.Path("__CLAUDE_DIR__")
STATE = ROOT / "state/api-fail-watch.json"
NOTIFY = ROOT / "bin/tg-send.py"
THRESHOLD = 3            # столько ошибок одного класса подряд = тревога
TAIL_LINES = 400         # сколько хвоста читать у лога без штампов времени

# Every agent has its own set of logs -- watch them all, except our own and the
# watchers' logs, where an error line is a report about someone else (mirrors
# SKIP in job-fail-watch.py).
SKIP = {"api-fail-watch.log", "job-fail-watch.log", "job-watch.log", "self-audit.log",
        "health-daily.log", "auth-alive-watch.log", "claude-link-guard.log"}


def owner_tz() -> dt.tzinfo:
    """The owner's zone from core/owner-tz (written by install-kit.sh), else server local."""
    try:
        return ZoneInfo((CLAUDE_DIR / "core/owner-tz").read_text().strip())
    except (OSError, ValueError, ZoneInfoNotFoundError):
        return dt.datetime.now().astimezone().tzinfo


TZ = owner_tz()


def default_logs() -> list[pathlib.Path]:
    return [p for p in sorted((ROOT / "logs").glob("*.log")) if p.name not in SKIP]


# класс ошибки -> что считать ею. Проверяется по строке лога целиком.
ERROR_CLASSES: dict[str, re.Pattern[str]] = {
    "auth": re.compile(r"HTTP Error 40[13]\b|\b40[13] (Unauthorized|Forbidden)\b|status(=|: ?)40[13]\b"
                       r"|\"[A-Z]+ [^\"]+\" 40[13] "),
    "empty": re.compile(r"пуст(ой|ая|ую) (ответ|таблиц)|<table></table>"
                        r"|INCOMPLETE:|Quota exceeded|exceeds grid limits|empty (response|table)",
                        re.I),
}
# A line after which an error streak counts as broken (the source is alive again).
SUCCESS = re.compile(r"Done at |selfcheck ok|selftest ok|HTTP/1\.[01]\" 200 |status(=|: ?)200\b")
# строки, которые не считаются ни ошибкой, ни успехом (шум health-чеков)
IGNORE = re.compile(r"GET /health")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})")


def parse_stamp(line: str) -> dt.datetime | None:
    m = STAMP.match(line)
    if not m:
        return None
    return dt.datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}").replace(
        tzinfo=dt.datetime.now().astimezone().tzinfo)     # логи пишутся в локальном времени сервера


def window_lines(path: pathlib.Path, since: dt.datetime) -> list[str]:
    """Строки лога за окно. С штампами — по штампу; без — хвост, если файл менялся в окне."""
    if not path.exists():
        return []
    mtime = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc)
    if mtime < since:
        return []
    lines = path.read_text(errors="replace").splitlines()[-max(TAIL_LINES, 5000):]
    stamped = [ln for ln in lines if STAMP.match(ln)]
    if not stamped:
        return lines[-TAIL_LINES:]
    out = []
    for ln in lines:
        ts = parse_stamp(ln)
        if ts is None:
            continue          # трассировки без штампа относятся к предыдущей строке; их не считаем
        if ts >= since:
            out.append(ln)
    return out


def longest_streak(lines: list[str]) -> dict[str, tuple[int, str]]:
    """{класс: (макс. серия подряд, последняя строка серии)}."""
    streak: dict[str, int] = {}
    best: dict[str, tuple[int, str]] = {}
    for ln in lines:
        if IGNORE.search(ln):
            continue
        if SUCCESS.search(ln):
            streak.clear()
            continue
        for cls, rx in ERROR_CLASSES.items():
            if rx.search(ln):
                streak[cls] = streak.get(cls, 0) + 1
                if streak[cls] >= best.get(cls, (0, ""))[0]:
                    best[cls] = (streak[cls], ln.strip()[:160])
    return best


def load_state(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def scan(logs: list[pathlib.Path], minutes: int, state_path: pathlib.Path,
         send, dry_run: bool = False, now: dt.datetime | None = None) -> list[str]:
    """Возвращает список отправленных (или в dry-run — подготовленных) тревог."""
    now = now or dt.datetime.now(dt.timezone.utc)
    since = now - dt.timedelta(minutes=minutes)
    today = now.astimezone(TZ).date().isoformat()
    state = load_state(state_path)
    sent: list[str] = []
    for path in logs:
        source = path.stem
        best = longest_streak(window_lines(path, since))
        for cls, (n, last) in best.items():
            if n < THRESHOLD:
                continue
            key = f"{source}:{cls}"
            if state.get(key) == today:
                continue
            what = "HTTP 401/403 (доступ отклонён)" if cls == "auth" else "пустой ответ / квота / сетка"
            text = (f"Сторож API: {source} — {n} раз подряд {what} за последние {minutes} мин.\n"
                    f"Последняя строка: {last}\n"
                    f"Лог: {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
            sent.append(text)
            if not dry_run:
                send(text)
                state[key] = today
    if not dry_run:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(state, ensure_ascii=False, indent=1))
    return sent


def tg_send(text: str) -> None:
    subprocess.run([sys.executable, str(NOTIFY), text], check=False)


def selftest() -> int:
    import tempfile
    now = dt.datetime.now(dt.timezone.utc)

    def stamp(m: int) -> str:
        return (now - dt.timedelta(minutes=m)).astimezone().strftime("%Y-%m-%d %H:%M:%S,000")

    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        log = d / "fake-receiver.log"
        st = d / "state.json"
        # две ошибки подряд — не тревога
        log.write_text("\n".join([
            f"{stamp(30)} [WARNING] crm: контакт 1 не прочитан: HTTP Error 401: Unauthorized",
            f"{stamp(29)} [INFO] 127.0.0.1 - \"GET /health HTTP/1.1\" 200 -",
            f"{stamp(28)} [WARNING] crm: контакт 2 не прочитан: HTTP Error 401: Unauthorized",
        ]) + "\n")
        out: list[str] = []
        assert scan([log], 60, st, out.append, now=now) == [], "2 ошибки не должны будить"
        # третья подряд — тревога, health-чек между ними серию не рвёт
        with log.open("a") as fh:
            fh.write(f"{stamp(27)} [WARNING] crm: контакт 3 не прочитан: HTTP Error 401: Unauthorized\n")
        got = scan([log], 60, st, out.append, now=now)
        assert len(got) == 1 and "fake-receiver" in got[0] and "3 раз" in got[0], got
        assert out == got, "тревога должна уйти через send"
        # тот же день — второй раз не будим
        assert scan([log], 60, st, out.append, now=now) == [], "дубль в тот же день"
        assert len(out) == 1
        # успех между ошибками рвёт серию
        log2 = d / "other.log"
        log2.write_text("\n".join([
            f"{stamp(20)} [WARNING] x: HTTP Error 403: Forbidden",
            f"{stamp(19)} [INFO] sync: Done at 12:00",
            f"{stamp(18)} [WARNING] x: HTTP Error 403: Forbidden",
            f"{stamp(17)} [WARNING] x: HTTP Error 403: Forbidden",
        ]) + "\n")
        assert scan([log2], 60, st, out.append, now=now) == [], "успех рвёт серию"
        # старые ошибки вне окна не считаются
        log3 = d / "old.log"
        log3.write_text("\n".join(f"{stamp(500 + i)} [WARNING] HTTP Error 401: Unauthorized"
                                  for i in range(5)) + "\n")
        assert scan([log3], 60, st, out.append, now=now) == [], "вне окна"
        # лог без штампов: пустой ответ x3 -> тревога класса empty
        log4 = d / "nostamp.log"
        log4.write_text("\n".join(["fetch page=1: empty response, total=0"] * 3) + "\n")
        got = scan([log4], 60, st, out.append, now=now)
        assert len(got) == 1 and "пустой ответ" in got[0], got
        # dry-run ничего не шлёт и не запоминает
        st2 = d / "state2.json"
        got = scan([log], 60, st2, out.append, dry_run=True, now=now)
        assert len(got) == 1 and not st2.exists() and len(out) == 2
    # own and watcher logs are never scanned
    assert "api-fail-watch.log" in SKIP and "job-fail-watch.log" in SKIP
    assert TZ is not None
    print("api-fail-watch selftest ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--logs", nargs="*", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.logs is None:
        logs = default_logs()
    else:
        logs = [pathlib.Path(p) if pathlib.Path(p).is_absolute() else ROOT / p for p in a.logs]
    sent = scan(logs, a.minutes, STATE, tg_send, dry_run=a.dry_run)
    stamp = dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M")
    if sent:
        for t in sent:
            print(f"{stamp} {'DRY ' if a.dry_run else ''}ALERT: {t.splitlines()[0]}")
    else:
        print(f"{stamp} ok: тревог нет ({len(logs)} логов, окно {a.minutes} мин)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
