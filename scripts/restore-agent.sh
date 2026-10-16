#!/usr/bin/env bash
# restore-agent.sh — поднять агента из шифрованного бэкапа на чистом сервере,
# одной командой, как install-agent.sh ставит нового.
#
# ПЕРЕД ЗАПУСКОМ: старый сервер ВЫКЛЮЧИ (или убедись, что он мёртв). Иначе два
# агента сидят на одном токене бота: сообщения достаются то одному, то другому,
# кроны и рассылки идут дважды.
#
# Что делает: берёт архив (файл или облако rclone) → проверяет пароль →
# раскладывает домашнюю папку агента целиком (память, характер, секреты, его
# проекты и скрипты) → возвращает channel.env, расписание, свои юниты →
# ставит пакеты apt, которых нет → пересобирает venv тем же Python →
# доставляет систему установщиком (install-agent.sh / install-codex.sh, они
# идемпотентны и восстановленное не трогают). Сбой отдельного шага — предупреждение
# в конце, а не обрыв: агент поднимается, недоделанное видно списком.
#
#   sudo bash restore-agent.sh --name myagent \
#        --archive gdrive:dashi-myagent-backups/myagent-20261016-0340.tar.gz.gpg \
#        --pass 'ПАРОЛЬ_ИЗ_МЕНЕДЖЕРА'
#   (--archive — локальный файл или remote:путь; без --pass спросит)
#   --envs-only      только пересобрать venv/npm (после того как поставил нужный Python)
#   --force-extract  распаковать архив заново, даже если он уже распакован
#   --kind codex     Codex-агент (обычно берётся из архива сам)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
source "$SCRIPT_DIR/backup-lib.sh"

