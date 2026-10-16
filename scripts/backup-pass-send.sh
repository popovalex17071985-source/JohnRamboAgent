#!/usr/bin/env bash
# backup-pass-send.sh — отдать хозяину пароль от бэкапа файлом в Telegram.
#
# Пароль живёт в secrets/backup.pass НА СЕРВЕРЕ. Умер сервер, а пароля нигде
# больше нет — облачную копию не расшифровать, бэкап бесполезен. Раньше пароль
# показывали один раз на экране установки, и его никто не сохранял. Теперь
# установщик шлёт его хозяину файлом через бота самого агента и отмечает
# доставку в state/backup/password-delivered.json. Не ушло (хозяин ещё не нажал
# Start у бота) — сторож бэкапа пробует снова каждый день.
#
# Шлём ТОЛЬКО хозяину (владелец бота из channel.env), никаким доп. получателям.
#
#   backup-pass-send.sh           отправить, если ещё не доставлен
#   backup-pass-send.sh --force   отправить ещё раз (например, после смены пароля
#                                 или тем, кому он не дошёл до 16.10.2026)
# Переменные: DASHI_AGENT, DASHI_WORKSPACE (обязательные), DASHI_CHANNEL_ENV.
#   sudo -u agent DASHI_AGENT=lena DASHI_WORKSPACE=/home/agent/.claude-lab/lena \
#     bash scripts/backup-pass-send.sh --force
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
source "$SCRIPT_DIR/backup-lib.sh"

AGENT="${DASHI_AGENT:?DASHI_AGENT не задан}"
WORKSPACE="${DASHI_WORKSPACE:?DASHI_WORKSPACE не задан}"
CHANNEL_ENV="${DASHI_CHANNEL_ENV:-/etc/dashi-plugin/$AGENT/channel.env}"
PASS_FILE="${DASHI_BACKUP_PASS:-$WORKSPACE/secrets/backup.pass}"
RCLONE_REMOTE="${DASHI_RCLONE_REMOTE:-gdrive}"
RCLONE_PATH="${DASHI_RCLONE_PATH:-dashi-$AGENT-backups}"
STATE="$WORKSPACE/state/backup/password-delivered.json"
FORCE=0; [[ "${1:-}" == --force ]] && FORCE=1

if [[ $FORCE -eq 0 && -s "$STATE" ]]; then
  echo "пароль уже доставлен хозяину ($(sed -n 's/.*"at": *"\([^"]*\)".*/\1/p' "$STATE")); заново: --force"
  exit 0
fi
[[ -s "$PASS_FILE" ]] || { echo "нет пароля: $PASS_FILE" >&2; exit 1; }
token="$(bk_tg_token "$CHANNEL_ENV")"
chat="$(bk_tg_owner "$CHANNEL_ENV")"
[[ -n "$token" && -n "$chat" ]] || { echo "нет токена бота или чата хозяина в $CHANNEL_ENV" >&2; exit 1; }

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
chmod 700 "$tmpd"
f="$tmpd/backup-password-$AGENT.txt"
(
  umask 077
  cat >"$f" <<EOF
Пароль от бэкапа агента $AGENT:

$(tr -d '\r\n' <"$PASS_FILE")

Что с ним сделать:
1. Сохрани пароль в менеджер паролей или в заметки — НЕ на сервере агента.
2. После этого сообщение с файлом можно удалить из чата.

Зачем: копия бэкапа зашифрована. Если сервер умрёт, агента поднимают из облачной
копии, и без этого пароля её не открыть никому.

Где лежат копии: на сервере ($WORKSPACE/backups) и в облаке
${RCLONE_REMOTE}:${RCLONE_PATH} (если облако подключено).
Как поднять агента на новом сервере: docs/07-backup-and-recovery.md, «Случай 2».
EOF
)

caption="Пароль от бэкапа агента $AGENT. Сохрани его ВНЕ сервера (менеджер паролей), потом удали это сообщение."
if mid="$(bk_tg_send_file "$token" "$chat" "$f" "$caption")"; then
  mkdir -p "$(dirname "$STATE")"
  printf '{"at": "%s", "chat": "%s", "message_id": %s}\n' "$(date -Iseconds)" "$chat" "${mid:-0}" >"$STATE"
  [[ $EUID -eq 0 ]] && chown --reference="$WORKSPACE" "$STATE" "$(dirname "$STATE")" 2>/dev/null
  echo "пароль отправлен хозяину файлом (чат $chat)"
  exit 0
fi
echo "пароль НЕ отправлен: Telegram не принял (хозяин нажал Start у бота?)" >&2
exit 1
