#!/usr/bin/env python3
"""Weekly stack-updates digest: what's out vs what the agent runs. REPORT-ONLY,
never updates anything (an OpenViking upgrade once hit 3 rakes -- a human decides,
not a cron).

Sources: npm (Claude Code), GitHub releases (bun), git fetch (the agent's own
dashi-plugin checkout vs origin/<DASHI_BRANCH>), docker digest (OpenViking ghcr,
only when a container named `openviking` exists).

    bin/stack-updates-check.py            # print the digest
    bin/stack-updates-check.py --send     # ...and send it to the owner
    bin/stack-updates-check.py --selftest
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path("__WORKSPACE__")
PLUGIN = pathlib.Path("__CLAUDE_DIR__/dashi-plugin-claude-code")
ENV_FILE = pathlib.Path(
    os.environ.get("DASHI_CHANNEL_ENV", "/etc/dashi-plugin/__AGENT__/channel.env"))
NOTIFY = ROOT / "bin/tg-send.py"
FRESH = "актуален"

# OpenViking releases NOT to offer. 569193efd49a = v0.4.21: 28.09.2026 on Smith and
# on Jarvis every memory written before the upgrade stopped showing in search (files
# intact, only new writes found); rolled back to v0.4.16. Drop a digest from here
# only after a newer release passes the old-memory recall check on Smith.
OV_HOLD = {"569193efd49a"}


def http_json(url: str):
    # npm 406s on the github Accept header -- send it only to api.github.com
    hdrs = {"User-Agent": "dashi-agent-stack-check"}
    if "api.github.com" in url:
        hdrs["Accept"] = "application/vnd.github+json"
    req = urllib.request.Request(url, headers=hdrs)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def sh(cmd: str) -> str:
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=120).stdout.strip()
    except subprocess.TimeoutExpired:
        return ""


def plugin_branch() -> str:
    """The branch this agent's plugin tracks (DASHI_BRANCH in channel.env), else main."""
    try:
        for line in ENV_FILE.read_text().splitlines():
            key, _, val = line.partition("=")
            if key == "DASHI_BRANCH" and val.strip():
                return val.strip()
    except OSError:
        pass
    return "main"


