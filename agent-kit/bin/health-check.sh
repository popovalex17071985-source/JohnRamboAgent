#!/usr/bin/env bash
# health-check.sh -- VPS health snapshot
# Output: table [Проверка | Статус | Детали]
# Exit codes: 0=all OK, 1=any WARN, 2=any FAIL
# Self-tests: HEALTH_TEST=1 bash health-check.sh

set -uo pipefail

CRED_PATH="${CRED_PATH:-$HOME/.claude/.credentials.json}"
# claude-gateway retired at the plugin cutover (2026-06-14); dropped from monitoring
# 2026-06-18 after a clean run on the plugin — was firing a daily false FAIL.
AGENT="__AGENT__"
WORKSPACE="${WORKSPACE:-__WORKSPACE__}"
# Сервисы агента: свой юнит всегда, ремонтник — если поставлен.
SERVICES=("dashi-$AGENT")
systemctl list-unit-files "claude-repair-$AGENT.service" >/dev/null 2>&1 \
  && SERVICES+=("claude-repair-$AGENT")
# Годовой токен (`claude setup-token`) НЕ создаёт .credentials.json -- он лежит в
# env-файле службы. Установка через токен давала ежедневный ложный FAIL «creds missing»
# при полностью живом агенте (Саня 07.09.2026, новый агент после установки).
TOKEN_ENV="${TOKEN_ENV:-/etc/dashi-plugin/$AGENT/channel.env}"
HEARTBEAT="${HEARTBEAT:-$WORKSPACE/data/cron-heartbeat}"
BACKUP_DIR="${BACKUP_DIR:-$WORKSPACE/backups}"
# Когда агент впервые увидел нынешний годовой токен: "HASH EPOCH". Дата env-файла
# сама по себе врёт -- его переписывают set-bot-token.sh, restore-agent.sh (cp -f)
# и прочие, и токен «молодеет». Поэтому дату запоминаем один раз на токен.
AUTH_STAMP="${AUTH_STAMP:-$WORKSPACE/data/claude-token-seen}"
YEAR_TOKEN_DAYS=365

# --- Pure functions (tested) ---

# classify_pct VALUE WARN_AT FAIL_AT LABEL -> echoes "STATUS|DETAILS"
classify_pct() {
  local pct="$1" warn="$2" fail="$3" label="$4"
  if [ "$pct" -ge "$fail" ]; then
    printf 'FAIL|%s %s%%\n' "$label" "$pct"
  elif [ "$pct" -ge "$warn" ]; then
    printf 'WARN|%s %s%%\n' "$label" "$pct"
  else
    printf 'OK|%s %s%%\n' "$label" "$pct"
  fi
}

# classify_load LOAD_1M CORES -> echoes "STATUS|DETAILS"
# WARN if load >= cores*0.7, FAIL if load >= cores
classify_load() {
  local load="$1" cores="$2"
  local warn_thr fail_thr
  warn_thr=$(awk "BEGIN{print $cores*0.7}")
  fail_thr="$cores"
  awk -v l="$load" -v w="$warn_thr" -v f="$fail_thr" -v c="$cores" '
    BEGIN {
      if (l+0 >= f+0)      printf "FAIL|load %.2f / %d cores\n", l, c;
      else if (l+0 >= w+0) printf "WARN|load %.2f / %d cores\n", l, c;
      else                 printf "OK|load %.2f / %d cores\n", l, c;
    }'
}

# classify_service NAME ACTIVE_STATE -> echoes "STATUS|DETAILS"
classify_service() {
  local name="$1" state="$2"
  case "$state" in
    active)              printf 'OK|%s: %s\n'   "$name" "$state" ;;
    activating|reloading) printf 'WARN|%s: %s\n' "$name" "$state" ;;
    *)                   printf 'FAIL|%s: %s\n' "$name" "$state" ;;
  esac
}

