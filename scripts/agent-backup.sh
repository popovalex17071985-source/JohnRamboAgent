#!/usr/bin/env bash
# Шифрованный бэкап ВСЕЙ домашней папки агента: память, характер, секреты,
# состояние канала И его работа — скрипты в ~/bin и ~/.local/bin, данные,
# проекты рядом с workspace. Минус мусор из deploy/backup-exclude.txt (кэши,
# node_modules, логи, сами архивы). Плюс пути вне домашки из
# deploy/backup-extra-paths (/opt/..., свои юниты, сайты nginx).
#
# До 16.10.2026 архив брал только .claude/secrets/state/deploy в workspace:
# умер сервер — агент помнил всё, кроме сделанной работы (bin/, data/, проекты,
# venv-ы, инструменты из ~/.local/bin пропадали).
#
# Что ещё кладётся в архив (deploy/, восстанавливает restore-agent.sh):
#   apt-manual.txt        пакеты, поставленные руками (apt-mark showmanual)
#   pyenvs/*.txt          список пакетов каждого venv + версия Python: сами venv
#                         в архив НЕ идут (непереносимы), их пересобирают
#   pyuser/*.txt          пакеты pip install --user (~/.local/lib/python3.*) +
#                         версия Python: сама папка в архив НЕ идёт
#   systemd-system/       юниты из /etc/systemd/system, которые запускают код агента
#   crontab.txt, channel.env, cron.d — как и раньше
#   timezone.txt          часовой пояс сервера (кроны идут по местному времени)
#   node-projects.txt     проекты, где node_modules срезан: там нужен npm install
# В корне архива DASHI-BACKUP.json — кто, откуда, какие доп. пути (формат 2).
#
# ВАЖНО про пароль: он лежит в secrets/backup.pass НА СЕРВЕРЕ. Установщик шлёт его
# хозяину файлом в Telegram (scripts/backup-pass-send.sh). Без пароля облачную
# копию не расшифровать.
#
# Режимы:
#   agent-backup.sh                  ночной прогон (крон), всегда exit 0
#   agent-backup.sh --init-excludes  создать deploy/backup-exclude.txt, если нет;
#                                    в старый список дописать новые шаблоны по умолчанию
#   agent-backup.sh --print-excludes итоговые шаблоны исключений (для проверки)
#   agent-backup.sh --size-report    сколько весит что попадёт в архив, без архива
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
source "$SCRIPT_DIR/backup-lib.sh"

AGENT="${DASHI_AGENT:?DASHI_AGENT не задан}"
WORKSPACE="${DASHI_WORKSPACE:?DASHI_WORKSPACE не задан}"   # /home/<user>/.claude-lab/<agent>
AGENT_HOME="${DASHI_HOME:-$HOME}"
KIND="${DASHI_KIND:-claude}"                              # claude | codex
BACKUP_DIR="${DASHI_BACKUP_DIR:-$WORKSPACE/backups}"
PASS_FILE="${DASHI_BACKUP_PASS:-$WORKSPACE/secrets/backup.pass}"
EXCLUDE_FILE="${DASHI_BACKUP_EXCLUDE:-$WORKSPACE/deploy/backup-exclude.txt}"
EXTRA_CONF="$WORKSPACE/deploy/backup-extra-paths"
CHANNEL_ENV="${DASHI_CHANNEL_ENV:-/etc/dashi-plugin/$AGENT/channel.env}"
SYSTEMD_DIR="${DASHI_SYSTEMD_DIR:-/etc/systemd/system}"
STATE_DIR="$WORKSPACE/state/backup"
LOG="$WORKSPACE/logs/backup.log"
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone 2>/dev/null || echo "$HOME/.local/bin/rclone")}"
RCLONE_REMOTE="${DASHI_RCLONE_REMOTE:-gdrive}"        # имя rclone-remote (off-site)
RCLONE_PATH="${DASHI_RCLONE_PATH:-dashi-$AGENT-backups}"
RETAIN="${DASHI_BACKUP_RETAIN:-7}"
GROWTH_WARN_MB="${DASHI_BACKUP_GROWTH_WARN_MB:-200}"

