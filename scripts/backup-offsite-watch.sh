#!/usr/bin/env bash
# backup-offsite-watch.sh — раз в сутки: есть ли СВЕЖАЯ копия бэкапа вне сервера.
#
# Только облачная копия переживает смерть сервера. Если её нет больше 48 часов
# (Google отозвал вход, кончилась квота, rclone так и не настроили) — хозяин узнаёт
# об этом сегодня, а не в день, когда сервер умер. Когда всё хорошо — молчит.
#
# Источник правды — листинг облака (rclone lsjson), а не наш собственный журнал;
# журнал (state/backup/last-offsite.json, его пишет agent-backup.sh) засчитывается
# только для запасного канала gws (такую копию rclone не видит).
#
# Плохо — это любое из:
#   not_configured  облака нет вовсе;
#   not_offsite     «облако» на самом деле папка на этом же сервере (remote типа
#                   local или alias/crypt поверх локальной папки);
#   unreachable     облако настроено, но не читается (истёк вход, нет сети) —
#                   есть ли там копия, неизвестно;
#   failing         последняя попытка отправки (state/backup/last-attempt.json)
#                   провалилась позже последней копии в облаке;
#   stale           новейшая копия старше 48 ч.
# stub — тестовая заглушка, объявленная явно (DASHI_BACKUP_OFFSITE_STUB или файл
# deploy/offsite-stub): не OK и не тревога, никому не пишет.
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
remote_ok=0; has_remote=0; unreachable=0
if [[ -x "$RCLONE_BIN" ]] && "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  remote_ok=1; has_remote=1
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
    # Expired Google login, revoked token, no network: the cloud cannot be read,
    # so nothing proves a copy is there. Its own status -- never «OK» from the journal.
    unreachable=1
    reason="облако не ответило: $(grep -v '^[[:space:]]*$' "$STATE_DIR/.rclone.err" | tail -1 | cut -c1-200)"
  fi
fi
# Own journal: counts ONLY for the gws fallback (an upload rclone cannot list).
# rclone uploads are proven by the listing above, not by our own word.
if [[ $unreachable -eq 0 && -s "$STATE_DIR/last-offsite.json" ]]; then
  read -r j_ts j_method j_name < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(int(d.get("ts", 0)), d.get("method") or "-", d.get("file") or "-")' "$STATE_DIR/last-offsite.json" 2>/dev/null || echo "0 - -")
  if [[ "$j_method" == gws && "${j_ts:-0}" -gt "$newest_ts" ]]; then
    newest_ts="$j_ts"; newest_name="${j_name/#-/}"; source_="journal"; remote_ok=1
  fi
fi

# ── is the "off-site" remote really off this server? ────────────────────────
# A remote of type local, or an alias/crypt/... wrapper over a local folder, keeps
# the "cloud" copy on the same machine: it dies with the server (Smith e2e
# 16.10.2026: gdrive = alias to /srv/offsite on /dev/vda2, and the watcher said OK).
# A local path on a network mount (nfs, cifs, sshfs, rclone mount) does leave the box.
where=""; offsite_kind="remote"
if [[ $has_remote -eq 1 ]]; then
  where="$("$RCLONE_BIN" config dump 2>/dev/null | python3 -c '
import json, sys
try:
    cfg = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
