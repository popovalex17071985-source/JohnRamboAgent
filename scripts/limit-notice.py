#!/usr/bin/env python3
"""limit-notice.py -- tell the owner when the Claude subscription limit is hit.

Called every minute by modal-watch.sh (same cron line, same agent user):
    limit-notice.py <tmux-session>

What it does, once per limit window:
  1. Bottom of the pane shows «You've hit your session limit · resets 3:40pm (Asia/...)»
     with the reset still in the future -> one notice to the owner with the time
     the agent will be back, plus the usage page where a free reset may be offered.
  2. The reset time has passed and no live limit is on screen -> one
     «Лимит отпустил, я снова на связи.».
  3. 10 min after the reset the rate-limit dialog is still open -> one escalation.

It NEVER presses keys. Lessons from the home-grown watchdog this replaces:
  * stray «1» presses aimed at the limit dialog leaked into the chat as owner
    messages (15.09.2026, ~a hundred of them);
  * in Claude Code 2.1.29x the auto-opened /rate-limit-options menu puts
    «Switch to usage credits» / «Upgrade your plan» FIRST on some accounts, so a
    blind «1» can switch the owner to paid usage. Esc would be the safe key, but
    the old watchdog's own log shows the line on screen is the error message,
    not a dialog: presses changed nothing. So we only report.

Lessons kept from it:
  * look at the pane TAIL only and only at lines that ARE the error message --
    the agent reading reports that quote the phrase was counted as a new hit
    (21.09.2026);
  * the error text lingers on screen after the reset; a line whose reset time is
    already in the past is old text, not a limit (16.09.2026);
  * one notice per window, state on disk (the old one flapped «limit / ready»).

Test hooks (env): LIMIT_PANE_FILE (pane text instead of tmux), LIMIT_NOW (epoch),
LIMIT_NOTIFY_CMD (command called with the text as $1), DASHI_WORKSPACE.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

TAIL_LINES = 25                 # the error line sits right above the input box
SAME_WINDOW_SEC = 120           # two parses of one reset time differ by < 2 min
SESSION_WINDOW_SEC = 5 * 3600   # a session limit never resets further out than 5h
WINDOW_SLACK_SEC = 5 * 60
ESCALATE_AFTER_SEC = 10 * 60
USAGE_URL = "https://claude.ai/settings/usage"
PERM_TZ = "Asia/Yekaterinburg"

# Only the subscription buckets. Spend-limit / usage-credit / team-budget lines
# are built by the same Claude Code helper («You've hit your monthly spend limit
# · ... · your session limit resets 3pm») -- anchoring the bucket name right
# after «your» keeps them out. «Fable limit» and «fast limit» are paid/fast
# lanes, not the subscription window, and stay out too.
LIMIT_RE = re.compile(
    r"^[\s⎿●⏺✻│▎*·-]*You['’]ve hit your (?P<kind>session|weekly|Opus|Sonnet)\b[^·]{0,20}?limit"
    r"\s*·\s*resets\s+(?P<when>[^()·]+?)\s*(?:\((?P<tz>[^)]+)\))?"
    r"\s*(?:·\s*progress saved\s*)?$"
)
LIMIT_START_RE = re.compile(r"^[\s⎿●⏺✻│▎*·-]*You['’]ve hit your ")
# Lines that are obviously command output (from the old watchdog, 21.09.2026).
COMMAND_OUTPUT_RE = re.compile(r"report\.txt|grep |cat |=== |\.log:|\.jsonl?:|[\"{}]")
WHEN_RE = re.compile(
    r"^(?:(?P<mon>[A-Z][a-z]{2}) (?P<day>\d{1,2}),(?: (?P<year>\d{4}),)? )?"
    r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s*(?P<ap>[ap]m)$",
    re.IGNORECASE,
)
MONTHS = {m: i for i, m in enumerate(
    "jan feb mar apr may jun jul aug sep oct nov dec".split(), start=1)}
DIALOG_RE = re.compile(r"What do you want to do\?")
DIALOG_OPTION_RE = re.compile(
    r"Stop and wait for limit to reset|Switch to usage|Upgrade your plan|Add funds to continue")


def resolve_workspace(agent: str) -> pathlib.Path | None:
    """$DASHI_WORKSPACE, else the install layout <ws>/.claude/dashi-plugin-claude-code/scripts/."""
    cands = []
    if os.environ.get("DASHI_WORKSPACE"):
        cands.append(pathlib.Path(os.environ["DASHI_WORKSPACE"]))
    here = pathlib.Path(__file__).resolve()
    if here.parent.name == "scripts" and here.parents[2].name == ".claude":
        cands.append(here.parents[3])
    cands.append(pathlib.Path.home() / ".claude-lab" / agent)
    for c in cands:
        if (c / ".claude").is_dir() or (c / "data").is_dir():
            return c
    return None


def owner_tz(ws: pathlib.Path) -> tuple[dt.tzinfo, str]:
    try:
        name = (ws / ".claude/core/owner-tz").read_text().strip()
        return ZoneInfo(name), name
    except (OSError, ZoneInfoNotFoundError, ValueError):
        pass
    name = os.environ.get("TZ", "")
    if not name:
        try:
            name = pathlib.Path("/etc/timezone").read_text().strip()
        except OSError:
            name = ""
    try:
        return ZoneInfo(name), name
    except (ZoneInfoNotFoundError, ValueError):
        return dt.datetime.now().astimezone().tzinfo, name


def read_pane(session: str) -> str:
    f = os.environ.get("LIMIT_PANE_FILE")
    if f:
        try:
            return pathlib.Path(f).read_text(errors="replace")
        except OSError:
            return ""
    try:
        return subprocess.run(["tmux", "capture-pane", "-pt", session, "-S", "-30"],
                              capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def pane_tail(pane: str) -> list[str]:
    lines = pane.rstrip("\n").split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    return lines[-TAIL_LINES:]


def find_hits(tail: list[str]) -> list[re.Match]:
    hits = []
    for i, line in enumerate(tail):
        if not LIMIT_START_RE.match(line) or COMMAND_OUTPUT_RE.search(line):
            continue
        m = LIMIT_RE.match(line.rstrip())
        if not m and i + 1 < len(tail):   # narrow pane wrapped the «(Asia/...)» part
            m = LIMIT_RE.match(line.rstrip() + " " + tail[i + 1].strip())
        if m:
            hits.append(m)
    return hits


def zone(name: str | None, fallback: dt.tzinfo) -> dt.tzinfo:
    if name:
        try:
            return ZoneInfo(name.strip())
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return fallback


def resolve_reset(m: re.Match, now: float, known: float | None,
                  fallback_tz: dt.tzinfo) -> float | None:
    """Epoch of the reset the line talks about (may be in the past = old text)."""
    w = WHEN_RE.match(m.group("when").strip())
    if not w:
        return None
    tz = zone(m.group("tz"), fallback_tz)
    hour = int(w.group("h")) % 12 + (12 if w.group("ap").lower() == "pm" else 0)
    minute = int(w.group("m") or 0)
    local_now = dt.datetime.fromtimestamp(now, tz)
    if w.group("mon"):
        mon = MONTHS.get(w.group("mon").lower())
        if not mon:
            return None
        year = int(w.group("year") or local_now.year)
        try:
            when = dt.datetime(year, mon, int(w.group("day")), hour, minute, tzinfo=tz)
        except ValueError:
            return None
        if not w.group("year") and when.timestamp() < now - 180 * 86400:
            when = when.replace(year=year + 1)      # «Jan 2» seen in late December
        return when.timestamp()
    # Time only: Claude Code prints it when the reset is < 24h ahead of the moment
    # the line was drawn. It is either the next such clock time (live) or the last
    # one (old text still on screen).
    today = dt.datetime.combine(local_now.date(), dt.time(hour, minute), tzinfo=tz)
    if today.timestamp() > now:
        future, past = today, today - dt.timedelta(days=1)
    else:
        past, future = today, today + dt.timedelta(days=1)
    t_f, t_p = future.timestamp(), past.timestamp()
    if known is not None and abs(known - t_p) <= SAME_WINDOW_SEC:
        return t_p                                  # the window we already handled
    if m.group("kind") == "session" and t_f - now > SESSION_WINDOW_SEC + WINDOW_SLACK_SEC:
        return t_p                                  # too far for a 5h window -> old
    return t_f


def human_time(epoch: float, tz: dt.tzinfo, tz_name: str, now: float) -> str:
    """«в 15:40 (по Перми)», or «12.10 в 09:00» when it is not today for the owner."""
    when = dt.datetime.fromtimestamp(epoch, tz)
    today = dt.datetime.fromtimestamp(now, tz).date()
    s = "в " + when.strftime("%H:%M") if when.date() == today else when.strftime("%d.%m в %H:%M")
    if tz_name == PERM_TZ:
        s += " (по Перми)"
    return s


class Notifier:
    def __init__(self, ws: pathlib.Path, agent: str):
        self.ws, self.agent = ws, agent

    def send(self, text: str) -> bool:
        cmd = os.environ.get("LIMIT_NOTIFY_CMD")
        try:
            if cmd:
                return subprocess.run([cmd, text], timeout=30).returncode == 0
            tg = self.ws / "bin/tg-send.py"
            if tg.is_file():
                return subprocess.run([sys.executable, str(tg), text],
                                      timeout=60).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
        return self._bot_api(text)

    def _bot_api(self, text: str) -> bool:
        """No kit bin/ yet: the same direct Bot API path modal-watch.sh uses."""
        env = pathlib.Path(os.environ.get(
            "DASHI_ENV_FILE", f"/etc/dashi-plugin/{self.agent}/channel.env"))
        token = chat = ""
        try:
            for line in env.read_text().splitlines():
                k, _, v = line.partition("=")
                if k == "TELEGRAM_BOT_TOKEN":
                    token = v.strip()
                elif k == "TELEGRAM_ALLOWED_USER_IDS":
                    chat = v.strip().split(",")[0]
        except OSError:
            return False
        if not token or not chat:
            return False
        root = os.environ.get("TELEGRAM_API_ROOT", "https://api.telegram.org")
        data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
        try:
            urllib.request.urlopen(f"{root}/bot{token}/sendMessage", data=data,
                                   timeout=20).read()
            return True
        except OSError:
            return False


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: limit-notice.py <tmux-session>", file=sys.stderr)
        return 2
    session = sys.argv[1]
    agent = session.removeprefix("channel-")
    ws = resolve_workspace(agent)
    if ws is None:
        return 0
    state_file = ws / "data/limit-notice.state"
    log_file = ws / "logs/limit-notice.log"
    now = float(os.environ.get("LIMIT_NOW") or time.time())

    def log(msg: str) -> None:
        try:
            log_file.parent.mkdir(parents=True, exist_ok=True)
            stamp = dt.datetime.fromtimestamp(now, tz).isoformat(timespec="seconds")
            with log_file.open("a") as fh:
                fh.write(f"[{stamp}] {msg}\n")
        except OSError:
            pass

    def save(st: dict) -> None:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(state_file)

    try:
        st = json.loads(state_file.read_text())
    except (OSError, ValueError):
        st = {}
    known = st.get("reset")
    tz, tz_name = owner_tz(ws)
    notify = Notifier(ws, agent)

    tail = pane_tail(read_pane(session))
    live = None
    hits = find_hits(tail)
    if hits:
        m = hits[-1]                                 # the newest line is the bottom one
        epoch = resolve_reset(m, now, known, tz)
        if epoch is not None and epoch > now:
            live = (m.group("kind"), epoch)
        elif epoch is not None:
            if st.get("phase") != "limited":
                log(f"old limit text on screen (reset {int(epoch)} passed) -- ignored")
    tail_text = "\n".join(tail)
    dialog = bool(DIALOG_RE.search(tail_text) and DIALOG_OPTION_RE.search(tail_text))

    if live:
        kind, epoch = live
        if st.get("phase") == "limited" and known and abs(known - epoch) <= SAME_WINDOW_SEC:
            return 0                                 # this window is already reported
        back = human_time(epoch, tz, tz_name, now)
        text = (
            f"Братан, лимит кончился, давай на перекур. Вернусь примерно {back}, "
            "сам продолжу как только откроется, дёргать не надо.\n\n"
            f"Если ждать некогда: {USAGE_URL} → раздел Resets → Reset for free "
            "(если он там есть). Лимит снимется сразу, и я продолжу. Нажать можешь "
            "только ты, из терминала эта кнопка недоступна."
        )
        if notify.send(text):
            save({"phase": "limited", "kind": kind, "reset": epoch,
                  "notified": now, "escalated": False})
            log(f"{kind} limit hit, reset {int(epoch)} ({back}) -- owner notified")
        else:
            log(f"{kind} limit hit, notify FAILED -- will retry next minute")
        return 0

    if st.get("phase") != "limited" or not known or now <= known:
        return 0                                     # nothing open, or still before the reset
    if dialog:
        # Past the reset, but the rate-limit menu still holds the queue.
        if not st.get("escalated") and now > known + ESCALATE_AFTER_SEC:
            back = human_time(known, tz, tz_name, now)
            text = (
                f"Лимит должен был сняться {back}, а у меня на экране всё ещё висит "
                "окно лимита «What do you want to do?» -- пока оно открыто, сообщения "
                "не идут. Сам туда не жму (первым пунктом там бывает платное "
                f"продолжение). Закрой его клавишей Esc: на сервере tmux attach -t {session}."
            )
            if notify.send(text):
                st["escalated"] = True
                save(st)
                log("still on the limit dialog 10 min after reset -- escalated")
        return 0
    if notify.send("Лимит отпустил, я снова на связи."):
        save({"phase": "recovered", "kind": st.get("kind"), "reset": known,
              "recovered": now})
        log(f"limit window {int(known)} over -- owner told «снова на связи»")
    return 0


if __name__ == "__main__":
    sys.exit(main())