# classify_credentials PATH -> echoes "STATUS|DETAILS"
# Второй аргумент -- env-файл службы; если там лежит годовой токен, вход в порядке
# даже без .credentials.json (интерактивного /login на таком агенте не было).
classify_credentials() {
  local path="$1" env_file="${2:-}"
  if [ ! -s "$path" ] && [ -n "$env_file" ] \
     && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-' "$env_file" 2>/dev/null; then
    printf 'OK|годовой токен в %s\n' "$env_file"
  elif [ ! -e "$path" ]; then
    printf 'FAIL|входа нет: ни %s, ни годового токена в %s\n' "$path" "${env_file:-env}"
  elif [ ! -s "$path" ]; then
    printf 'FAIL|%s empty\n' "$path"
  else
    local size
    size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    printf 'OK|%s (%db)\n' "$path" "$size"
  fi
}

# classify_auth_expiry DAYS_LEFT KIND -> echoes "STATUS|DETAILS"
# Саня 30.08.2026: «а в архитектуре новых агентов будет это?». Проверка входа
# смотрит «вход на месте», а вход умирает по СРОКУ -- и агент замолкает целиком.
# Порог у годового шире (месяц): новый выпускают руками и не за один вечер.
classify_auth_expiry() {
  local left="$1" kind="$2" warn=30
  [ "$kind" = "месячный вход" ] && warn=7
  if [ "$left" -le 0 ]; then
    printf 'FAIL|%s ИСТЁК -- агент замолчит\n' "$kind"
  elif [ "$left" -le "$warn" ]; then
    printf 'WARN|%s кончается через %d дн\n' "$kind" "$left"
  else
    printf 'OK|%s: ещё %d дн\n' "$kind" "$left"
  fi
}