name, path = sys.argv[1], sys.argv[2]
WRAP = ("alias", "crypt", "chunker", "compress", "hasher")
for _ in range(10):
    r = cfg.get(name)
    if not isinstance(r, dict):
        break
    t = r.get("type", "")
    if t == "local":
        print(path or ".")
        break
    if t not in WRAP:
        break
    target = r.get("remote", "")
    if ":" in target and not target.startswith("/"):
        name, rest = target.split(":", 1)
        path = (rest.rstrip("/") + "/" + path) if rest else path
        continue
    print(target.rstrip("/") + "/" + path)
    break' "$RCLONE_REMOTE" "$RCLONE_PATH" 2>/dev/null)"
  if [[ -n "$where" ]]; then
    p="$where"; [[ "$p" == /* ]] || p="$HOME/$p"
    while [[ ! -e "$p" && "$p" != / && "$p" != . ]]; do p="$(dirname "$p")"; done
    fst="$(findmnt -n -o FSTYPE -T "$p" 2>/dev/null || stat -f -c %T "$p" 2>/dev/null)"
    case "$fst" in
      nfs*|cifs|smb*|ceph|glusterfs|fuse.sshfs|fuse.rclone|fuse.s3fs|*davfs*) offsite_kind="network" ;;
      *) offsite_kind="local" ;;
    esac
  fi
fi
# Test setups (staging e2e) may stand in a local folder for the cloud, but must say
# so: DASHI_BACKUP_OFFSITE_STUB=<why> or a deploy/offsite-stub file. Then the verdict
# is «stub», never a green OK, and nobody gets a message. Ignored for a real remote.
stub="${DASHI_BACKUP_OFFSITE_STUB:-}"
[[ -z "$stub" && -s "$WORKSPACE/deploy/offsite-stub" ]] && stub="$(head -1 "$WORKSPACE/deploy/offsite-stub")"

# Last upload attempt (agent-backup.sh): a failure newer than the newest copy means
# copies stopped leaving even if the newest one is still younger than STALE_H.
att_ok=""; att_ts=0; att_err=""
if [[ -s "$STATE_DIR/last-attempt.json" ]]; then
  IFS=$'\t' read -r att_ok att_ts att_err < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("1" if d.get("ok") else "0", int(d.get("ts", 0)), (d.get("error") or "-").replace("\t", " "), sep="\t")' \
    "$STATE_DIR/last-attempt.json" 2>/dev/null || printf 'x\t0\t-\n')
fi

age_h=-1
[[ "$newest_ts" -gt 0 ]] && age_h=$(( (now - newest_ts) / 3600 ))
if [[ $remote_ok -eq 0 ]]; then
  status="not_configured"
elif [[ "$offsite_kind" == local && -n "$stub" ]]; then
  status="stub"; reason="заглушка: $stub; remote ${RCLONE_REMOTE} ведёт в $where на этом же сервере"
elif [[ "$offsite_kind" == local ]]; then
  status="not_offsite"; reason="remote ${RCLONE_REMOTE} ведёт в $where на этом же сервере"
elif [[ $unreachable -eq 1 ]]; then
  status="unreachable"
elif [[ "$att_ok" == 0 && "$att_ts" -gt "$newest_ts" ]]; then
  status="failing"; reason="последняя отправка $(( (now - att_ts) / 3600 )) ч назад не удалась: ${att_err/#-/без текста ошибки}"
elif [[ "$newest_ts" -eq 0 ]]; then
  status="stale"; [[ -n "$reason" ]] || reason="в облаке нет ни одной копии"
else
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
if [[ "$status" == stub ]]; then
  # Declared test stand-in: not OK, not an alarm either — nobody is messaged.
  log "STUB off-site: копии вне сервера НЕТ, это заглушка ($reason); свежая $newest_name, ${age_h} ч назад"
  [[ $DRY -eq 1 ]] && echo "stub: $reason"
  exit 0
fi

# ── not ok: tell the owner (and the extra recipients) ───────────────────────
case "$status" in
  not_offsite)
    head="«облачная» копия бэкапа лежит на этом же сервере"
    body="Remote ${RCLONE_REMOTE} ведёт в $where — это диск того же сервера, его смерть копия не переживёт. Нужен настоящий облачный remote (Google Drive): docs/07-backup-and-recovery.md, раздел «Google Drive». Или попроси меня: «подключи облако для бэкапа»." ;;
  unreachable)
    head="облако с бэкапами не отвечает — есть ли там свежая копия, неизвестно"
    body="${reason^}. Самое частое: истёк вход в Google — проверка: rclone lsd ${RCLONE_REMOTE}: ; если «token expired/invalid_grant», вход надо обновить (docs/07-backup-and-recovery.md, раздел «Google Drive»)." ;;
  failing)
    head="бэкап перестал уезжать в облако"
    body="${reason^}. ${newest_name:+В облаке пока лежит копия ${age_h} ч назад ($newest_name), но новых нет. }Что смотреть: logs/backup.log (строки FAIL), проверка входа в облако: rclone lsd ${RCLONE_REMOTE}: — если «token expired/invalid_grant», вход в Google надо обновить." ;;
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
