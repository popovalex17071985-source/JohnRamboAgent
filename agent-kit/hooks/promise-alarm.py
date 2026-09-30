#!/usr/bin/env python3
"""Stop hook: a promise to continue must set its own alarm.

19.09.2026, owner's words: «как нам сделать так, чтобы ты не забывал браться и
делать задачи». The failure is structural, not moral -- when a turn ends the
agent has no process of its own, so «беру правку 4, вернусь с прогоном» is a
promise nothing enforces: the next wake-up comes from the owner's ping.

So the promise itself arms a machine alarm. This hook reads the turn's final
text, and when it finds a forward commitment («беру», «вернусь», «дальше»,
«продолжу»…) it schedules bin/remind-at.sh a few minutes out, which pokes the
live pane with «ПРОДОЛЖАЙ: <the promise>». Nothing is blocked -- the turn ends
normally and the agent is woken by a cron line that outlives the session.

Dedup: at most one alarm per DELAY_MIN window, keyed by the promise text, so a
chain of turns about the same task does not pile up alarms.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

WORKSPACE = Path("__WORKSPACE__")
STATE_PATH = WORKSPACE / "state" / "promise-alarm.json"
LOG_PATH = WORKSPACE / "logs" / "promise-alarm.log"
OWNER_TZ = ZoneInfo(os.environ.get("OWNER_TZ", "Asia/Yekaterinburg"))
DELAY_MIN = 4
COOLDOWN_MIN = 5
MAX_PROMISE_CHARS = 180

# Forward commitments: «I take it / I'll be back / next up / I'm starting».
# Leading \b matters: without it «соберу»/«разберу» matched «беру» and armed
# alarms for plain future-tense verbs (30.09.2026, three false wake-ups in a row).
PROMISE_RE = re.compile(
    r"\b(беру(сь)?\b|берусь\b|вернусь\b|возвращаюсь\b|продолж(у|аю)\b|"
    r"дальше\s+(правк|задач|пункт|шаг)|иду\s+(делать|копать|править)|"
    r"сейчас\s+(сделаю|займусь)|запустил,?\s+вернусь|отчитаюсь\b)",
    re.IGNORECASE,
)
# A turn that merely reports a finished thing is not a promise.
DONE_ONLY_RE = re.compile(r"^(готово|сделано|закрыто)[.!]?$", re.IGNORECASE)
QUOTED_RE = re.compile(r"«[^»]*»")
# A commitment that waits on the owner («когда пришлёшь ссылку -- разберу»,
# «ответит -- соберу сводку») is not mine to resume: the alarm would wake me to
# a task that is blocked on him. Such sentences are skipped.
CONDITIONAL_RE = re.compile(
    r"^\W*(если|когда|как\s+только|после\s+(его|твоего|её|их)|"
    r"ответит|ответишь|пришлёт|пришлёшь|кинет|кинешь|скажет|скажешь|назовёт|назовёшь)\b",
    re.IGNORECASE,
)


def log(line: str) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(OWNER_TZ).strftime("%d.%m %H:%M")
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {line}\n")
    except OSError:
        pass


def final_text(transcript_path: str) -> str:
    """Last assistant text of the transcript (tail-read, newest first)."""
    try:
        with open(transcript_path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            start = max(0, size - 2 * 1024 * 1024)
            fh.seek(start)
            buf = fh.read(size - start)
    except OSError:
        return ""
    lines = buf.decode("utf-8", errors="replace").split("\n")
    if start > 0 and lines:
        lines = lines[1:]
    for raw in reversed([line for line in lines if line.strip()]):
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        message = obj.get("message") if isinstance(obj, dict) else None
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        parts = [
            block["text"]
            for block in content
            if isinstance(block, dict)
            and block.get("type") == "text"
            and isinstance(block.get("text"), str)
        ]
        if parts:
            return "\n".join(parts)
    return ""


def promise_sentence(text: str) -> str | None:
    """The sentence carrying the commitment, trimmed for a pane message."""
    # A newline ENDS a sentence on its own: `(?<=\n)\s+` needed a second space
    # after it, so a heading line with no full stop glued itself to the promise
    # below and the pane got «Итог: тесты прошли\nВернусь…» as the commitment.
    for chunk in re.split(r"(?<=[.!?])\s+|\n+", text):
        chunk = chunk.strip()
        if not chunk or DONE_ONLY_RE.match(chunk) or CONDITIONAL_RE.match(chunk):
            continue
        # A verb inside «…» is a quotation (a report ABOUT the word «беру»),
        # not my commitment -- 30.09.2026 such a report armed an alarm.
        if PROMISE_RE.search(QUOTED_RE.sub("", chunk)):
            return chunk[:MAX_PROMISE_CHARS]
    return None


def recently_armed(promise: str) -> bool:
    key = hashlib.sha256(promise.encode("utf-8")).hexdigest()[:12]
    now = datetime.now(OWNER_TZ)
    try:
        prior = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        when = datetime.fromisoformat(prior["armed_at"])
        if prior.get("key") == key and now - when < timedelta(minutes=COOLDOWN_MIN):
            return True
    except (OSError, ValueError, KeyError, TypeError):
        pass
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(
            json.dumps({"key": key, "armed_at": now.isoformat(), "promise": promise}),
            encoding="utf-8",
        )
    except OSError:
        pass
    return False


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    transcript = payload.get("transcript_path")
    if not isinstance(transcript, str) or not transcript:
        return 0
    promise = promise_sentence(final_text(transcript))
    if promise is None:
        return 0
    if recently_armed(promise):
        log(f"будильник уже стоит: {promise[:60]}")
        return 0
    fire_at = datetime.now(OWNER_TZ) + timedelta(minutes=DELAY_MIN)
    when = fire_at.strftime("%d.%m %H:%M")
    message = (
        f"ПРОДОЛЖАЙ БЕЗ НАПОМИНАНИЯ: ты обещал -- «{promise}». "
        "Делай молча до результата, потом один отчёт в чат."
    )
    try:
        subprocess.run(
            [str(WORKSPACE / "bin" / "remind-at.sh"), when, message],
            check=False,
            capture_output=True,
            timeout=20,
        )
        log(f"поставил будильник на {when}: {promise[:60]}")
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"будильник не встал ({exc}): {promise[:60]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
