#!/usr/bin/env bash
# backup-offsite-watch.sh — раз в сутки: есть ли СВЕЖАЯ копия бэкапа вне сервера.
#
# Только облачная копия переживает смерть сервера. Если её нет больше 48 часов
# (Google отозвал вход, кончилась квота, rclone так и не настроили) — хозяин узнаёт
# об этом сегодня, а не в день, когда сервер умер. Когда всё хорошо — молчит.
#
# Источник правды — листинг облака (rclone lsjson), а не наш собственный журнал;
# журнал (state/backup/last-offsite.json, его пишет agent-backup.sh) нужен только
# для запасного канала gws и когда облако не ответило.
#
# Куда пишет, когда плохо:
#   - хозяину через бота самого агента (токен и чат из channel.env / .env);
#   - доп. получателям из DASHI_BACKUP_ALERT_CHATS (в env или в channel.env);
#   - строкой «FAIL: off-site ...» в logs/backup-watch.log — её подхватывает
#     сторож провалов агента и сводка здоровья флота у оператора;
#   - state/backup/offsite-status.json — состояние для сводки здоровья флота.
# Ещё: если пароль бэкапа хозяину так и не ушёл (не нажал Start у бота) —
# пробует отправить снова (scripts/backup-pass-send.sh).
#
#   backup-offsite-watch.sh               ежедневный прогон (крон), exit 0 всегда
#   backup-offsite-watch.sh --dry-run     посчитать и напечатать, никому не писать
#   backup-offsite-watch.sh --status-only состояние + строка в лог, без Telegram
#                                         (так его зовёт ночной agent-backup.sh:
#                                         сводка флота видит беду даже там, где
#                                         дневного крона сторожа ещё нет)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
source "$SCRIPT_DIR/backup-lib.sh"

AGENT="${DASHI_AGENT:?DASHI_AGENT не задан}"
WORKSPACE="${DASHI_WORKSPACE:?DASHI_WORKSPACE не задан}"
CHANNEL_ENV="${DASHI_CHANNEL_ENV:-/etc/dashi-plugin/$AGENT/channel.env}"
STALE_H="${DASHI_BACKUP_STALE_HOURS:-48}"
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone 2>/dev/null || echo "$HOME/.local/bin/rclone")}"
RCLONE_REMOTE="${DASHI_RCLONE_REMOTE:-gdrive}"
RCLONE_PATH="${DASHI_RCLONE_PATH:-dashi-$AGENT-backups}"
STATE_DIR="$WORKSPACE/state/backup"
LOG="$WORKSPACE/logs/backup-watch.log"
DRY=0; QUIET=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --status-only) QUIET=1 ;;
esac

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T %Z')] $*" >>"$LOG"; }
now=$(date +%s)