MODE="run"
case "${1:-}" in
  --init-excludes)  MODE=init ;;
  --print-excludes) MODE=print ;;
  --size-report)    MODE=size ;;
  "") ;;
  *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
esac

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")" "$WORKSPACE/deploy" "$STATE_DIR"
log() { echo "[$(date '+%F %T %Z')] $*" >>"$LOG"; }
fail() { log "FAIL: $*"; exit 0; }   # exit 0: cron must never jam on an error
attempt() {  # attempt <1|0> [error]: the last backup/upload try, for the watchdog's «failing»
  printf '{"ts": %s, "ok": %s, "error": %s}\n' "$(date +%s)" "$([[ $1 == 1 ]] && echo true || echo false)" \
    "$(bk_json_str "${2:-}")" >"$STATE_DIR/last-attempt.json"
}

# ── exclude list ────────────────────────────────────────────────────────────
init_excludes() {
  local added
  if [[ -s "$EXCLUDE_FILE" ]]; then
    # The owner's list is never regenerated; defaults added later are appended once.
    added="$(bk_append_new_defaults "$EXCLUDE_FILE")"
    [[ -n "$added" ]] && log "в список исключений дописаны новые шаблоны по умолчанию: $(tr '\n' ' ' <<<"$added")"
    return 0
  fi
  bk_default_excludes "$AGENT_HOME" "$WORKSPACE" >"$EXCLUDE_FILE"
  log "создан список исключений по умолчанию: $EXCLUDE_FILE"
}
init_excludes
[[ "$MODE" == init ]] && { echo "$EXCLUDE_FILE"; exit 0; }

