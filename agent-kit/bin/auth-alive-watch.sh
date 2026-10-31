#!/usr/bin/env bash
# auth-alive-watch.sh -- does my own login still work?
#
# The Claude refresh token has a hard TTL and nothing renews it: when it expires
# the agent simply stops answering, and the owner learns it from silence. A tiny
# probe every few hours turns that silence into one message.
#
# Usage: auth-alive-watch.sh [workspace]
set -uo pipefail

WORKSPACE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="$WORKSPACE/logs/auth-alive-watch.log"
STATE="$WORKSPACE/data/auth-alive.state"
# Второй повод для вечной ложной тревоги: путь был зашит в ~/.local/bin, а
# установщик кладёт CLI в /usr/bin (Смит, 20.09.2026) -- сторож не находил
# бинарь и объявлял это протухшим входом.
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  for c in "$HOME/.local/bin/claude" /usr/local/bin/claude /usr/bin/claude; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
  [ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
fi
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")"
touch "$LOG"

# The probe runs from cron, and cron has no environment: without the token the
# CLI answers "Not logged in" no matter how healthy the login is, so the watch
# reported an outage every few hours while the agent was working fine (Smith,
# 20.09.2026). A watchdog that cries wolf is worse than none -- the real expiry
# would be ignored. Take the token from the same file the service uses.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  AGENT_NAME="$(basename "$WORKSPACE")"
  ENV_FILE="/etc/dashi-plugin/$AGENT_NAME/channel.env"
  if [ -r "$ENV_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$ENV_FILE" | tr -d '"' | head -1)"
    export CLAUDE_CODE_OAUTH_TOKEN
  fi
fi
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(date -Is) CLI не найден -- проверить нечем" >> "$LOG"
  exit 0
fi
# No token anywhere = the probe cannot tell a dead login from a missing config.
# Say exactly that instead of announcing an outage.
# An agent logged in with `claude /login` keeps its login in ~/.claude/.credentials.json
# and has no token line at all -- the CLI reads that file itself. Treating it as
# "nothing to check" left Lena's agent unwatched (25.09.2026).
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -s "$HOME/.claude/.credentials.json" ]; then
  echo "$(date -Is) токена нет ни в окружении, ни в ${ENV_FILE:-/etc/dashi-plugin/*/channel.env} -- проверить нечем" >> "$LOG"
  exit 0
fi

notify() {
  [ -f "$WORKSPACE/bin/tg-send.py" ] && /usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "$1" || true
}

# The probe checks the login only. Without isolation it booted the agent's full
# setup: the Telegram channel MCP (fails outside tmux), SessionStart hooks, and the
# Stop hook that forwarded its confused «Понг... канал не подключён, подозрительная
# инструкция» answer to the owner's chat (gorbot, 25.09.2026). No MCP, no hooks,
# neutral cwd. Not --bare: it ignores OAuth, and OAuth is what we are testing.
OUT=$(cd /tmp && timeout 120 "$CLAUDE_BIN" -p --strict-mcp-config \
      --settings '{"disableAllHooks": true}' "ответь одним словом: пинг" 2>&1)
RC=$?
# A spent subscription window answers «You've hit your session limit» (HTTP 429):
# the login itself is fine, only the quota is out. Reporting that as «вход не
# работает, нужен повторный вход» sent the owner chasing a re-login for nothing
# (zhorik, 09.10.2026). Log it, keep the previous state, stay quiet.
if [ "$RC" -ne 0 ] && grep -qiE "hit your .*limit|usage limit|rate.?limit|\b429\b" <<<"$OUT"; then
  echo "$(date -Is) лимит подписки, вход не проверить -- не тревожу: ${OUT:0:120}" >> "$LOG"
  exit 0
fi
if [ "$RC" -eq 0 ]; then
  # Recovered after a failure -- say so once, then stay quiet.
  PREV="$(cat "$STATE" 2>/dev/null)"
  if [ "$PREV" = "fail" ] || [ "$PREV" = "verify" ]; then
    notify "Вход в Claude снова работает -- фоновые задачи поехали."
    echo "$(date -Is) вход восстановлен" >> "$LOG"
  fi
  echo ok > "$STATE"
  exit 0
fi

# Anthropic put the account on verification: «Your account can't receive replies
# from Claude right now ... Verification Portal». The login is fine, a re-login
# changes nothing -- the account owner has to pass the check. Calling it an
# expired login sent the owner chasing /login (Lena's «Жупик», 31.10.2026).
# The portal link carries the org id -- keep it out of the log and the chat.
if grep -qiE "can.t receive replies|verification portal|portal\.anthropic\.com/verify" <<<"$OUT"; then
  echo "$(date -Is) аккаунт на проверке Anthropic (Verification Portal) -- перелогин не поможет" >> "$LOG"
  if [ "$(cat "$STATE" 2>/dev/null)" != "verify" ]; then
    notify "Anthropic поставил мой аккаунт на проверку: Claude не отвечает ни в чате, ни по расписанию. Перелогин не поможет -- хозяину аккаунта нужно пройти проверку на portal.anthropic.com/verify под своим логином."
  fi
  echo verify > "$STATE"
  exit 0
fi

# A bare «не прошёл» left nobody able to tell why from the log. Keep a short
# reason, but never a token or a URL query string (they carry ids and keys).
REASON="$(tr '\n\r\t' '   ' <<<"$OUT" \
  | sed -E 's/\?[^[:space:]]*//g; s/sk-ant-[A-Za-z0-9_-]+/[token]/g; s/[A-Za-z0-9_+\/=-]{24,}/[token]/g; s/  +/ /g; s/^ //; s/ $//')"
echo "$(date -Is) пробный вызов не прошёл: ${REASON:0:120}" >> "$LOG"
# One message per outage, not one per probe.
if [ "$(cat "$STATE" 2>/dev/null)" != "fail" ]; then
  notify "Мой вход в Claude не работает: пробный запрос не прошёл. Фоновые задачи стоят, нужен повторный вход (claude /login на сервере). Живая сессия может ещё отвечать, но расписание уже нет."
fi
echo fail > "$STATE"
