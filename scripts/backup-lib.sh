# shellcheck shell=bash
# backup-lib.sh -- shared helpers for agent-backup.sh, restore-agent.sh,
# backup-offsite-watch.sh and backup-pass-send.sh. Sourced, never executed.
#
# Pure functions (no side effects) come first so tests can source this file
# without root, network or a real agent: tests/agent-backup-home-smoke.sh.

# ── archive member names ────────────────────────────────────────────────────
# The archive (format 2) is rooted at /: the agent home is stored as
# "home/agent/...", extra paths as "opt/app/...". Member names never start
# with "/", so every absolute path is turned into that form before it is used
# as an exclude pattern or a member to add.
bk_to_member() {  # bk_to_member /abs/path -> abs/path
  local p="$1"
  while [[ "$p" == /* ]]; do p="${p#/}"; done
  while [[ "$p" == */ && -n "$p" ]]; do p="${p%/}"; done
  printf '%s' "$p"
}

# One line of deploy/backup-exclude.txt -> one tar exclude pattern (stdout).
# Empty output = skip the line. Return 1 = the line is dangerous (would drop
# the whole home) and was refused; the caller logs it.
#   ~/x        -> <home as member>/x   (the agent's home, whoever runs it)
#   /abs/x     -> abs/x                (one path)
#   bare-name  -> bare-name            (tar unanchored: that name anywhere)
bk_exclude_pattern() {  # bk_exclude_pattern "<line>" "<agent home>"
  local line="$1" home="$2" p
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] || return 0
  case "$line" in
    "~"|"~/"|"/"|"*"|"/*"|"~/*"|"."|"./") return 1 ;;
  esac
  if [[ "$line" == "~/"* ]]; then
    p="$(bk_to_member "$home")/${line#\~/}"
  elif [[ "$line" == /* ]]; then
    p="$(bk_to_member "$line")"
  else
    p="$line"
  fi
  # The home itself as a pattern would empty the archive.
  [[ "$p" == "$(bk_to_member "$home")" || -z "$p" ]] && return 1
  printf '%s' "$p"
}

# Default exclude list, written once into deploy/backup-exclude.txt. The owner
# edits that file; the script never rewrites it. Workspace lines are given
# relative to the home (~/<ws>) so the file survives a move to another user.
bk_default_excludes() {  # bk_default_excludes <home> <workspace>
  local home="$1" ws="$2" w
  if [[ "$ws" == "$home"/* ]]; then w="~/${ws#"$home"/}"; else w="$ws"; fi
  cat <<EOF
# Что ночной бэкап НЕ кладёт в архив. Архив берёт ВСЮ домашнюю папку агента
# ($home) минус строки ниже — так в него попадают и рабочие папки рядом с
# агентом, и скрипты в ~/bin и ~/.local/bin, и данные проектов.
#
# Одна строка — один шаблон, после # — комментарий:
#   ~/путь      папка или файл в домашней папке агента
#   /абс/путь   один путь
#   имя         папка/файл с таким именем где угодно (например node_modules)
#   папка/*     содержимое папки без неё самой: папка на новом сервере
#               останется, и кроны, которые пишут туда логи, не упадут
#
# Виртуальные окружения Python (venv) режутся сами: в архив идёт их список
# пакетов (deploy/pyenvs), restore-agent.sh пересобирает их тем же Python.
# Сам каталог архивов и git-копия плагина режутся сами тоже.

# --- где угодно: пересобирается само ---
__pycache__
*.pyc
node_modules
.pytest_cache
.mypy_cache

# --- содержимое логов (папки остаются пустыми) ---
*.log
*.log.[0-9]*
$w/logs/*
$w/.claude/logs/*
$w/tmp/*
$w/scratchpad/*

# --- кэши и программы, которые ставит установщик ---
~/.cache
~/.npm
~/.bun
~/.local/share/claude
~/.local/share/uv
~/.local/share/Trash
~/.local/share/docker
~/.docker
~/.rustup
~/.cargo/registry
~/go/pkg/mod
~/.claude/plugins/cache
~/.claude/plugins/marketplaces
~/.claude/debug
~/.claude/shell-snapshots
~/.claude/file-history
# расшифровки сессий Claude (много места); память рядом с ними (memory/) остаётся
~/.claude/projects/*.jsonl
# пакеты Python, поставленные pip install --user: в архив идёт их список
# (deploy/pyuser), restore-agent.sh ставит их заново
~/.local/lib/python3*
# Python, который uv скачал ремонтнику: установщик ставит его заново
/opt/repair-*/python

# --- файлы из Telegram и временное агента ---
$w/state/telegram/inbox

# --- долгая память: временное и замки живой базы ---
~/.openviking/appdata/temp
~/.openviking/data/.openviking.lock
~/.openviking/appdata/.openviking.lock
EOF
}

# Log dirs that cron lines write into: «>> /path/x.log», «> /p/y.log 2>&1».
# One directory per line on stdout, absolute only, unique.
bk_log_dirs_from_cron() {  # bk_log_dirs_from_cron < crontab text
  grep -v '^[[:space:]]*#' \
    | grep -oE '(^|[[:space:]])[0-9]?>>?[[:space:]]*/[^[:space:];|&]+' \
    | sed -E 's/^[[:space:]]*[0-9]?>>?[[:space:]]*//' \
    | while IFS= read -r f; do
        [[ "$f" == /dev/* ]] && continue
        printf '%s\n' "${f%/*}"
      done | sort -u
}

# `pip freeze` output -> requirement lines pip can install on a new box.
# Editable checkouts and local file URLs point at paths that may not exist yet:
# they go to stderr as «skip: ...» instead of breaking the whole install.
bk_freeze_filter() {  # bk_freeze_filter < freeze  > requirements
  local l
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ -z "$l" || "$l" == \#* ]] && continue
    if [[ "$l" == -e\ * || "$l" == *" @ file://"* ]]; then
      printf 'skip: %s\n' "$l" >&2; continue
    fi
    printf '%s\n' "$l"
  done
}

# Header of a deploy/pyenvs/*.txt snapshot:
#   # venv=/home/agent/proj/.venv python=3.10 system_site=false
bk_venv_field() {  # bk_venv_field <file> venv|python|system_site
  head -1 "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# ── Telegram: the agent's own bot ───────────────────────────────────────────
# Token and owner chat come from the agent's env file:
#   Claude agents: /etc/dashi-plugin/<agent>/channel.env
#     TELEGRAM_BOT_TOKEN, owner = DASHI_CHAT_ID or first TELEGRAM_ALLOWED_USER_IDS
#   Codex agents:  /root/agent-main/.env
#     TELEGRAM_TOKEN, owner = TELEGRAM_CHAT_ID
# Same rule as agent-kit tg-send.py. Extra recipients (e.g. the fleet operator,
# if he has pressed Start in this bot): DASHI_BACKUP_ALERT_CHATS=id1,id2.
bk_env_get() {  # bk_env_get <file> <KEY>
  [[ -r "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | tail -1 | tr -d '"'"'"'\r'
}

bk_tg_token() {  # bk_tg_token <env file>
  local t; t="$(bk_env_get "$1" TELEGRAM_BOT_TOKEN)"
  [[ -n "$t" ]] || t="$(bk_env_get "$1" TELEGRAM_TOKEN)"
  printf '%s' "$t"
}

bk_tg_owner() {  # bk_tg_owner <env file>
  local c; c="$(bk_env_get "$1" DASHI_CHAT_ID)"
  [[ -n "$c" ]] || c="$(bk_env_get "$1" TELEGRAM_CHAT_ID)"
  [[ -n "$c" ]] || { c="$(bk_env_get "$1" TELEGRAM_ALLOWED_USER_IDS)"; c="${c%%,*}"; }
  printf '%s' "${c//[[:space:]]/}"
}

bk_tg_extra_chats() {  # bk_tg_extra_chats <env file> -> one id per line
  local c="${DASHI_BACKUP_ALERT_CHATS:-}"
  [[ -n "$c" ]] || c="$(bk_env_get "$1" DASHI_BACKUP_ALERT_CHATS)"
  tr ', ' '\n\n' <<<"$c" | sed '/^$/d'
}

# The token never goes to argv (ps shows argv to every user): curl reads the
# URL from a config on stdin. DASHI_TG_DRYRUN_DIR=<dir> writes the call into
# files instead of sending -- used by tests.
_bk_tg_call() {  # _bk_tg_call <token> <method> curl-args...
  local token="$1" method="$2"; shift 2
  if [[ -n "${DASHI_TG_DRYRUN_DIR:-}" ]]; then
    mkdir -p "$DASHI_TG_DRYRUN_DIR"
    printf '%s\n' "$method" "$@" >"$DASHI_TG_DRYRUN_DIR/$(date +%s%N).call"
    printf '{"ok":true,"result":{"message_id":1}}'
    return 0
  fi
  printf 'url = "%s/bot%s/%s"\n' "${TELEGRAM_API_ROOT:-https://api.telegram.org}" "$token" "$method" \
    | curl -sS -m 30 -K - "$@"
}

bk_tg_send_text() {  # bk_tg_send_text <token> <chat> <text>  -> 0 if Telegram said ok
  local out
  out="$(_bk_tg_call "$1" sendMessage --data-urlencode "chat_id=$2" --data-urlencode "text=$3" 2>&1)" || return 1
  grep -q '"ok":true' <<<"$out"
}

bk_tg_send_file() {  # bk_tg_send_file <token> <chat> <file> <caption> -> prints message_id
  local out
  out="$(_bk_tg_call "$1" sendDocument -F "chat_id=$2" -F "caption=$4" -F "document=@$3" 2>&1)" || return 1
  grep -q '"ok":true' <<<"$out" || { printf '%s' "$out" | grep -oE '"description":"[^"]*"' >&2; return 1; }
  grep -oE '"message_id":[0-9]+' <<<"$out" | head -1 | cut -d: -f2
}

# ── misc ────────────────────────────────────────────────────────────────────
bk_json_str() {  # bk_json_str <text> -> "escaped"
  local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Default patterns added AFTER lists were already created on live agents. A list is
# never regenerated (the owner edits it), so these get appended once to old lists.
# "pattern|why" -- why becomes the comment above the appended line.
BK_ADDED_DEFAULTS=(
  "~/.local/lib/python3*|пакеты pip install --user: в архив идёт их список (deploy/pyuser), восстановление ставит их заново (у Альберта было 1,3 ГБ)"
  "/opt/repair-*/python|Python, который uv скачал ремонтнику: установщик ставит его заново"
)

# Append the added defaults an existing list lacks. A pattern present anywhere in
# the file -- even commented out (the owner's opt-out) -- is left alone; owner
# lines are never touched. Prints the appended patterns.
bk_append_new_defaults() {  # bk_append_new_defaults <exclude file>
  local f="$1" e pat why block=""
  [[ -f "$f" ]] || return 0
  for e in "${BK_ADDED_DEFAULTS[@]}"; do
    pat="${e%%|*}"; why="${e#*|}"
    grep -qF -- "$pat" "$f" && continue
    block+="# $why"$'\n'"$pat"$'\n'
    printf '%s\n' "$pat"
  done
  [[ -n "$block" ]] || return 0
  {
    printf '\n# добавлено обновлением плагина %s. Не нужно — закомментируй строку (#),\n' "$(date +%F)"
    printf '# а не удаляй: удалённая вернётся при следующем бэкапе.\n'
    printf '%s' "$block"
  } >>"$f"
}

# A shell file that is `source`d later: every value quoted with %q, so a quote,
# space or $ in a path cannot break it or run as code.
bk_write_state_env() {  # bk_write_state_env <file> VAR...
  local f="$1" v; shift
  { for v in "$@"; do printf '%s=%q\n' "$v" "${!v-}"; done; } >"$f"
}