# auth_days_left -> echoes "DAYS|KIND", or nothing when there is no expiry to read.
# Годовой токен в env службы главнее .credentials.json: служба ходит с ним, а
# файл от старого /login может лежать давно протухшим (у Джарвиса -27 дн при
# живом агенте). Годовой токен непрозрачный, срока внутри нет: год от первой
# встречи с этим токеном (первая встреча -- дата env-файла на тот момент).
auth_days_left() {
  local now; now=$(date +%s)
  local line; line=$(grep -m1 '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-' "$TOKEN_ENV" 2>/dev/null)
  if [ -n "$line" ]; then
    local hash seen=""
    hash=$(printf '%s' "$line" | sha256sum | cut -c1-16)
    if [ "$(cut -d' ' -f1 "$AUTH_STAMP" 2>/dev/null)" = "$hash" ]; then
      seen=$(cut -d' ' -f2 "$AUTH_STAMP" 2>/dev/null)
    fi
    if ! [[ "$seen" =~ ^[0-9]+$ ]]; then
      seen=$(stat -c%Y "$TOKEN_ENV" 2>/dev/null || echo "$now")
      mkdir -p "$(dirname "$AUTH_STAMP")" 2>/dev/null
      printf '%s %s\n' "$hash" "$seen" > "$AUTH_STAMP" 2>/dev/null
    fi
    printf '%d|годовой токен\n' "$(( YEAR_TOKEN_DAYS - (now - seen) / 86400 ))"
    return
  fi
  local ms
  ms=$(/usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(int(d.get('claudeAiOauth',{}).get('refreshTokenExpiresAt') or 0))" \
        "$CRED_PATH" 2>/dev/null)
  ms=${ms:-0}
  [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] || return 0
  printf '%d|месячный вход\n' "$(( (ms / 1000 - now) / 86400 ))"
}

# classify_backup AGE_H DETAILS -> echoes "STATUS|DETAILS"
# AGE_H = whole hours since the newest backup archive, or -1 if none exist.
# Daily backup: OK if <26h, WARN 26-47h (a run was likely missed), FAIL >=48h or none.
classify_backup() {
  local age="$1" detail="$2"
  if [ "$age" -lt 0 ]; then
    printf 'FAIL|бэкап: нет архивов\n'
  elif [ "$age" -ge 48 ]; then
    printf 'FAIL|бэкап: %dч назад (>48ч)\n' "$age"
  elif [ "$age" -ge 26 ]; then
    printf 'WARN|бэкап: %dч назад\n' "$age"
  else
    printf 'OK|бэкап: %s\n' "$detail"
  fi
}

# --- Self-tests ---

run_tests() {
  local fails=0 total=0
  assert() {
    total=$((total + 1))
    local expect="$1" got="$2" name="$3"
    if [ "$expect" = "$got" ]; then
      printf '  OK  %s\n' "$name"
    else
      printf '  FAIL %s\n    expect: %s\n    got:    %s\n' "$name" "$expect" "$got"
      fails=$((fails + 1))
    fi
  }

  echo "== classify_pct =="
  assert "OK|disk 50%"   "$(classify_pct 50 80 90 disk)" "disk 50% -> OK"
  assert "WARN|disk 80%" "$(classify_pct 80 80 90 disk)" "disk 80% (boundary) -> WARN"
  assert "WARN|disk 85%" "$(classify_pct 85 80 90 disk)" "disk 85% -> WARN"
  assert "FAIL|disk 90%" "$(classify_pct 90 80 90 disk)" "disk 90% (boundary) -> FAIL"
  assert "FAIL|disk 95%" "$(classify_pct 95 80 90 disk)" "disk 95% -> FAIL"
  assert "OK|RAM 0%"     "$(classify_pct 0 80 90 RAM)"   "RAM 0% -> OK"

  echo "== classify_load =="
  assert "OK|load 0.50 / 2 cores"   "$(classify_load 0.5 2)" "load 0.5 of 2 -> OK"
  assert "WARN|load 1.40 / 2 cores" "$(classify_load 1.4 2)" "load 1.4 of 2 -> WARN"
  assert "FAIL|load 2.00 / 2 cores" "$(classify_load 2.0 2)" "load 2.0 of 2 -> FAIL"
  assert "FAIL|load 3.50 / 2 cores" "$(classify_load 3.5 2)" "load 3.5 of 2 -> FAIL"

  echo "== classify_service =="
  assert "OK|claude-gateway: active"      "$(classify_service claude-gateway active)"     "active -> OK"
  assert "WARN|claude-gateway: activating" "$(classify_service claude-gateway activating)" "activating -> WARN"
  assert "FAIL|claude-gateway: inactive"   "$(classify_service claude-gateway inactive)"   "inactive -> FAIL"
  assert "FAIL|claude-gateway: failed"     "$(classify_service claude-gateway failed)"     "failed -> FAIL"
  assert "FAIL|claude-gateway: unknown"    "$(classify_service claude-gateway unknown)"    "unknown -> FAIL"

  echo "== classify_credentials =="
  local tmp; tmp=$(mktemp)
  echo '{"token":"x"}' > "$tmp"
  local got_ok; got_ok=$(classify_credentials "$tmp")
  case "$got_ok" in OK\|*) printf '  OK  non-empty file -> OK\n' ;; *) printf '  FAIL non-empty file -> got: %s\n' "$got_ok"; fails=$((fails+1)) ;; esac
  total=$((total+1))
  : > "$tmp"
  assert "FAIL|$tmp empty"   "$(classify_credentials "$tmp")"          "empty file -> FAIL"
  rm -f "$tmp"
  assert "FAIL|входа нет: ни $tmp, ни годового токена в env" \
    "$(classify_credentials "$tmp")"                                    "missing file -> FAIL"
  local envf; envf=$(mktemp)
  echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-XXXX" > "$envf"
  assert "OK|годовой токен в $envf" "$(classify_credentials "$tmp" "$envf")" \
    "нет creds, но есть годовой токен -> OK"
  echo "BOT_TOKEN=123" > "$envf"
  assert "FAIL|входа нет: ни $tmp, ни годового токена в $envf" \
    "$(classify_credentials "$tmp" "$envf")" "нет ни creds, ни токена -> FAIL"
  rm -f "$envf"


  echo "== classify_auth_expiry =="
  assert "OK|годовой токен: ещё 200 дн"   "$(classify_auth_expiry 200 'годовой токен')" "200д -> OK"
  assert "WARN|годовой токен кончается через 20 дн" \
    "$(classify_auth_expiry 20 'годовой токен')" "20д -> WARN"
  assert "FAIL|годовой токен ИСТЁК -- агент замолчит" \
    "$(classify_auth_expiry 0 'годовой токен')" "0д -> FAIL"
  assert "OK|месячный вход: ещё 20 дн"    "$(classify_auth_expiry 20 'месячный вход')" "месячный 20д -> OK"
  assert "WARN|месячный вход кончается через 5 дн" \
    "$(classify_auth_expiry 5 'месячный вход')" "месячный 5д -> WARN"
  assert "FAIL|месячный вход ИСТЁК -- агент замолчит" \
    "$(classify_auth_expiry -3 'месячный вход')" "месячный -3д -> FAIL"

  echo "== auth_days_left =="
  local adir; adir=$(mktemp -d)
  (
    TOKEN_ENV="$adir/channel.env" CRED_PATH="$adir/creds.json" AUTH_STAMP="$adir/data/seen"
    now=$(date +%s)
    printf '{"claudeAiOauth":{"refreshTokenExpiresAt":%d}}' "$(( (now + 10*86400 + 3600) * 1000 ))" \
      > "$CRED_PATH"
    echo "BOT_TOKEN=1" > "$TOKEN_ENV"
    assert "10|месячный вход" "$(auth_days_left)" "нет токена -> срок из creds"
    echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-AAAA" > "$TOKEN_ENV"
    touch -d '@'"$(( now - 100*86400 ))" "$TOKEN_ENV"
    assert "265|годовой токен" "$(auth_days_left)" "токен главнее creds, год от даты env"
    touch "$TOKEN_ENV"
    assert "265|годовой токен" "$(auth_days_left)" "env переписан -- дата не молодеет"
    echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-BBBB" > "$TOKEN_ENV"
    assert "365|годовой токен" "$(auth_days_left)" "новый токен -- новый отсчёт"
    rm -f "$TOKEN_ENV" "$CRED_PATH"
    assert "" "$(auth_days_left)" "ни токена, ни creds -> пусто"
    exit "$fails"
  ) || fails=$(( $? ))
  total=$(( total + 5 ))
  rm -rf "$adir"

  echo "== classify_backup =="
  assert "FAIL|бэкап: нет архивов"        "$(classify_backup -1 '')"  "none -> FAIL"
  assert "OK|бэкап: arch (5 ч)"           "$(classify_backup 5 'arch (5 ч)')" "5h -> OK"
  assert "WARN|бэкап: 30ч назад"          "$(classify_backup 30 'x')" "30h -> WARN"
  assert "FAIL|бэкап: 50ч назад (>48ч)"   "$(classify_backup 50 'x')" "50h -> FAIL"

  echo ""
  echo "Tests: $((total - fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# --- Probes (live system) ---