# Extra paths outside home (one absolute path or glob per line).
extra_paths=()
read_extras() {
  [[ -f "$EXTRA_CONF" ]] || return 0
  local line p rel q dup matched
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != /* ]]; then log "extra: пропуск, путь не абсолютный: $line"; continue; fi
    matched=0
    # Globs are expanded here (nullglob, IFS= keeps spaces): an empty glob is a
    # log line, not a tar error.
    while IFS= read -r -d '' p; do
      matched=1
      p="${p%/}"; rel="$(bk_to_member "$p")"
      [[ -n "$rel" ]] || { log "extra: пропуск корня /"; continue; }
      if [[ "$p" == "$AGENT_HOME" || "$p" == "$AGENT_HOME"/* ]]; then
        log "extra: пропуск, это и так в архиве (домашняя папка): $p"; continue
      fi
      if [[ "$AGENT_HOME" == "$p"/* ]]; then
        log "extra: пропуск, путь содержит всю домашнюю папку: $p"; continue
      fi
      dup=0; for q in "${extra_paths[@]:-}"; do [[ "$q" == "$rel" ]] && dup=1; done
      [[ $dup -eq 1 ]] || extra_paths+=("$rel")
    done < <(shopt -s nullglob; IFS=; for g in $line; do
               [[ -e "$g" || -L "$g" ]] && printf '%s\0' "$g"; done)
    [[ $matched -eq 1 ]] || log "extra: пропуск, нет такого пути/пустой глоб: $line"
  done <"$EXTRA_CONF"
}
read_extras

# Python venvs under home and extra paths: excluded from the archive (not
# portable), their package lists go to deploy/pyenvs instead.
venvs=()
find_venvs() {
  local roots=("$AGENT_HOME") r cfg
  for r in "${extra_paths[@]:-}"; do [[ -n "$r" ]] && roots+=("/$r"); done
  while IFS= read -r -d '' cfg; do
    venvs+=("${cfg%/pyvenv.cfg}")
  done < <(find "${roots[@]}" -xdev -maxdepth 8 \
             \( -name node_modules -o -name .cache -o -path "$AGENT_HOME/.local/share/uv" \
                -o -path "$BACKUP_DIR" -o -path "$WORKSPACE/.claude/dashi-plugin-claude-code" \
                -o -path "$AGENT_HOME/.openviking" -o -name .git \) -prune \
             -o -name pyvenv.cfg -type f -print0 2>/dev/null)
}
find_venvs

EXCL=()
build_excludes() {
  local line pat
  while IFS= read -r line || [[ -n "$line" ]]; do
    if pat="$(bk_exclude_pattern "$line" "$AGENT_HOME")"; then
      [[ -n "$pat" ]] && EXCL+=("$pat")
    else
      log "исключения: строка отвергнута (срезала бы всю домашку): $line"
    fi
  done <"$EXCLUDE_FILE"
  # Always out, whatever the file says: the archives themselves, the plugin's git
  # clone (it is on GitHub), the staging folder of a previous restore, venvs.
  EXCL+=("$(bk_to_member "$BACKUP_DIR")"
         "$(bk_to_member "$WORKSPACE/.claude/dashi-plugin-claude-code")"
         "$(bk_to_member "$WORKSPACE/extra")")
  local v; for v in "${venvs[@]:-}"; do [[ -n "$v" ]] && EXCL+=("$(bk_to_member "$v")"); done
}
build_excludes
TAR_EXCL=(); for p in "${EXCL[@]}"; do TAR_EXCL+=("--exclude=$p"); done
HOME_M="$(bk_to_member "$AGENT_HOME")"

if [[ "$MODE" == print ]]; then printf '%s\n' "${EXCL[@]}"; exit 0; fi

if [[ "$MODE" == size ]]; then
  # tar into /dev/null does not read file contents: a fast, exact listing with sizes.
  # Grouped two levels below home (home/agent/projects/shop), extras likewise.
  depth=$(( $(tr -cd '/' <<<"$HOME_M" | wc -c) + 4 ))
  rep="$(tar -cvvf /dev/null --ignore-failed-read "${TAR_EXCL[@]}" -C / "$HOME_M" "${extra_paths[@]}" 2>/dev/null \
    | awk -v d="$depth" '
        $1 !~ /^d/ { size=$3; path=""; for (i=6;i<=NF;i++) path = path (i>6?" ":"") $i
          sub(/ -> .*/, "", path)
          n=split(path, a, "/"); k=a[1]; for (i=2;i<d && i<n;i++) k=k "/" a[i]
          s[k]+=size; t+=size; c++ }
        END { for (k in s) printf "%10.1f МБ  /%s\n", s[k]/1048576, k
              printf "TOTAL итого: %.1f МБ в %d файлах (до сжатия)\n", t/1048576, c }')"
  grep -v '^TOTAL ' <<<"$rep" | sort -rn | head -25
  grep '^TOTAL ' <<<"$rep" | sed 's/^TOTAL //'
  exit 0
fi

# ── run ─────────────────────────────────────────────────────────────────────
# Whatever happens below (fail() exits too), refresh the off-site status: the
# fleet health summary and the agent's own failure watch read it.
MAN_DIR=""; TAR_ERR=""
on_exit() {
  [[ -n "$MAN_DIR" ]] && rm -rf "$MAN_DIR"
  [[ -n "$TAR_ERR" ]] && rm -f "$TAR_ERR"
  bash "$SCRIPT_DIR/backup-offsite-watch.sh" --status-only >/dev/null 2>&1 || true
}
trap on_exit EXIT
[[ -s "$PASS_FILE" ]] || fail "нет пароля: $PASS_FILE — прогони установку бэкапа"
cd "$WORKSPACE" || fail "не могу зайти в $WORKSPACE"

STAMP="$(date +%Y%m%d-%H%M)"
ARCHIVE="$BACKUP_DIR/$AGENT-$STAMP.tar.gz.gpg"
PREV="$(ls -1t "$BACKUP_DIR/$AGENT"-*.tar.gz.gpg 2>/dev/null | head -1)"