# ── newest off-site copy ────────────────────────────────────────────────────
status=""; source_="none"; newest_ts=0; newest_name=""; reason=""
remote_ok=0
if [[ -x "$RCLONE_BIN" ]] && "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  remote_ok=1
  if js="$("$RCLONE_BIN" lsjson --files-only --no-mimetype "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>"$STATE_DIR/.rclone.err")"; then
    read -r newest_ts newest_name < <(python3 -c '
import json, re, sys
from datetime import datetime, timedelta, timezone
# rclone: 2026-10-16T03:40:12.123456789Z or ...+05:00; Python 3.10 cannot parse
# nanoseconds or Z, so split the parts by hand.
RX = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?$")
best = (0, "")
for it in json.loads(sys.stdin.read() or "[]"):
    name = it.get("Name", "")
    if not (name.startswith(sys.argv[1] + "-") and name.endswith(".tar.gz.gpg")):
        continue
    m = RX.match(it.get("ModTime", ""))
    if not m:
        continue
    tz = timezone.utc
    if m.group(2) and m.group(2) != "Z":
        sign = 1 if m.group(2)[0] == "+" else -1
        hh, mm = m.group(2)[1:].split(":")
        tz = timezone(sign * timedelta(hours=int(hh), minutes=int(mm)))
    ts = int(datetime.fromisoformat(m.group(1)).replace(tzinfo=tz).timestamp())
    best = max(best, (ts, name))
print(best[0], best[1] or "-")' "$AGENT" <<<"$js" 2>/dev/null || echo "0 -")
    [[ "$newest_name" == "-" ]] && newest_name=""
    source_="rclone"
  else
    reason="облако не ответило: $(tail -1 "$STATE_DIR/.rclone.err" | cut -c1-160)"
  fi
fi
# Own journal: the only trace of the gws fallback, and a fallback when rclone failed.
if [[ "$newest_ts" -eq 0 && -s "$STATE_DIR/last-offsite.json" ]]; then
  read -r j_ts j_name < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(int(d.get("ts", 0)), d.get("file") or "-")' "$STATE_DIR/last-offsite.json" 2>/dev/null || echo "0 -")
  if [[ "${j_ts:-0}" -gt 0 ]]; then
    newest_ts="$j_ts"; newest_name="${j_name/#-/}"; source_="journal"; remote_ok=1
  fi
fi

age_h=-1
if [[ $remote_ok -eq 0 ]]; then
  status="not_configured"
elif [[ "$newest_ts" -eq 0 ]]; then
  status="stale"; [[ -n "$reason" ]] || reason="в облаке нет ни одной копии"
else
  age_h=$(( (now - newest_ts) / 3600 ))
  if (( age_h >= STALE_H )); then status="stale"; else status="ok"; fi
fi

printf '{"checked_at": %s, "status": %s, "source": %s, "newest_age_h": %s, "newest": %s, "reason": %s, "stale_hours": %s}\n' \
  "$now" "$(bk_json_str "$status")" "$(bk_json_str "$source_")" "$age_h" \
  "$(bk_json_str "$newest_name")" "$(bk_json_str "$reason")" "$STALE_H" >"$STATE_DIR/offsite-status.json"

# ── password hand-over retry (silent; only when it never reached the owner) ──
if [[ $DRY -eq 0 && $QUIET -eq 0 && ! -s "$STATE_DIR/password-delivered.json" && -f "$SCRIPT_DIR/backup-pass-send.sh" ]]; then
  if DASHI_CHANNEL_ENV="$CHANNEL_ENV" bash "$SCRIPT_DIR/backup-pass-send.sh" >>"$LOG" 2>&1; then
    log "пароль бэкапа доставлен хозяину (повторная попытка)"
  fi
fi

if [[ "$status" == ok ]]; then
  log "OK off-site: свежая копия $newest_name, ${age_h} ч назад ($source_)"
  [[ $DRY -eq 1 ]] && echo "ok: $newest_name, ${age_h} ч назад ($source_)"
  exit 0
fi

# ── not ok: tell the owner (and the extra recipients) ───────────────────────
case "$status" in
  not_configured)
    head="облачная копия бэкапа НЕ настроена"
    body="Бэкап лежит только на этом сервере и умрёт вместе с ним: восстановить агента будет не из чего. Подключить Google Drive — docs/07-backup-and-recovery.md, раздел «Google Drive» (10 минут, один раз). Или попроси меня: «подключи облако для бэкапа»." ;;
  *)
    if [[ $age_h -ge 0 ]]; then
      head="облачной копии бэкапа нет уже ${age_h} ч"
      body="Последняя копия в облаке: $newest_name. Новые туда не уезжают — если сервер умрёт сейчас, потеряется всё сделанное с тех пор."
    else
      head="в облаке нет ни одной копии бэкапа"
      body="Облако подключено, но копий в нём нет (${reason})."
    fi
    body="$body Что смотреть: logs/backup.log (строки FAIL), проверка входа в облако: rclone lsd ${RCLONE_REMOTE}: — если «token expired/invalid_grant», вход в Google надо обновить." ;;
esac
log "FAIL: off-site: $head${reason:+ ($reason)}"
text="Агент $AGENT: $head.
$body"
[[ $DRY -eq 1 ]] && { echo "$text"; exit 0; }
[[ $QUIET -eq 1 ]] && exit 0

token="$(bk_tg_token "$CHANNEL_ENV")"
[[ -n "$token" ]] || { log "WARN: не могу написать хозяину -- нет токена бота в $CHANNEL_ENV"; exit 0; }
sent=0
for chat in "$(bk_tg_owner "$CHANNEL_ENV")" $(bk_tg_extra_chats "$CHANNEL_ENV"); do
  [[ -n "$chat" ]] || continue
  if bk_tg_send_text "$token" "$chat" "$text"; then sent=$((sent + 1))
  else log "WARN: сообщение в чат $chat не ушло"; fi
done
log "оповещение отправлено в $sent чат(а)"
exit 0