probe_disk() {
  local pct
  pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  classify_pct "$pct" 80 90 "/"
}

probe_ram() {
  local total used pct
  read -r total used < <(free -m | awk '/^Mem:/ {print $2, $3}')
  if [ "$total" -eq 0 ]; then echo "FAIL|RAM unknown"; return; fi
  pct=$(( used * 100 / total ))
  classify_pct "$pct" 80 90 "RAM (${used}M / ${total}M)"
}

probe_cpu() {
  local load cores
  load=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc)
  classify_load "$load" "$cores"
}

probe_service() {
  local name="$1" state
  state=$(systemctl is-active "$name" 2>/dev/null || true)
  [ -z "$state" ] && state="unknown"
  classify_service "$name" "$state"
}

probe_secrets() {
  # Маска вместо секрета: канал режет длинные токены на выходе в чат, и агент,
  # взявший ключ из переписки, кладёт на диск «8ad1***0bd4». Файл есть, служба
  # поднялась, а каждый запрос отвечает 401 (живой агент 08.09.2026).
  local hits
  hits=$(grep -rlE '[A-Za-z0-9_]{4}\*{2,}[A-Za-z0-9_]{4}' \
           "$WORKSPACE/secrets" "$WORKSPACE/config" 2>/dev/null | head -3 | tr '\n' ' ')
  if [ -n "$hits" ]; then
    echo "FAIL|маска вместо ключа: ${hits% }"
  else
    echo "OK|секреты без масок"
  fi
}

