#!/usr/bin/env bash
# Шифрованный бэкап того, чего НЕТ на GitHub: память агента, его характер,
# секреты, состояние канала. Один AES-256 (GPG symmetric) архив в день, ротация
# последних RETAIN штук. Если настроен rclone-remote — копия ещё и off-site
# (смерть VPS = весь смысл бэкапа именно в этом).
#
# ВАЖНО про пароль: он лежит в secrets/backup.pass НА СЕРВЕРЕ. Если сервер умрёт,
# а копию пароля ты нигде больше не сохранил — off-site архив расшифровать НЕЧЕМ.
# Установщик показывает пароль один раз и просит сохранить его отдельно.
#
# Восстановление (нужен пароль):
#   gpg -d -o restore.tar.gz <архив>.tar.gz.gpg && tar xzf restore.tar.gz
#
# Запускается кроном раз в сутки. Всегда exit 0 — чтобы не заклинить крон;
# ошибки пишутся в лог.
set -uo pipefail

AGENT="${DASHI_AGENT:?DASHI_AGENT не задан}"
WORKSPACE="${DASHI_WORKSPACE:?DASHI_WORKSPACE не задан}"   # /home/<user>/.claude-lab/<agent>
BACKUP_DIR="${DASHI_BACKUP_DIR:-$WORKSPACE/backups}"
PASS_FILE="${DASHI_BACKUP_PASS:-$WORKSPACE/secrets/backup.pass}"
LOG="$WORKSPACE/logs/backup.log"
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone 2>/dev/null || echo "$HOME/.local/bin/rclone")}"
RCLONE_REMOTE="${DASHI_RCLONE_REMOTE:-gdrive}"        # имя rclone-remote (off-site)
RCLONE_PATH="${DASHI_RCLONE_PATH:-dashi-$AGENT-backups}"
RETAIN="${DASHI_BACKUP_RETAIN:-7}"

STAMP="$(date +%Y%m%d-%H%M)"
ARCHIVE="$BACKUP_DIR/$AGENT-$STAMP.tar.gz.gpg"

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T %Z')] $*" >>"$LOG"; }
fail() { log "FAIL: $*"; exit 0; }   # exit 0: крон не должен клинить на ошибке

[[ -s "$PASS_FILE" ]] || fail "нет пароля: $PASS_FILE — прогони установку бэкапа"

cd "$WORKSPACE" || fail "не могу зайти в $WORKSPACE"

# Снимок системного конфига, живущего ВНЕ workspace: crontab агента и systemd-юнит.
# Без него на новом VPS не будет ни расписания, ни сервиса.
mkdir -p deploy
crontab -l >deploy/crontab.txt 2>/dev/null || true
for u in "/etc/systemd/system/dashi-$AGENT.service" "$HOME/.config/systemd/user/dashi-$AGENT.service"; do
  [[ -f "$u" ]] && cp -f "$u" deploy/ 2>/dev/null || true
done
# channel.env (токен бота, доступ, пути) живёт в /etc, вне workspace — без него
# восстановление неполное (агент не подключится к Telegram). Он root:agent 660,
# группа agent читает. Кладём в снимок, чтобы restore был однокомандным.
cp -f "/etc/dashi-plugin/$AGENT/channel.env" deploy/channel.env 2>/dev/null || true
# cron.d юниты агента (советник/модалки/бэкап) — тоже вне workspace.
for c in "/etc/cron.d/dashi-$AGENT"-*; do [[ -f "$c" ]] && cp -f "$c" deploy/ 2>/dev/null || true; done