SERVICE_USER="${DASHI_SERVICE_USER:-}"
AGENT_NAME=""; ARCHIVE=""; PASS=""; KIND=""
REPO_URL="${DASHI_REPO_URL:-https://github.com/popovalex17071985-source/JohnRamboAgent.git}"
BRANCH="${DASHI_BRANCH:-main}"; ASSUME_YES=0; ENVS_ONLY=0; FORCE_EXTRACT=0
STATE_ROOT="${DASHI_RESTORE_STATE:-/var/lib/dashi-restore}"
WARNS=()

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; WARNS+=("$*"); }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    AGENT_NAME="$2"; shift 2 ;;
    --archive) ARCHIVE="$2";    shift 2 ;;
    --pass)    PASS="$2";       shift 2 ;;
    --user)    SERVICE_USER="$2"; shift 2 ;;
    --repo)    REPO_URL="$2";   shift 2 ;;
    --branch)  BRANCH="$2";     shift 2 ;;
    --kind)    KIND="$2";       shift 2 ;;
    --envs-only) ENVS_ONLY=1;   shift ;;
    --force-extract) FORCE_EXTRACT=1; shift ;;
    --yes|-y)  ASSUME_YES=1;    shift ;;
    --help|-h) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный аргумент: $1 (--help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0 ..."
[[ -n "$AGENT_NAME" ]] || die "нужен --name <имя агента>"
mkdir -p "$STATE_ROOT"; chmod 700 "$STATE_ROOT"
STATE_ENV="$STATE_ROOT/$AGENT_NAME.env"
# deploy/ snapshots of the OLD server, stashed right after unpacking: the installer's
# first backup rewrites <workspace>/deploy from the NEW box (Smith e2e 16.10.2026:
# the agent's own shop-web.service was lost that way). Root-only, holds channel.env.
SNAP="$STATE_ROOT/$AGENT_NAME.deploy"

home_of() { [[ "$1" == root ]] && echo /root || echo "/home/$1"; }
# Old absolute path -> the same place on this box (another user = another home).
map_path() { if [[ "$OLD_HOME" != "$NEW_HOME" && "$1" == "$OLD_HOME"/* ]]; then
               printf '%s' "$NEW_HOME/${1#"$OLD_HOME"/}"; else printf '%s' "$1"; fi; }
owner_of() { stat -c %U "$1" 2>/dev/null || echo root; }
as_user() { local u="$1"; shift; if [[ "$u" == root ]]; then "$@"; else runuser -u "$u" -- "$@"; fi; }

# ── step: system packages ───────────────────────────────────────────────────
restore_apt() {
  local list="$SNAP/apt-manual.txt" pkg cand missing=() unavailable=() failed=()
  [[ -s "$list" ]] || { warn "нет списка пакетов apt в архиве (старый бэкап?) — пропускаю"; return 0; }
  say "Ставлю системные пакеты, которые стояли на старом сервере"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || warn "apt-get update с ошибкой — ставлю по старым спискам"
  while IFS= read -r pkg; do
    pkg="${pkg%%#*}"; pkg="${pkg//[[:space:]]/}"
    [[ -n "$pkg" ]] || continue
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && continue
    # A package with no candidate (third-party repo not added) would fail the batch.
    cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')"
    if [[ -z "$cand" || "$cand" == "(none)" ]]; then unavailable+=("$pkg"); else missing+=("$pkg"); fi
  done <"$list"
  if [[ ${#missing[@]} -gt 0 ]]; then
    if ! apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
      for pkg in "${missing[@]}"; do apt-get install -y -qq "$pkg" >/dev/null 2>&1 || failed+=("$pkg"); done
    fi
  fi
  ok "пакетов поставлено: $(( ${#missing[@]} - ${#failed[@]} )), остальные уже были"
  [[ ${#unavailable[@]} -gt 0 ]] && warn "нет в репозиториях (свой источник apt не подключён?): ${unavailable[*]}"
  [[ ${#failed[@]} -gt 0 ]] && warn "не поставились: ${failed[*]}"
  return 0
}

# ── step: server timezone (cron lines are written in the OLD server's local time) ─
restore_timezone() {
  local want cur others
  want="$(head -1 "$SNAP/timezone.txt" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$want" ]] || return 0
  cur="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
  cur="${cur:-Etc/UTC}"
  [[ "$cur" == "$want" ]] && { ok "часовой пояс как на старом сервере: $want"; return 0; }
  # Another agent already lives here: its crons are in the current zone, don't move them.
  others="$(find /etc/dashi-plugin -mindepth 1 -maxdepth 1 -type d ! -name "$AGENT_NAME" 2>/dev/null | head -1)"
  if [[ -n "$others" && "$cur" != Etc/UTC && "$cur" != UTC ]]; then
    warn "часовой пояс: старый сервер $want, здесь $cur и уже живёт другой агент — расписание агента сдвинется, проверь кроны"
    return 0
  fi
  [[ -e "/usr/share/zoneinfo/$want" ]] || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tzdata >/dev/null 2>&1
  if timedatectl set-timezone "$want" >/dev/null 2>&1 \
     || { [[ -e "/usr/share/zoneinfo/$want" ]] && ln -sf "/usr/share/zoneinfo/$want" /etc/localtime && echo "$want" >/etc/timezone; }; then
    systemctl restart cron >/dev/null 2>&1 || true
    ok "часовой пояс сервера: $want (как на старом, кроны идут в то же время)"
  else
    warn "часовой пояс не выставлен: на старом был $want — sudo timedatectl set-timezone $want"
  fi
}

# ── step: Python venvs (rebuilt with the SAME Python minor) ──────────────────
python_for() {  # python_for 3.10 -> path to python3.10 or empty (tries apt once)
  local v="$1" py="python$1" cand
  if ! command -v "$py" >/dev/null 2>&1; then
    cand="$(apt-cache policy "$py" 2>/dev/null | awk '/Candidate:/ {print $2}')"
    [[ -n "$cand" && "$cand" != "(none)" ]] && apt-get install -y -qq "$py" >/dev/null 2>&1
  fi
  command -v "$py" >/dev/null 2>&1 || return 0
  # Ubuntu ships `venv` separately: without pythonX.Y-venv the build fails on ensurepip.
  if ! "$py" -c 'import ensurepip' >/dev/null 2>&1; then
    apt-get install -y -qq "python$v-venv" >/dev/null 2>&1 || true
  fi
  command -v "$py"
}

rebuild_envs() {
  local snaps=("$SNAP"/pyenvs/*.txt) s venv ver sys py owner req built=0 skipped=0
  [[ -e "${snaps[0]}" ]] || { ok "venv в архиве не было"; return 0; }
  say "Пересобираю Python-окружения (venv): ${#snaps[@]} шт."
  for s in "${snaps[@]}"; do
    venv="$(map_path "$(bk_venv_field "$s" venv)")"; ver="$(bk_venv_field "$s" python)"
    sys="$(bk_venv_field "$s" system_site)"
    [[ -n "$venv" && -n "$ver" ]] || { warn "снимок venv без заголовка: $s"; continue; }
    if [[ -x "$venv/bin/python" ]] && "$venv/bin/python" -m pip --version >/dev/null 2>&1; then
      skipped=$((skipped + 1)); continue          # idempotent: already rebuilt
    fi
    if [[ ! -d "$(dirname "$venv")" ]]; then
      warn "venv $venv: папки нет (путь вне домашки — сначала верни его из extra/, потом --envs-only)"; continue
    fi
    py="$(python_for "$ver")"
    if [[ -z "$py" ]]; then
      warn "venv $venv: нет python$ver на этом сервере. Поставь: add-apt-repository -y ppa:deadsnakes/ppa && apt install -y python$ver-venv, потом: bash $0 --name $AGENT_NAME --envs-only"
      continue
    fi
    owner="$(owner_of "$(dirname "$venv")")"
    req="$(mktemp)"; bk_freeze_filter <"$s" >"$req" 2>"$req.skip"; chmod 644 "$req"
    [[ -s "$req.skip" ]] && warn "venv $venv: пропущены локальные пакеты: $(tr '\n' ' ' <"$req.skip" | cut -c1-200)"
    local args=(-m venv --clear); [[ "$sys" == true ]] && args+=(--system-site-packages)
    if as_user "$owner" "$py" "${args[@]}" "$venv" >/dev/null 2>&1 \
       && { [[ ! -s "$req" ]] || as_user "$owner" "$venv/bin/pip" install -q -r "$req" >/dev/null 2>"$req.err"; }; then
      built=$((built + 1)); ok "venv $venv (python$ver)"
    else
      warn "venv $venv не собрался: $(tail -2 "$req.err" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    fi
    rm -f "$req" "$req.skip" "$req.err"
  done
  ok "venv пересобрано: $built, уже были: $skipped"
}

# ── step: node (after the installer: it brings node/npm) ─────────────────────
rebuild_node() {
  local f="$SNAP/node-projects.txt" d owner tool
  if [[ -s "$SNAP/npm-global.txt" ]]; then
    if command -v npm >/dev/null 2>&1; then
      xargs -a "$SNAP/npm-global.txt" runuser -u "$SERVICE_USER" -- npm install -g --silent >/dev/null 2>&1 \
        && ok "глобальные npm-пакеты агента поставлены" || warn "глобальные npm-пакеты не встали: $(tr '\n' ' ' <"$SNAP/npm-global.txt")"
    else
      warn "npm нет — глобальные пакеты не поставлены: $(tr '\n' ' ' <"$SNAP/npm-global.txt")"
    fi
  fi
  [[ -s "$f" ]] || return 0
  say "Ставлю зависимости node-проектов (node_modules в архив не идут)"
  while IFS= read -r d; do
    d="$(map_path "$d")"
    [[ -d "$d" && ! -d "$d/node_modules" ]] || continue
    owner="$(owner_of "$d")"
    if [[ -f "$d/bun.lock" || -f "$d/bun.lockb" ]] && command -v bun >/dev/null 2>&1; then tool=(bun install)
    elif [[ -f "$d/package-lock.json" ]]; then tool=(npm ci --silent)
    else tool=(npm install --silent); fi
    command -v "${tool[0]}" >/dev/null 2>&1 || { warn "$d: нет ${tool[0]}"; continue; }
    (cd "$d" && as_user "$owner" "${tool[@]}" >/dev/null 2>&1) && ok "$d" || warn "$d: ${tool[*]} не прошёл"
  done <"$f"
}

# ── step: units of the agent from /etc/systemd/system ────────────────────────
restore_units() {
  local dir="$SNAP/systemd-system" u n placed=0
  [[ -d "$dir" ]] || return 0
  for u in "$dir"/*.service "$dir"/*.timer; do
    [[ -f "$u" ]] || continue
    n="$(basename "$u")"
    [[ -e "/etc/systemd/system/$n" ]] && continue      # the installer's own, or already back
    sed "s#$OLD_HOME/#$NEW_HOME/#g" "$u" >"/etc/systemd/system/$n"; placed=$((placed + 1))
  done
  [[ $placed -gt 0 ]] && { systemctl daemon-reload; ok "юнитов возвращено: $placed"; }
  [[ -s "$dir/enabled.txt" ]] || return 0
  while IFS= read -r n; do
    [[ -n "$n" && -e "/etc/systemd/system/$n" ]] || continue
    systemctl is-active --quiet "$n" && continue
    systemctl enable --now "$n" >/dev/null 2>&1 && ok "запущен $n" || warn "юнит $n не стартовал: systemctl status $n"
  done <"$dir/enabled.txt"
}

restore_user_units() {
  [[ "$SERVICE_USER" != root ]] || return 0
  local wants=("$NEW_HOME"/.config/systemd/user/*.wants/*) uid u
  [[ -e "${wants[0]}" ]] || return 0
  uid="$(id -u "$SERVICE_USER")"
  loginctl enable-linger "$SERVICE_USER" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -d "/run/user/$uid" ]] && break; sleep 1; done
  [[ -d "/run/user/$uid" ]] || { warn "пользовательские юниты: нет /run/user/$uid (linger не поднялся)"; return 0; }
  runuser -u "$SERVICE_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1
  for u in "${wants[@]}"; do
    u="$(basename "$u")"
    runuser -u "$SERVICE_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user start "$u" >/dev/null 2>&1 \
      && ok "запущен (user) $u" || warn "пользовательский юнит $u не стартовал"
  done
}

summary() {
  say "Готово"
  ok "агент $AGENT_NAME восстановлен из бэкапа"
  if [[ ${#WARNS[@]} -gt 0 ]]; then
    printf '\n    \033[33mНе доделано (%d) — агент работает, это доделать руками:\033[0m\n' "${#WARNS[@]}"
    printf '      - %s\n' "${WARNS[@]}"
  fi
}

# ── --envs-only: re-run only the environment rebuild ─────────────────────────
if [[ $ENVS_ONLY -eq 1 ]]; then
  [[ -s "$STATE_ENV" ]] || die "нет $STATE_ENV — сначала полный restore"
  # shellcheck disable=SC1090
  source "$STATE_ENV"
  rebuild_envs; rebuild_node; summary; exit 0
fi

[[ -n "$ARCHIVE" ]] || die "нужен --archive <локальный файл или remote:путь>"

# ── 0. the old server must be off ────────────────────────────────────────────
say "Старый сервер должен быть выключен"
cat <<'EOF'
    Восстановленный агент сразу подключится к тому же боту. Если старый сервер
    ещё жив — два агента будут драться за сообщения, кроны и рассылки пойдут
    дважды. Выключи старый сервер в панели хостинга (или убедись, что он мёртв).
EOF
if [[ $ASSUME_YES -eq 0 ]]; then
  __a=""; read -r -p "    Старый сервер выключен? [y/N] " __a </dev/tty || true
  [[ "$__a" =~ ^[YyДд] ]] || die "сначала выключи старый сервер, потом запусти снова"
fi

# gpg decrypts, python3 reads the manifest; a minimal VPS/container may lack both.
need=()
command -v gpg >/dev/null 2>&1 || need+=(gnupg)
command -v python3 >/dev/null 2>&1 || need+=(python3)
if [[ ${#need[@]} -gt 0 ]]; then
  say "Ставлю ${need[*]} (нужно для расшифровки)"
  (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null 2>&1) \
    || die "не смог поставить ${need[*]} — поставь вручную: apt install ${need[*]}"
  ok "${need[*]} установлен(ы)"
fi

# ── 1. fetch the archive ─────────────────────────────────────────────────────
say "Беру архив"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOCAL_ARCH="$TMP/$(basename "$ARCHIVE")"
if [[ -f "$ARCHIVE" ]]; then
  cp -f "$ARCHIVE" "$LOCAL_ARCH"
elif [[ "$ARCHIVE" == *:* ]]; then
  RCLONE_BIN="$(command -v rclone || true)"
  [[ -n "$RCLONE_BIN" ]] || die "нужен rclone, чтобы забрать $ARCHIVE (или укажи локальный файл)"
  "$RCLONE_BIN" copyto "$ARCHIVE" "$LOCAL_ARCH" 2>&1 | tail -2 || die "rclone не смог забрать $ARCHIVE"
else
  die "архив не найден: $ARCHIVE"
fi
[[ -s "$LOCAL_ARCH" ]] || die "архив пустой/не скачался: $ARCHIVE"
ok "архив на месте ($(du -h "$LOCAL_ARCH" | cut -f1))"

if [[ -z "$PASS" ]]; then
  read -r -s -p "    Пароль от бэкапа: " PASS </dev/tty; echo
fi
[[ -n "$PASS" ]] || die "без пароля архив не расшифровать"
PASSFILE="$TMP/pass"; (umask 077; printf '%s' "$PASS" >"$PASSFILE")
decrypt() { gpg --batch --quiet --passphrase-file "$PASSFILE" -d "$LOCAL_ARCH" 2>/dev/null; }

# ── 2. check the password BEFORE touching anything ──────────────────────────
say "Проверяю пароль"
decrypt | tar tzf - >"$TMP/list" 2>/dev/null || die "пароль неверный или архив битый — расшифровать не удалось"
ok "пароль верный, архив читается ($(wc -l <"$TMP/list") записей)"

FORMAT=1; grep -qx 'DASHI-BACKUP.json' "$TMP/list" && FORMAT=2
if [[ $FORMAT -eq 2 ]]; then
  decrypt | tar xzf - -O DASHI-BACKUP.json >"$TMP/manifest.json" 2>/dev/null
  mf() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print("\n".join(v) if isinstance(v, list) else v)' "$TMP/manifest.json" "$1"; }
  M_AGENT="$(mf agent)"; M_KIND="$(mf kind)"; M_USER="$(mf user)"; OLD_HOME="$(mf home)"; OLD_WS="$(mf workspace)"
  [[ -n "$OLD_HOME" && -n "$OLD_WS" ]] || die "манифест архива неполный"
  [[ "$M_AGENT" == "$AGENT_NAME" ]] || die "это архив агента «$M_AGENT», а --name $AGENT_NAME"
  KIND="${KIND:-${M_KIND:-claude}}"; SERVICE_USER="${SERVICE_USER:-${M_USER:-agent}}"
  NEW_HOME="$(home_of "$SERVICE_USER")"
  WORKSPACE="$(map_path "$OLD_WS")"
  ok "архив формата 2: вся домашка ($OLD_HOME), агент $M_AGENT ($KIND), снят $(mf created)"
else
  KIND="${KIND:-claude}"; SERVICE_USER="${SERVICE_USER:-agent}"
  NEW_HOME="$(home_of "$SERVICE_USER")"; OLD_HOME="$NEW_HOME"
  WORKSPACE="$NEW_HOME/.claude-lab/$AGENT_NAME"
  ok "архив старого формата (только workspace)"
fi
[[ "$OLD_HOME" != "$NEW_HOME" ]] && warn "домашняя папка была $OLD_HOME, теперь $NEW_HOME — пути в своих скриптах агента проверь"

# The user must exist before unpacking into its home.
if [[ "$SERVICE_USER" != root ]] && ! id "$SERVICE_USER" >/dev/null 2>&1; then
  say "Создаю пользователя $SERVICE_USER"
  adduser --disabled-password --gecos "" "$SERVICE_USER" >/dev/null
  ok "пользователь создан"
fi

# ── 3. unpack (once per archive: a re-run continues instead of overwriting) ──
DONE="$STATE_ROOT/$AGENT_NAME.done"
if [[ $FORCE_EXTRACT -eq 0 && -s "$DONE" && "$(cat "$DONE")" == "$(basename "$ARCHIVE")" ]]; then
  say "Данные уже распакованы из этого архива — не трогаю (заново: --force-extract)"
else
  say "Восстанавливаю данные агента"
  if [[ $FORMAT -eq 2 ]]; then
    OLD_M="$(bk_to_member "$OLD_HOME")"; NEW_M="$(bk_to_member "$NEW_HOME")"
    xform=()
    if [[ "$OLD_M" != "$NEW_M" ]]; then
      xform=("--transform=s,^$(printf '%s' "$OLD_M" | sed 's/[][\.*^$,]/\\&/g'),$NEW_M,")
    fi
    decrypt | tar xzf - -C / "${xform[@]}" "$OLD_M" || die "распаковка домашней папки не удалась"
    [[ "$SERVICE_USER" != root ]] && chown -R "$SERVICE_USER:$SERVICE_USER" "$NEW_HOME"
    ok "домашняя папка восстановлена: $NEW_HOME"
    # Extras (paths outside home) go to <workspace>/extra/<path>, never in place.
    if grep -qvE "^($(printf '%s' "$OLD_M" | sed 's/[][\.*^$|()+?{}]/\\&/g')(/|$)|DASHI-BACKUP\.json$)" "$TMP/list"; then
      mkdir -p "$WORKSPACE/extra"
      decrypt | tar xzf - -C "$WORKSPACE/extra" --anchored --exclude="$OLD_M" --exclude=DASHI-BACKUP.json --no-anchored \
        || warn "доп. пути из архива распаковались не полностью"
    fi
  else
    mkdir -p "$WORKSPACE"; chown "$SERVICE_USER:$SERVICE_USER" "$NEW_HOME/.claude-lab" "$WORKSPACE" 2>/dev/null
    decrypt | tar xzf - -C "$WORKSPACE" || die "распаковка не удалась"
    find "$WORKSPACE" -mindepth 1 -maxdepth 1 ! -name extra -exec chown -R "$SERVICE_USER:$SERVICE_USER" {} +
    chown "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE"
    # Old format carries long-term memory as .openviking/ inside the workspace.
    if [[ -d "$WORKSPACE/.openviking" ]]; then
      if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx openviking; then
        docker stop openviking >/dev/null && OV_WAS_UP=1
      fi
      [[ -e "$NEW_HOME/.openviking" ]] && mv "$NEW_HOME/.openviking" "$NEW_HOME/.openviking.pre-restore-$(date +%Y%m%d-%H%M)"
      mv "$WORKSPACE/.openviking" "$NEW_HOME/.openviking"
      chown -R "$SERVICE_USER:$SERVICE_USER" "$NEW_HOME/.openviking"
    fi
    ok "данные восстановлены в $WORKSPACE"
  fi
  # The off-site journal tells about the OLD server's uploads: carried over, it made
  # the watchdog say «OK» right after this box's first upload failed (Smith e2e).
  for f in last-offsite.json last-attempt.json offsite-status.json; do
    [[ -f "$WORKSPACE/state/backup/$f" ]] && mv -f "$WORKSPACE/state/backup/$f" "$WORKSPACE/state/backup/$f.old-server"
  done
  rm -rf "$SNAP"
  basename "$ARCHIVE" >"$DONE"
fi
if [[ ! -d "$SNAP" && -d "$WORKSPACE/deploy" ]]; then
  cp -a "$WORKSPACE/deploy" "$SNAP" && chmod 700 "$SNAP"
fi
cat >"$STATE_ENV" <<EOF
AGENT_NAME='$AGENT_NAME'
SERVICE_USER='$SERVICE_USER'
KIND='$KIND'
OLD_HOME='$OLD_HOME'
NEW_HOME='$NEW_HOME'
WORKSPACE='$WORKSPACE'
EOF

# Backups before 12.10.2026 carry ov.conf without storage.workspace: image 0.4.21+
# then starts on an empty base («memory is gone»). Pin it before the container starts.
OV_FIX="$SCRIPT_DIR/../agent-kit/scripts/ov-conf-fix.py"
if [[ -f "$OV_FIX" && -s "$NEW_HOME/.openviking/ov.conf" ]]; then
  python3 "$OV_FIX" "$NEW_HOME/.openviking" | sed 's/^/    /'
  chown -R "$SERVICE_USER:$SERVICE_USER" "$NEW_HOME/.openviking" 2>/dev/null || true
fi
# The container stopped for the swap comes back only after ov.conf is pinned.
[[ -n "${OV_WAS_UP:-}" ]] && docker start openviking >/dev/null

# Packages first: crontab, python, tools the agent's scripts call come from apt.
restore_apt
restore_timezone

# ── 4. system config that lives outside home (snapshot in deploy/) ──────────
if [[ -d "$SNAP" ]]; then
  say "Возвращаю системный конфиг"
  if [[ "$KIND" == claude && -f "$SNAP/channel.env" ]]; then
    mkdir -p "/etc/dashi-plugin/$AGENT_NAME"
    sed "s#$OLD_HOME/#$NEW_HOME/#g" "$SNAP/channel.env" >"/etc/dashi-plugin/$AGENT_NAME/channel.env"
    chown "root:$SERVICE_USER" "/etc/dashi-plugin/$AGENT_NAME/channel.env"; chmod 660 "/etc/dashi-plugin/$AGENT_NAME/channel.env"
    ok "channel.env возвращён (токен бота, доступ)"
  fi
  for c in "$SNAP/dashi-$AGENT_NAME"-*; do
    [[ -f "$c" ]] || continue
    sed "s#$OLD_HOME/#$NEW_HOME/#g" "$c" >"/etc/cron.d/$(basename "$c")"; chmod 644 "/etc/cron.d/$(basename "$c")"
  done
  if [[ -s "$SNAP/crontab.txt" ]]; then
    sed "s#$OLD_HOME/#$NEW_HOME/#g" "$SNAP/crontab.txt" | crontab -u "$SERVICE_USER" - 2>/dev/null \
      && ok "crontab агента восстановлен" || warn "crontab не встал: crontab -u $SERVICE_USER $SNAP/crontab.txt"
  fi
  # Log dirs: log CONTENTS are not in the archive, but a cron line appending into a
  # missing dir fails every run (Jarvis DR drill #6, 16.10.2026).
  n=0
  while IFS= read -r d; do
    [[ -n "$d" && ! -d "$d" ]] || continue
    mkdir -p "$d" && n=$((n + 1))
    [[ "$d" == "$NEW_HOME"/* && "$SERVICE_USER" != root ]] && chown -R "$SERVICE_USER:$SERVICE_USER" "$d"
  done < <(cat "$SNAP/crontab.txt" "$SNAP"/dashi-"$AGENT_NAME"-* 2>/dev/null \
             | sed "s#$OLD_HOME/#$NEW_HOME/#g" | bk_log_dirs_from_cron)
  mkdir -p "$WORKSPACE/logs"; [[ "$SERVICE_USER" != root ]] && chown "$SERVICE_USER:$SERVICE_USER" "$WORKSPACE/logs"
  ok "папки логов из расписания на месте (создано $n)"
fi

# ── 4b. extra paths outside home: shown, never written over system paths ────
if [[ -d "$WORKSPACE/extra" ]]; then
  say "В архиве были доп. пути вне домашки"
  warn "доп. пути лежат в $WORKSPACE/extra/<путь> — на место НЕ ставлю, это вручную (сначала diff -r)"
  if [[ -f "$SNAP/backup-extra-paths" ]]; then
    sed 's/#.*//; /^[[:space:]]*$/d; s/^[[:space:]]*/      /' "$SNAP/backup-extra-paths"
  else
    (cd "$WORKSPACE/extra" && find . -mindepth 1 -maxdepth 3 | sed 's|^\.|      |' | head -20)
  fi
  ex=""
  while IFS= read -r l; do
    l="${l%%#*}"; l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [[ "$l" == /* && -e "$WORKSPACE/extra$l" ]] && { ex="$l"; break; }
  done < <(cat "$SNAP/backup-extra-paths" 2>/dev/null)
  echo "    Вернуть, например (сначала сравни: diff -r <из extra> <на месте>):"
  if [[ -d "$WORKSPACE/extra$ex" && -n "$ex" ]]; then
    echo "      sudo cp -a --backup=numbered \"$WORKSPACE/extra$ex/.\" \"$ex/\""
  elif [[ -n "$ex" ]]; then
    echo "      sudo cp -a --backup=numbered \"$WORKSPACE/extra$ex\" \"$ex\""
  else
    echo "      sudo cp -a --backup=numbered \"$WORKSPACE/extra/<путь>\" \"/<путь>\""
  fi
fi

# ── 5. Python environments (before the agent starts using them) ─────────────
rebuild_envs

# ── 6. the system part: the installer (idempotent, keeps restored data) ─────
say "Доставляю систему через установщик (идемпотентно)"
if [[ "$KIND" == codex ]]; then
  if [[ -f "$SCRIPT_DIR/install-codex.sh" ]]; then
    bash "$SCRIPT_DIR/install-codex.sh" --yes || warn "install-codex.sh завершился с ошибкой — см. вывод выше"
  else
    warn "рядом нет install-codex.sh — скачай его и запусти: bash install-codex.sh"
  fi
else
  if [[ -f "$SCRIPT_DIR/install-agent.sh" ]]; then
    # Bot token and user id come from the restored channel.env — no questions.
    bash "$SCRIPT_DIR/install-agent.sh" --name "$AGENT_NAME" --user "$SERVICE_USER" \
         --repo "$REPO_URL" --branch "$BRANCH" --yes \
      || warn "установщик завершился с ошибкой — см. вывод выше"
  else
    warn "рядом нет install-agent.sh ($SCRIPT_DIR)"
  fi
fi

# ── 7. the rest of the agent's own world ────────────────────────────────────
rebuild_node
restore_units
restore_user_units

summary
if [[ "$KIND" == claude ]]; then
  if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-' "/etc/dashi-plugin/$AGENT_NAME/channel.env" 2>/dev/null; then
    echo "    Вход в Claude не нужен: годовой токен приехал из бэкапа вместе с channel.env."
  else
    echo "    Остался вход в Claude: sudo bash $SCRIPT_DIR/install-agent.sh --name $AGENT_NAME — он проведёт по шагам."
  fi
fi
exit 0