# System config that lives OUTSIDE home: crontab, the agent's own units, channel.env.
crontab -l >deploy/crontab.txt 2>/dev/null || true
for u in "$SYSTEMD_DIR/dashi-$AGENT.service" "$AGENT_HOME/.config/systemd/user/dashi-$AGENT.service"; do
  [[ -f "$u" ]] && cp -f "$u" deploy/ 2>/dev/null || true
done
# channel.env (bot token, access, paths) lives in /etc: root:agent 660, readable.
cp -f "/etc/dashi-plugin/$AGENT/channel.env" deploy/channel.env 2>/dev/null || true
for c in "/etc/cron.d/dashi-$AGENT"-*; do [[ -f "$c" ]] && cp -f "$c" deploy/ 2>/dev/null || true; done

# Hand-installed system packages: restore-agent.sh installs whatever a new box lacks.
apt-mark showmanual >deploy/apt-manual.txt 2>/dev/null || : >deploy/apt-manual.txt
# Server timezone: cron lines are local time; a new box in UTC shifts every job.
{ timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null; } \
  | head -1 >deploy/timezone.txt

# Venvs: what is in each one and which Python built it. A venv rebuilt on another
# Python minor dies on binary wheels (Jarvis DR drill 16.10.2026, numpy on 3.10).
rm -rf deploy/pyenvs; mkdir -p deploy/pyenvs
for v in "${venvs[@]:-}"; do
  [[ -n "$v" && -x "$v/bin/python" ]] || continue
  ver="$("$v/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || continue
  pkgs="$("$v/bin/python" -m pip freeze 2>/dev/null)" \
    || pkgs="$(command -v uv >/dev/null && uv pip freeze --python "$v/bin/python" 2>/dev/null)" || pkgs=""
  sys_site=false
  grep -qiE '^include-system-site-packages *= *true' "$v/pyvenv.cfg" 2>/dev/null && sys_site=true
  slug="$(sed 's#^/##; s#[/. ]#_#g' <<<"$v")"
  printf '# venv=%s python=%s system_site=%s\n%s\n' "$v" "$ver" "$sys_site" "$pkgs" >"deploy/pyenvs/$slug.txt"
done

# pip install --user packages (~/.local/lib/pythonX.Y): excluded like venvs (Albert
# carried 1.3 GB of them into the cloud), their list goes to deploy/pyuser instead.
# pip itself when it works for that Python; else the dist-info headers (the Python
# may be gone, or its pip broken).
rm -rf deploy/pyuser; mkdir -p deploy/pyuser
for site in "$AGENT_HOME"/.local/lib/python3*/site-packages; do
  [[ -d "$site" ]] || continue
  ver="${site%/site-packages}"; ver="${ver##*/python}"
  pkgs=""
  if command -v "python$ver" >/dev/null 2>&1; then
    pkgs="$(HOME="$AGENT_HOME" "python$ver" -m pip list --user --format=freeze --exclude-editable 2>/dev/null)" || pkgs=""
  fi
  if [[ -z "$pkgs" ]]; then
    pkgs="$(for m in "$site"/*.dist-info/METADATA "$site"/*.egg-info/PKG-INFO; do
              [[ -f "$m" ]] || continue
              awk -F': ' '{sub(/\r$/, "")} /^$/ {exit} $1 == "Name" {n = $2} $1 == "Version" {v = $2}
                          END {if (n != "" && v != "") print n "==" v}' "$m"
            done | sort -fu)"
  fi
  [[ -n "$pkgs" ]] || continue
  printf '# user-site python=%s\n%s\n' "$ver" "$pkgs" >"deploy/pyuser/python$ver.txt"
done

