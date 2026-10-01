#!/usr/bin/env bash
# restore-agent.sh — поднять агента из шифрованного бэкапа на чистом сервере,
# так же одной командой, как install-agent.sh ставит нового.
#
# Что делает: находит архив (локальный или в облаке rclone) → расшифровывает
# паролем → раскладывает данные агента (память, характер, секреты, состояние,
# channel.env, crontab, юнит) → передаёт системную часть установщику
# (install-agent.sh идемпотентен: увидит восстановленные данные и не затрёт их,
# доставит только систему/сервис/хуки). Вход в Claude обычно не нужен:
# годовой токен (CLAUDE_CODE_OAUTH_TOKEN) приезжает внутри channel.env из бэкапа.
#
# Пример:
#   sudo bash restore-agent.sh --name myagent \
#        --archive gdrive:dashi-myagent-backups/myagent-20260824-0340.tar.gz.gpg \
#        --pass 'ПАРОЛЬ_ИЗ_МЕНЕДЖЕРА'
#   (--archive можно указать и локальным файлом; --pass можно не давать — спросит)
set -uo pipefail

SERVICE_USER="${DASHI_SERVICE_USER:-agent}"
AGENT_NAME=""; ARCHIVE=""; PASS=""; REPO_URL="${DASHI_REPO_URL:-https://github.com/popovalex17071985-source/dashi-plugin-claude-code.git}"
BRANCH="${DASHI_BRANCH:-main}"; ASSUME_YES=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    AGENT_NAME="$2"; shift 2 ;;
    --archive) ARCHIVE="$2";    shift 2 ;;
    --pass)    PASS="$2";       shift 2 ;;
    --user)    SERVICE_USER="$2"; shift 2 ;;
    --repo)    REPO_URL="$2";   shift 2 ;;
    --branch)  BRANCH="$2";     shift 2 ;;
    --yes|-y)  ASSUME_YES=1;    shift ;;
    --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный аргумент: $1 (--help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0 ..."
[[ -n "$AGENT_NAME" ]] || die "нужен --name <имя агента>"
[[ -n "$ARCHIVE" ]] || die "нужен --archive <локальный файл или remote:путь>"

WORKSPACE="/home/$SERVICE_USER/.claude-lab/$AGENT_NAME"
CLAUDE_DIR="$WORKSPACE/.claude"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
as_agent() { su - "$SERVICE_USER" -c "$1"; }

# gpg нужен для расшифровки, на минимальном VPS его может не быть. Ставим сами.
if ! command -v gpg >/dev/null 2>&1; then
  say "Ставлю gnupg (нужен для расшифровки)"
  (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg >/dev/null 2>&1) \
    || die "не смог поставить gnupg — поставь вручную: apt install gnupg"
  ok "gnupg установлен"
fi

# Пользователь агента должен существовать до распаковки в его домашку.
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  say "Создаю пользователя $SERVICE_USER"
  adduser --disabled-password --gecos "" "$SERVICE_USER" >/dev/null
  ok "пользователь создан"
fi
mkdir -p "$WORKSPACE"; chown "$SERVICE_USER:$SERVICE_USER" "/home/$SERVICE_USER/.claude-lab" "$WORKSPACE"

# 1. Достать архив (облако или локальный файл) во временный.
say "Беру архив"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOCAL_ARCH="$TMP/$(basename "$ARCHIVE")"
if [[ -f "$ARCHIVE" ]]; then
  cp -f "$ARCHIVE" "$LOCAL_ARCH"
elif [[ "$ARCHIVE" == *:* ]]; then
  RCLONE_BIN="$(command -v rclone || su - "$SERVICE_USER" -c 'command -v rclone' || true)"
  [[ -n "$RCLONE_BIN" ]] || die "нужен rclone, чтобы забрать $ARCHIVE (или укажи локальный файл)"
  "$RCLONE_BIN" copyto "$ARCHIVE" "$LOCAL_ARCH" 2>&1 | tail -2 || die "rclone не смог забрать $ARCHIVE"
else
  die "архив не найден: $ARCHIVE"
fi
[[ -s "$LOCAL_ARCH" ]] || die "архив пустой/не скачался: $ARCHIVE"
ok "архив на месте ($(du -h "$LOCAL_ARCH" | cut -f1))"

# 2. Пароль.
if [[ -z "$PASS" ]]; then
  read -r -s -p "    Пароль от бэкапа: " PASS </dev/tty; echo
fi
[[ -n "$PASS" ]] || die "без пароля архив не расшифровать"
PASSFILE="$TMP/pass"; printf '%s' "$PASS" > "$PASSFILE"

# 3. Проверить, что расшифровывается, ДО того как что-то трогаем.
say "Проверяю пароль"
gpg --batch --quiet --passphrase-file "$PASSFILE" -d "$LOCAL_ARCH" 2>/dev/null | tar tzf - >/dev/null 2>&1 \
  || die "пароль неверный или архив битый — расшифровать не удалось"
ok "пароль верный, архив читается"

# 4. Распаковать данные в workspace.
say "Восстанавливаю данные агента"
gpg --batch --quiet --passphrase-file "$PASSFILE" -d "$LOCAL_ARCH" 2>/dev/null \
  | tar xzf - -C "$WORKSPACE"
chown -R "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE"
ok "данные восстановлены в $WORKSPACE"

# 4b. Долгая память приезжает в архиве как .openviking/ -- её место в домашке
#     пользователя, куда смотрит контейнер OpenViking. Старую не удаляем, а
#     откладываем рядом; контейнер на время подмены останавливаем.
if [[ -d "$WORKSPACE/.openviking" ]]; then
  say "Возвращаю долгую память"
  OV_HOME="/home/$SERVICE_USER/.openviking"
  OV_WAS_UP=""
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx openviking; then
    docker stop openviking >/dev/null && OV_WAS_UP=1
  fi
  [[ -e "$OV_HOME" ]] && mv "$OV_HOME" "$OV_HOME.pre-restore-$(date +%Y%m%d-%H%M)"
  mv "$WORKSPACE/.openviking" "$OV_HOME"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$OV_HOME"
  [[ -n "$OV_WAS_UP" ]] && docker start openviking >/dev/null
  ok "память на месте ($OV_HOME)"
fi

# 5. Вернуть на место то, что лежит вне workspace (снимок в deploy/).
if [[ -d "$WORKSPACE/deploy" ]]; then
  say "Возвращаю системный конфиг"
  if [[ -f "$WORKSPACE/deploy/channel.env" ]]; then
    mkdir -p "/etc/dashi-plugin/$AGENT_NAME"
    cp -f "$WORKSPACE/deploy/channel.env" "/etc/dashi-plugin/$AGENT_NAME/channel.env"
    chown "root:$SERVICE_USER" "/etc/dashi-plugin/$AGENT_NAME/channel.env"; chmod 660 "/etc/dashi-plugin/$AGENT_NAME/channel.env"
    ok "channel.env возвращён (токен бота, доступ)"
  fi
  for c in "$WORKSPACE/deploy/dashi-$AGENT_NAME"-*; do
    [[ -f "$c" ]] && cp -f "$c" /etc/cron.d/ && chmod 644 "/etc/cron.d/$(basename "$c")"
  done
  [[ -f "$WORKSPACE/deploy/crontab.txt" ]] && as_agent "crontab '$WORKSPACE/deploy/crontab.txt'" 2>/dev/null \
    && ok "crontab агента восстановлен"
fi

# 6. Системная часть — переиспользуем установщик (идемпотентен: данные уже на
#    месте, он их не тронет, доставит систему/Node/Bun/сервис/хуки).
say "Доставляю систему через установщик (идемпотентно)"
[[ -x "$SCRIPT_DIR/install-agent.sh" ]] || die "рядом нет install-agent.sh ($SCRIPT_DIR)"
# Токен и user-id берём из восстановленного channel.env — установщик их увидит и не спросит.
bash "$SCRIPT_DIR/install-agent.sh" --name "$AGENT_NAME" --user "$SERVICE_USER" \
     --repo "$REPO_URL" --branch "$BRANCH" --yes \
  || die "установщик завершился с ошибкой — см. вывод выше"

say "Готово"
ok "агент $AGENT_NAME восстановлен из бэкапа"
if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-' "/etc/dashi-plugin/$AGENT_NAME/channel.env" 2>/dev/null; then
  echo "    Вход в Claude не нужен: годовой токен приехал из бэкапа вместе с channel.env."
else
  echo "    Остался вход в Claude: sudo bash $SCRIPT_DIR/install-agent.sh --name $AGENT_NAME — он проведёт по шагам."
fi