# Что бэкапим (относительно WORKSPACE): всё незаменимое, чего нет в git-репе плагина.
ITEMS=(".claude" "secrets" "state" "deploy")
present=()
for it in "${ITEMS[@]}"; do [[ -e "$it" ]] && present+=("$it"); done
[[ ${#present[@]} -gt 0 ]] || fail "нечего бэкапить"

# Исключаем сам git-репозиторий плагина (он на GitHub) и node_modules — иначе
# архив раздувается гигабайтами того, что и так восстановится git-клоном.
# Долгая память (OpenViking) живёт ВНЕ workspace, в ~/.openviking. До 02.10.2026
# её в архиве не было: умер сервер -- агент помнит всё, кроме прожитого.
# Кладём под префиксом .openviking/, restore-agent.sh вернёт её в домашку.
# --ignore-failed-read: контейнер оставляет там root-файлы (замок, studio.sqlite3),
# их не прочесть -- это не повод терять весь архив.
OV_ARGS=()
[[ -d "$HOME/.openviking" ]] && OV_ARGS=(-C "$HOME" .openviking)
tar czf - --ignore-failed-read \
  --exclude='.claude/dashi-plugin-claude-code' \
  --exclude='*/node_modules' \
  --exclude='state/telegram/inbox' \
  --exclude='.openviking/appdata/temp' \
  --exclude='.openviking/data/.openviking.lock' \
  "${present[@]}" "${OV_ARGS[@]}" 2>>"$LOG" \
  | gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASS_FILE" -o "$ARCHIVE" 2>>"$LOG"
rc=("${PIPESTATUS[@]}"); tar_rc=${rc[0]}; gpg_rc=${rc[1]}
# tar exit 1 = «файл изменился при чтении» (архив валиден); 2 = фатально.
if [[ $tar_rc -gt 1 || $gpg_rc -ne 0 ]]; then
  rm -f "$ARCHIVE"; fail "tar|gpg упал (tar=$tar_rc gpg=$gpg_rc)"
fi
# Self-check: свежий архив ОБЯЗАН расшифровываться и разворачиваться. Битый бэкап
# хуже отсутствующего — создаёт ложное чувство защиты. Не прошёл — удаляем и фейлим.
if ! gpg --batch --quiet --passphrase-file "$PASS_FILE" -d "$ARCHIVE" 2>>"$LOG" | tar tzf - >/dev/null 2>>"$LOG"; then
  rm -f "$ARCHIVE"; fail "self-check: свежий архив не расшифровался/не читается — удалён"
fi
log "OK local: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)), self-check пройден"

# Ротация локально.
mapfile -t old < <(ls -1t "$BACKUP_DIR/$AGENT"-*.tar.gz.gpg 2>/dev/null | tail -n +$((RETAIN + 1)))
for f in "${old[@]:-}"; do [[ -n "$f" ]] && rm -f "$f" && log "rotated: $f"; done

# Запасной канал в Drive: gws CLI под нашим OAuth-клиентом (~/.config/gws).
# ponytail: без своего кода загрузки -- зовём готовый хелпер +upload.
gws_upload() {
  local f="$1"
  command -v npx >/dev/null 2>&1 || return 1
  [[ -f "$HOME/.config/gws/client_secret.json" ]] || return 1
  npx --yes @googleworkspace/cli drive +upload "$f" >>"$LOG" 2>&1
}

# Off-site — только если rclone и remote настроены.
if [[ -x "$RCLONE_BIN" ]] && "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  # Общий OAuth-клиент rclone делит квоту Google на сотни агентов, и одиночный
  # 403 rateLimitExceeded почти всегда проходит со второй-третьей попытки.
  # Найдено агентом Гора 11.09.2026: бэкап падал 4 дня подряд, а тот же
  # рукой повторённый copy уезжал через несколько секунд.
  ok=""
  for attempt in 1 2 3 4 5; do
    if "$RCLONE_BIN" copy "$ARCHIVE" "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>>"$LOG"; then
      ok=1; break
    fi
    sleep $((attempt * 5))
  done
  if [[ -n "$ok" ]]; then
    log "OK off-site: ${RCLONE_REMOTE}:${RCLONE_PATH}/$(basename "$ARCHIVE")"
    # Мимо корзины: Google держит удалённое 30 дней и всё это время считает в квоту
    # (у Jarvis корзина старых архивов съела 8,3 ГБ из 15, 02.10.2026).
    "$RCLONE_BIN" delete --drive-use-trash=false --min-age "${RETAIN}d" "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>>"$LOG" || true
  elif gws_upload "$ARCHIVE"; then
    # rclone по умолчанию ходит под ОБЩИМ ключом -- в пик Google отвечает «квота».
    # Запасной канал: googleworkspace CLI, он авторизован под нашим собственным
    # OAuth-клиентом, и своя квота не зависит от чужих людей (проверено 11.09.2026).
    log "OK off-site через gws (rclone упёрся в квоту): $(basename "$ARCHIVE")"
  else
    fail "off-site не уехал ни через rclone, ни через gws (локальная копия цела)"
  fi
else
  log "WARN: нет rclone-remote '${RCLONE_REMOTE}' — бэкап ТОЛЬКО локальный (смерть VPS не переживёт)"
fi
exit 0