# Is this absolute path inside the archive's extra paths? A listed dir covers its
# files and a glob covers what it matched (extra_paths holds the expanded paths);
# an exact-line match missed /opt/repair-X/.env under a listed /opt/repair-X.
covered_by_extras() {  # covered_by_extras </abs/path>
  local m="${1#/}" r
  for r in "${extra_paths[@]:-}"; do
    [[ -n "$r" ]] || continue
    [[ "$m" == "$r" || "$m" == "$r"/* ]] && return 0
  done
  return 1
}

# Units in /etc/systemd/system that belong to this agent: run as its user, point
# into its home, or carry its name. Copies + which of them were enabled.
rm -rf deploy/systemd-system; mkdir -p deploy/systemd-system
me="$(id -un)"
for u in "$SYSTEMD_DIR"/*.service "$SYSTEMD_DIR"/*.timer; do
  [[ -f "$u" && ! -L "$u" ]] || continue
  n="$(basename "$u")"
  mine=0
  [[ "$n" == dashi-"$AGENT"* || "$n" == *-"$AGENT".service ]] && mine=1
  [[ "$me" != root ]] && grep -qE "^User=$me[[:space:]]*$" "$u" && mine=1
  grep -qF "$AGENT_HOME/" "$u" && mine=1
  # A timer belongs if its service was taken (services are walked first): the
  # canary timer cron-canary-<agent>.timer carries neither a user nor a home path.
  [[ "$n" == *.timer && -f "deploy/systemd-system/${n%.timer}.service" ]] && mine=1
  [[ $mine -eq 1 ]] || continue
  cp -f "$u" deploy/systemd-system/ 2>/dev/null || continue
  [[ "$(systemctl is-enabled "$n" 2>/dev/null)" == enabled ]] && echo "$n" >>deploy/systemd-system/enabled.txt
  # Env files outside home are not in the archive unless listed in extra paths.
  grep -oE '^EnvironmentFile=-?/[^ ]+' "$u" | sed 's/^EnvironmentFile=-\{0,1\}//' | while IFS= read -r ef; do
    [[ "$ef" == "$AGENT_HOME"/* || "$ef" == "/etc/dashi-plugin/$AGENT/"* ]] && continue
    covered_by_extras "$ef" || log "WARN: юнит $n читает $ef вне домашки -- добавь путь в deploy/backup-extra-paths"
  done
done

# Node projects whose node_modules is cut out: restore runs npm/bun install there.
: >deploy/node-projects.txt
find "$AGENT_HOME" -xdev -maxdepth 6 \
  \( -path "$WORKSPACE/.claude/dashi-plugin-claude-code" -o -path "$AGENT_HOME/.npm-global" \
     -o -path "$AGENT_HOME/.bun" -o -path "$AGENT_HOME/.cache" -o -path "$AGENT_HOME/.npm" \
     -o -path "$BACKUP_DIR" -o -name .git \) -prune \
  -o -type d -name node_modules -prune -print 2>/dev/null \
  | while IFS= read -r nm; do [[ -f "${nm%/node_modules}/package.json" ]] && echo "${nm%/node_modules}"; done \
  | sort -u >deploy/node-projects.txt
# Global npm tools when npm's prefix is inside home (their node_modules is cut too).
npm_prefix="$(npm config get prefix 2>/dev/null || true)"
if [[ -n "$npm_prefix" && "$npm_prefix" == "$AGENT_HOME"/* && -d "$npm_prefix/lib/node_modules" ]]; then
  for d in "$npm_prefix"/lib/node_modules/* "$npm_prefix"/lib/node_modules/@*/*; do
    [[ -f "$d/package.json" && "$(basename "$d")" != npm ]] || continue
    python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j["name"]+"@"+j["version"])' "$d/package.json" 2>/dev/null
  done >deploy/npm-global.txt
else
  rm -f deploy/npm-global.txt
fi

# Manifest at the archive root: restore reads it first.
MAN_DIR="$(mktemp -d)"; TAR_ERR="$(mktemp)"
{
  printf '{"format": 2, "agent": %s, "kind": %s, "user": %s,\n' \
    "$(bk_json_str "$AGENT")" "$(bk_json_str "$KIND")" "$(bk_json_str "$me")"
  printf ' "home": %s, "workspace": %s, "host": %s, "created": %s,\n' \
    "$(bk_json_str "$AGENT_HOME")" "$(bk_json_str "$WORKSPACE")" \
    "$(bk_json_str "$(hostname 2>/dev/null)")" "$(bk_json_str "$(date -Iseconds)")"
  printf ' "extras": ['
  sep=""; for p in "${extra_paths[@]:-}"; do [[ -n "$p" ]] && { printf '%s%s' "$sep" "$(bk_json_str "/$p")"; sep=", "; }; done
  printf ']}\n'
} >"$MAN_DIR/DASHI-BACKUP.json"
cp -f "$MAN_DIR/DASHI-BACKUP.json" deploy/backup-manifest.json
[[ ${#extra_paths[@]} -gt 0 ]] && log "extra: в архив идут ${#extra_paths[@]} путь(ей) вне домашки"

# Disk pre-check: a full disk must not leave a half-written archive behind. The
# estimate is the uncompressed size (tar into /dev/null reads no contents), an upper
# bound for the archive; the first whole-home run can be 10x the old workspace-only one.
est_b="$(tar -cvvf /dev/null --ignore-failed-read "${TAR_EXCL[@]}" -C / "$HOME_M" "${extra_paths[@]}" 2>/dev/null \
  | awk '$1 !~ /^d/ {s += $3} END {printf "%.0f", s}')"
free_b="${DASHI_BACKUP_FREE_BYTES:-$(df -PB1 "$BACKUP_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')}"
if [[ "$est_b" =~ ^[0-9]+$ && "$free_b" =~ ^[0-9]+$ ]]; then
  need_b=$(( est_b + est_b / 10 + 100 * 1048576 ))
  if (( free_b < need_b )); then
    msg="мало места на диске: архиву нужно до $((need_b / 1048576)) МБ, свободно $((free_b / 1048576)) МБ в $BACKUP_DIR"
    attempt 0 "$msg"
    fail "$msg. Архив не писал, прошлые копии целы. Что тяжёлое: agent-backup.sh --size-report; лишнее -- в deploy/backup-exclude.txt"
  fi
fi

# --ignore-failed-read: live dirs change under us, and the OpenViking container
# leaves root-owned files in ~/.openviking; neither may cost the whole night.
# Excludes come BEFORE -C: in GNU tar they apply to the names that follow them.
tar czf - --ignore-failed-read "${TAR_EXCL[@]}" \
  -C "$MAN_DIR" DASHI-BACKUP.json -C / "$HOME_M" "${extra_paths[@]}" 2>"$TAR_ERR" \
  | gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASS_FILE" -o "$ARCHIVE" 2>>"$LOG"
rc=("${PIPESTATUS[@]}"); tar_rc=${rc[0]}; gpg_rc=${rc[1]}
unreadable="$(grep -cE 'Permission denied|Cannot open|Cannot read' "$TAR_ERR" 2>/dev/null || true)"
if [[ "${unreadable:-0}" -gt 0 ]]; then
  log "WARN: tar не смог прочитать $unreadable файл(ов), они не в архиве: $(grep -m3 -E 'Permission denied|Cannot open|Cannot read' "$TAR_ERR" | tr '\n' ' ' | cut -c1-400)"
fi
grep -vE 'Permission denied|Cannot open|Cannot read|file changed as we read it|socket ignored' "$TAR_ERR" | head -5 >>"$LOG"
# tar exit 1 = "file changed as we read it" (archive valid); 2 = fatal.
if [[ $tar_rc -gt 1 || $gpg_rc -ne 0 ]]; then
  rm -f "$ARCHIVE"; fail "tar|gpg упал (tar=$tar_rc gpg=$gpg_rc)"
fi
# Self-check: the fresh archive MUST decrypt and list. A broken backup is worse
# than none: it gives a false sense of safety. Failed -> delete and FAIL.
check="$(gpg --batch --quiet --passphrase-file "$PASS_FILE" -d "$ARCHIVE" 2>>"$LOG" | tar tvzf - 2>>"$LOG" \
  | awk '$NF == "DASHI-BACKUP.json" {m=1} $1 !~ /^d/ {s+=$3; c++}
         END {printf "%d|%.0f МБ в %d файлах", m, s/1048576, c}'
  echo "|${PIPESTATUS[0]}${PIPESTATUS[1]}")"
pipe_rc="${check##*|}"; check="${check%|*}"
if [[ "$pipe_rc" != 00 ]]; then
  rm -f "$ARCHIVE"; fail "self-check: свежий архив не расшифровался/не читается — удалён"
fi
[[ "${check%%|*}" == 1 ]] || { rm -f "$ARCHIVE"; fail "self-check: в архиве нет DASHI-BACKUP.json — удалён"; }
raw_mb="${check#*|}"
size_b=$(stat -c %s "$ARCHIVE")
log "OK local: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1); до сжатия $raw_mb), self-check пройден"
if [[ -n "$PREV" && -f "$PREV" ]]; then
  prev_b=$(stat -c %s "$PREV")
  if (( size_b > 2 * prev_b && size_b - prev_b > GROWTH_WARN_MB * 1048576 )); then
    log "WARN: архив вырос с $((prev_b/1048576)) до $((size_b/1048576)) МБ -- проверь, что попало: agent-backup.sh --size-report"
  fi
fi

# Local rotation.
mapfile -t old < <(ls -1t "$BACKUP_DIR/$AGENT"-*.tar.gz.gpg 2>/dev/null | tail -n +$((RETAIN + 1)))
for f in "${old[@]:-}"; do [[ -n "$f" ]] && rm -f "$f" && log "rotated: $f"; done

offsite_ok() {  # offsite_ok <method>: remember the last good copy for the watchdog
  attempt 1
  printf '{"ts": %s, "method": %s, "file": %s, "remote": %s}\n' "$(date +%s)" \
    "$(bk_json_str "$1")" "$(bk_json_str "$(basename "$ARCHIVE")")" \
    "$(bk_json_str "${RCLONE_REMOTE}:${RCLONE_PATH}")" >"$STATE_DIR/last-offsite.json"
}

# Fallback to Drive: gws CLI under our own OAuth client (~/.config/gws).
gws_upload() {
  local f="$1"
  command -v npx >/dev/null 2>&1 || return 1
  [[ -f "$HOME/.config/gws/client_secret.json" ]] || return 1
  npx --yes @googleworkspace/cli drive +upload "$f" >>"$LOG" 2>&1
}

# Off-site — only when rclone and the remote are configured.
if [[ -x "$RCLONE_BIN" ]] && "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  # rclone's shared OAuth client splits Google's quota across everyone; a single
  # 403 rateLimitExceeded almost always passes on the 2nd-3rd try (Gor, 11.09.2026).
  ok=""
  for attempt in 1 2 3 4 5; do
    if "$RCLONE_BIN" copy "$ARCHIVE" "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>>"$LOG"; then
      ok=1; break
    fi
    sleep $((attempt * 5))
  done
  if [[ -n "$ok" ]]; then
    log "OK off-site: ${RCLONE_REMOTE}:${RCLONE_PATH}/$(basename "$ARCHIVE")"
    offsite_ok rclone
    # Skip the trash: Google keeps deleted files 30 days and counts them in quota
    # (Jarvis: old archives in the trash ate 8.3 of 15 GB, 02.10.2026).
    "$RCLONE_BIN" delete --drive-use-trash=false --min-age "${RETAIN}d" "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>>"$LOG" || true
  elif gws_upload "$ARCHIVE"; then
    log "OK off-site через gws (rclone упёрся в квоту): $(basename "$ARCHIVE")"
    offsite_ok gws
  else
    attempt 0 "$(grep -E 'ERROR|Failed' "$LOG" | tail -1 | cut -c1-200)"
    fail "off-site не уехал ни через rclone, ни через gws (локальная копия цела)"
  fi
else
  log "WARN: нет rclone-remote '${RCLONE_REMOTE}' — бэкап ТОЛЬКО локальный (смерть VPS не переживёт)"
fi
exit 0