def rows() -> list[tuple[str, str, str]]:
    out = []
    # Claude Code
    have = sh("(~/.local/bin/claude --version || claude --version) 2>/dev/null "
              "| grep -oE '^[0-9.]+'") or "?"
    try:
        latest = http_json("https://registry.npmjs.org/@anthropic-ai/claude-code/latest")["version"]
    except Exception:
        latest = "?"
    out.append(("Claude Code", have, latest))
    # bun
    have = sh("(~/.bun/bin/bun --version || bun --version) 2>/dev/null") or "?"
    try:
        latest = http_json("https://api.github.com/repos/oven-sh/bun/releases/latest")[
            "tag_name"].replace("bun-v", "")
    except Exception:
        latest = "?"
    out.append(("bun", have, latest))
    # dashi-plugin: the agent's checkout vs origin/<branch> (same way as the advisor)
    if (PLUGIN / ".git").exists():
        br = plugin_branch()
        ok = sh(f"git -C '{PLUGIN}' fetch -q --depth 30 origin '{br}' && echo ok") == "ok"
        behind = sh(f"git -C '{PLUGIN}' rev-list --count HEAD..FETCH_HEAD") if ok else ""
        if behind and behind != "0":
            out.append(("dashi-plugin", "HEAD", f"origin/{br} +{behind} коммитов"))
        else:
            out.append(("dashi-plugin", "HEAD", FRESH if ok else "?"))
    # OpenViking: only where the long-term memory container actually exists.
    # What the RUNNING container uses, not the local :latest tag (28.09 a pulled
    # :latest sat unused next to a container pinned to v0.4.16).
    img = sh("docker inspect openviking --format '{{.Image}}' 2>/dev/null")
    if img:
        have = sh(f"docker image inspect '{img}' --format '{{{{index .RepoDigests 0}}}}' "
                  "2>/dev/null | grep -oP 'sha256:\\K.{12}'") or "?"
        try:
            tok = http_json("https://ghcr.io/token?scope=repository:volcengine/openviking:pull")[
                "token"]
            req = urllib.request.Request(
                "https://ghcr.io/v2/volcengine/openviking/manifests/latest",
                headers={"Authorization": f"Bearer {tok}",
                         "Accept": "application/vnd.oci.image.index.v1+json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                remote = r.headers.get("Docker-Content-Digest", "?").replace("sha256:", "")[:12]
        except Exception:
            remote = "?"
        if remote in OV_HOLD:
            remote = FRESH  # a known-bad release is not an update
        out.append(("OpenViking", have, remote if remote != have else FRESH))
    return out


# Human name, "why it matters" and a short label -- the owner is an operator, not a coder.
HUMAN = {
    "Claude Code":  ("Claude Code — движок, на котором я работаю", "движок Claude Code"),
    "bun":          ("bun — среда моего Telegram-моста", "среда bun"),
    "dashi-plugin": ("dashi-plugin — мост Telegram ↔ Claude", "dashi-plugin"),
    "OpenViking":   ("OpenViking — моя долгая память", "OpenViking"),
}


def human_line(name: str, have: str, latest: str) -> str:
    title = HUMAN.get(name, (name, name))[0]
    if latest.startswith("origin/"):
        n = latest.split("+")[1].split()[0] if "+" in latest else "?"
        return f"• {title}. В общей ветке накопилось {n} правок, у меня их ещё нет."
    if len(have) == 12 and len(latest) == 12:  # docker digests: no versions, just "a new build"
        return f"• {title}. Вышла новая сборка."
    return f"• {title}. У меня {have}, вышла {latest}."


def is_stale(have: str, latest: str) -> bool:
    return latest not in ("?", FRESH, have) and have != latest


def build_message(items: list[tuple[str, str, str]]) -> str:
    stale_lines, fresh_names = [], []
    for name, have, latest in items:
        if is_stale(have, latest):
            stale_lines.append(human_line(name, have, latest))
        else:
            fresh_names.append(HUMAN.get(name, (name, name))[1])
    if not stale_lines:
        return "Проверил обновления своих инструментов — всё свежее, обновлять нечего."
    lines = [f"Проверил обновления своих инструментов — можно обновить "
             f"{len(stale_lines)} шт.:", ""]
    lines += stale_lines
    if fresh_names:
        lines += ["", "Остальное свежее: " + ", ".join(fresh_names) + "."]
    lines += ["Сам ничего не трогал — решает хозяин. Мост обновляется командой /update."]
    return "\n".join(lines)


def selftest() -> int:
    fresh = build_message([("Claude Code", "2.1.0", "2.1.0"), ("bun", "1.2.0", "?")])
    assert "всё свежее" in fresh, fresh
    msg = build_message([
        ("Claude Code", "2.1.0", "2.2.0"),
        ("dashi-plugin", "HEAD", "origin/main +4 коммитов"),
        ("OpenViking", "aaaaaaaaaaaa", "bbbbbbbbbbbb"),
        ("bun", "1.2.0", FRESH),
    ])
    assert "можно обновить 3 шт." in msg, msg
    assert "У меня 2.1.0, вышла 2.2.0" in msg
    assert "накопилось 4 правок" in msg
    assert "новая сборка" in msg
    assert "среда bun" in msg
    assert "Саня" not in msg and "Смит" not in msg
    assert "569193efd49a" in OV_HOLD
    assert not is_stale("HEAD", FRESH) and not is_stale("x", "?")
    print("stack-updates-check selftest ok")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    msg = build_message(rows())
    print(msg)
    if "--send" in sys.argv:
        subprocess.run([sys.executable, str(NOTIFY), msg], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