probe_credentials() {
  classify_credentials "$CRED_PATH" "$TOKEN_ENV"
}

probe_auth_expiry() {
  local left; left=$(auth_days_left)
  [ -n "$left" ] || { echo "skip|срок входа не прочитать"; return; }
  classify_auth_expiry "${left%%|*}" "${left#*|}"
}

probe_cron() {
  # Канарейка: минутная крон-задача трогает файл. Протух — планировщик НЕ
  # выполняет задачи агента, какой бы ни была причина (27.08.2026: шесть часов
  # простоя из-за лишней жёсткой ссылки на файле расписания).
  if [ ! -f "$HEARTBEAT" ]; then
    echo "FAIL|крон: канарейка ни разу не отметилась"
    return
  fi
  local age_m
  age_m=$(( ( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ) / 60 ))
  if [ "$age_m" -le 5 ]; then echo "OK|крон: канарейка свежая (${age_m} мин)"
  elif [ "$age_m" -le 15 ]; then echo "WARN|крон: канарейка молчит ${age_m} мин"
  else echo "FAIL|крон НЕ ВЫПОЛНЯЕТ ЗАДАЧИ: канарейка молчит ${age_m} мин"; fi
}

probe_backup() {
  local latest age_s age_h
  latest=$(ls -1t "$BACKUP_DIR"/*.tar.gz* "$BACKUP_DIR"/*.tgz 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    # Бэкап — отдельная настройка хозяина (нужен свой вход в облако). Его
    # отсутствие не поломка агента, врать красным не будем.
    echo "WARN|бэкап не настроен ($BACKUP_DIR)"
    return
  fi
  age_s=$(( $(date +%s) - $(stat -c %Y "$latest") ))
  age_h=$(( age_s / 3600 ))
  classify_backup "$age_h" "$(basename "$latest") (${age_h}ч)"
}

# --- Renderer ---

# render_row "Проверка" "STATUS|Детали"
render_row() {
  local check="$1" payload="$2"
  local status="${payload%%|*}"
  local detail="${payload#*|}"
  local color reset
  if [ -t 1 ]; then
    case "$status" in
      OK)   color="\033[32m" ;;
      WARN) color="\033[33m" ;;
      FAIL) color="\033[31m" ;;
      *)    color="" ;;
    esac
    reset="\033[0m"
  else
    color=""; reset=""
  fi
  printf '| %-20s | %b%-4s%b | %s\n' "$check" "$color" "$status" "$reset" "$detail"
}

# Долговременная память. Не «порт открыт», а служба отвечает на /health: 19.09.2026
# у партнёрского агента памяти не было вовсе, а слив три дня писал «недоступен, skip»
# в лог, который никто не читал.
probe_memory() {
  curl -sf -m 5 "http://127.0.0.1:1933/health" >/dev/null 2>&1 \
    && { echo "ok|сервис памяти отвечает"; return; }
  [ -s "$HOME/.openviking/ov.conf" ] \
    && { echo "WARN|память настроена, но сервис на :1933 не отвечает"; return; }
  echo "ok|долгой памяти нет (не настраивали)"
}

# Считалка смыслов: без неё память принимает записи, но не индексирует.
probe_embed() {
  # Выключенная служба -- память переведена на ключ OpenAI, локальная не нужна.
  if systemctl is-enabled --quiet dashi-embed 2>/dev/null; then
    systemctl is-active --quiet dashi-embed \
      && echo "ok|считалка смыслов работает" || echo "WARN|служба эмбеддингов лежит"
  else
    echo "ok|локальной считалки нет (или память на ключе)"
  fi
}

# Рост файлов. Транскрипт сессии = то, из чего Stop-хук достаёт ответ хозяину:
# на разросшемся файле ответ не успевает записаться и пропадает (19.09.2026, 30 МБ).
probe_sizes() {
  local big proj logs data out=""
  proj=$(du -sm "$HOME/.claude/projects" 2>/dev/null | cut -f1); proj=${proj:-0}
  big=$(find "$HOME/.claude/projects" -name '*.jsonl' -printf '%s\n' 2>/dev/null | sort -rn | head -1)
  big=$(( ${big:-0} / 1048576 ))
  logs=$(du -sm "$WORKSPACE/logs" 2>/dev/null | cut -f1); logs=${logs:-0}
  data=$(du -sm "$WORKSPACE/data" 2>/dev/null | cut -f1); data=${data:-0}
  out="переписка ${proj}М (крупнейшая сессия ${big}М), логи ${logs}М, данные ${data}М"
  if [ "$big" -ge 20 ]; then echo "WARN|$out -- сессию пора начать заново, ответы начнут теряться"; return; fi
  if [ "$logs" -ge 500 ] || [ "$data" -ge 2000 ]; then echo "WARN|$out -- нужна ротация"; return; fi
  echo "ok|$out"
}

probe_dead_letter() {
  # Quarantines with no reader are /dev/null with extra steps: 82 parked inbound
  # updates sat unseen for three months (19.09.2026). Surface them here.
  local digest out fresh total
  digest="$WORKSPACE/bin/dead-letter-digest.py"
  [ -x "$digest" ] || { echo "skip|разборщика карантина нет"; return; }
  out=$(/usr/bin/python3 "$digest" --workspace "$WORKSPACE" --quiet --json 2>/dev/null) || {
    echo "WARN|разборщик карантина упал"; return; }
  total=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(r["total"] for r in d))' 2>/dev/null)
  fresh=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(r["fresh"] for r in d))' 2>/dev/null)
  total=${total:-0}; fresh=${fresh:-0}
  if [ "$fresh" -gt 0 ]; then
    echo "WARN|в карантине $total записей, свежих $fresh -- разобрать: bin/dead-letter-digest.py --json"
    return
  fi
  echo "ok|в карантине $total записей, свежих нет"
}

main() {
  declare -A results

  results[Disk]=$(probe_disk)
  results[RAM]=$(probe_ram)
  results[CPU_load]=$(probe_cpu)
  results[Agent]=$(probe_service "dashi-$AGENT")
  results[OAuth]=$(probe_credentials)
  results[Auth_expiry]=$(probe_auth_expiry)
  results[Cron]=$(probe_cron)
  results[Backup]=$(probe_backup)
  results[Secrets]=$(probe_secrets)
  results[Memory]=$(probe_memory)
  results[Embeddings]=$(probe_embed)
  results[Sizes]=$(probe_sizes)
  results[Dead_letter]=$(probe_dead_letter)

  local sep="+----------------------+------+-----------------------------------------"
  echo "$sep"
  printf '| %-20s | %-4s | %s\n' "Проверка" "Стат" "Детали"
  echo "$sep"
  render_row "Диск /"          "${results[Disk]}"
  render_row "RAM"             "${results[RAM]}"
  render_row "CPU load (1m)"   "${results[CPU_load]}"
  render_row "Агент"           "${results[Agent]}"
  render_row "OAuth creds"     "${results[OAuth]}"
  render_row "Срок входа"      "${results[Auth_expiry]}"
  render_row "Планировщик"     "${results[Cron]}"
  render_row "Бэкап"           "${results[Backup]}"
  render_row "Секреты"         "${results[Secrets]}"
  # 19.09.2026: эти четыре считались, но в таблицу не попадали -- вердикт
  # портился, а какой пункт просел, видно не было.
  render_row "Долгая память"   "${results[Memory]}"
  render_row "Эмбеддинги"      "${results[Embeddings]}"
  render_row "Размеры"         "${results[Sizes]}"
  render_row "Карантин"        "${results[Dead_letter]}"
  echo "$sep"

  local worst=0
  for key in "${!results[@]}"; do
    local s="${results[$key]%%|*}"
    case "$s" in
      WARN) [ "$worst" -lt 1 ] && worst=1 ;;
      FAIL) worst=2 ;;
    esac
  done
  echo ""
  case "$worst" in
    0) echo "Verdict: OK" ;;
    1) echo "Verdict: WARN" ;;
    2) echo "Verdict: FAIL" ;;
  esac
  exit "$worst"
}

if [ "${HEALTH_TEST:-0}" = "1" ]; then
  run_tests
  exit $?
fi

main "$@"
