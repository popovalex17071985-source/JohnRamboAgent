#!/usr/bin/env bash
# install-agent.sh — разворачивает dashi-агента на чистом сервере одной командой.
#
# Заменяет 14 ручных шагов из artifacts/dashi-agent-guide-v2.md. Скрипт
# идемпотентный: гоняй сколько угодно раз, он доделывает недостающее и не
# трогает готовое. Прерваться на входе в Claude — нормально, запусти снова.
#
# Что человек делает сам (автоматизировать нельзя):
#   1. арендует VPS и заходит на него root'ом
#   2. заводит бота у @BotFather и узнаёт свой id у @userinfobot
#   3. проходит вход в Claude по ссылке (OAuth) — скрипт сам запускает
#      `claude setup-token` и забирает ГОДОВОЙ токен (никаких перелогинов раз в месяц)
#
# Использование:
#   bash install-agent.sh                      # спросит всё интерактивно
#   bash install-agent.sh --name jarvis --token 123:AA... --user-id 140141496
#   ... --openai-key sk-...                  # запасной путь памяти, если локальная модель не влезла
#   ... --branch feature/x                   # staging-агент: обновляется с feature-ветки, не с main
#   ... --model opus                         # модель Claude для агента (opus|sonnet|haiku|полный id); без флага — дефолт аккаунта
#   ... --claude-token sk-ant-oat01-...      # готовый годовой токен (claude setup-token на любой машине)
#   ... --repair-token 123:BB...             # бот-ремонтник: страховка на случай «агент лёг и молчит»
#   ... --no-browser                         # без Playwright/Chromium (по умолчанию браузер ставится)
#   ... --groq-key gsk_...                   # голосовые сообщения через Groq (Whisper)
#   ... --tz Asia/Yekaterinburg              # пояс ХОЗЯИНА: утренняя сводка в 09:00 по нему (по умолчанию пояс сервера)
#   ... --user agent                         # системный пользователь агента (по умолчанию agent)
#   ... --webhook-port 8089                  # порт приёмника хуков; второму агенту на хосте — свой (+ свой --user)
#   ... --repo URL                           # откуда клонировать плагин (по умолчанию GitHub)
#   ... --yes                                # без вопросов (cloud-init, CI): необязательное пропускается
#
set -euo pipefail

NODE_MAJOR=22
# Версии зашиты, чтобы «поставил вчера — работает, поставил сегодня — нет» не
# случалось. Bun: та, что живёт у Jarvis (bun --version); OpenViking: digest
# образа, который крутится у Jarvis (docker images --digests). nodesource и uv
# НЕ запинены сознательно: nodesource сам держит мажор 22.x, а uv нужен только
# ремонтнику как установщик Python — их поломки нам пока не встречались.
BUN_VERSION="bun-v1.4.0"
OPENVIKING_IMAGE="ghcr.io/volcengine/openviking@sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701"
REPO_URL="${DASHI_REPO_URL:-https://github.com/popovalex17071985-source/JohnRamboAgent.git}"
# Ветка, с которой агент обновляется (/update, советник, повторный прогон).
# main = проверенное, раскатывается всем после обсуждения; staging-агенты
# (Smith) сидят на feature-ветке и видят изменения первыми.
# Пусто = решаем ниже: --branch/DASHI_BRANCH → ветка из уже существующего
# channel.env → main. Раньше повторный прогон без --branch молча пересаживал
# staging-агента на main и стирал его локальные правки.
BRANCH="${DASHI_BRANCH:-}"
SERVICE_USER="${DASHI_SERVICE_USER:-agent}"
# Порт приёмника событий от Claude (хуки → плагин). Второй агент на том же
# хосте обязан получить свой порт, иначе оба стучатся в 8089.
WEBHOOK_PORT="${DASHI_WEBHOOK_PORT:-8089}"
USER_GIVEN=0; PORT_GIVEN=0
[[ -n "${DASHI_SERVICE_USER:-}" ]] && USER_GIVEN=1
[[ -n "${DASHI_WEBHOOK_PORT:-}" ]] && PORT_GIVEN=1

AGENT_NAME=""; BOT_TOKEN=""; USER_ID=""; GROQ_KEY=""; OPENAI_KEY=""; CLAUDE_TOKEN=""; REPAIR_TOKEN=""; ASSUME_YES=0
MODEL="${DASHI_MODEL:-}"
OWNER_TZ="${DASHI_OWNER_TZ:-}"
SKIP_BROWSER=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m· %s (уже сделано)\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }
# 11.09.2026: «предупредил и пошёл дальше» = тихая дыра. Ключ Google так и
# просочился: установка считалась успешной, а бэкап падал по квоте четыре дня.
# gap() = то же предупреждение, но пункт попадает в итоговый список недоделок.
GAPS=()
gap()  { warn "$1"; GAPS+=("$1${2:+ | доделать: $2}"); }
# Есть ли настоящий терминал. `-r /dev/tty` врёт: файл читаем всегда, а открыть
# его без управляющего терминала (docker exec, CI, cloud-init) нельзя.
have_tty() { { : </dev/tty; } 2>/dev/null; }

usage() {
  # Шапка файла до set -euo — целиком, чтобы новый флаг не выпадал из справки
  awk 'NR >= 2 && /^set -euo pipefail/ { exit } NR >= 2 { print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      AGENT_NAME="$2"; shift 2 ;;
    --token)     BOT_TOKEN="$2";  shift 2 ;;
    --user-id)   USER_ID="$2";    shift 2 ;;
    --groq-key)  GROQ_KEY="$2";   shift 2 ;;
    --openai-key) OPENAI_KEY="$2"; shift 2 ;;   # включает семантическую память OpenViking
    --claude-token) CLAUDE_TOKEN="$2"; shift 2 ;; # годовой токен из `claude setup-token`
    --repair-token) REPAIR_TOKEN="$2"; shift 2 ;; # бот-ремонтник (страховка, ещё один /newbot)
    --user)      SERVICE_USER="$2"; USER_GIVEN=1; shift 2 ;;
    --webhook-port) WEBHOOK_PORT="$2"; PORT_GIVEN=1; shift 2 ;;   # порт приёмника хуков (по умолчанию 8089)
    --repo)      REPO_URL="$2";   shift 2 ;;
    --branch)    BRANCH="$2";     shift 2 ;;   # main (по умолчанию) | feature-ветка для staging
    --tz)        OWNER_TZ="$2";   shift 2 ;;   # пояс ХОЗЯИНА: сводка приходит в 09:00 по нему
    --model)     MODEL="$2";      shift 2 ;;   # opus|sonnet|haiku|полный id; пусто = дефолт аккаунта
    --no-browser) SKIP_BROWSER=1; shift ;;   # не ставить Playwright/Chromium (экономия ~400 МБ)
    --yes|-y)    ASSUME_YES=1;    shift ;;
    --help|-h)   usage ;;
    *) die "неизвестный аргумент: $1 (--help для справки)" ;;
  esac
done

# Токен можно передать и через окружение — не светится в ps, в отличие от флага:
#   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-... sudo -E bash install-agent.sh ...
CLAUDE_TOKEN="${CLAUDE_TOKEN:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0"

# ─────────────────────────────────────────────────────────────────────────────
# 0. Что за агент
# ─────────────────────────────────────────────────────────────────────────────
ask() {  # ask VAR "приглашение" [обязательность]
  local __var="$1" __prompt="$2" __required="${3:-1}" __val=""
  while :; do
    # Без терминала (docker exec, CI, вложенный su) read падает мгновенно —
    # со старым `|| true` цикл крутился вечно, жрал CPU и МОЛЧАЛ. Теперь
    # установка честно останавливается с понятной причиной. (e2e 27.08.)
    if ! have_tty || ! read -r -p "$__prompt" __val </dev/tty; then
      [[ "$__required" -eq 0 ]] && break
      die "нужен ответ на «$__prompt», но терминала нет — запусти установщик интерактивно или передай значение флагом"
    fi
    [[ -n "$__val" || "$__required" -eq 0 ]] && break
    echo "    поле обязательное"
  done
  printf -v "$__var" '%s' "$__val"
}

# Город хозяина -> код часового пояса. Спрашивать у человека IANA-код
# бессмысленно: он знает свой город, а не «Asia/Yekaterinburg». Незнакомое
# значение возвращаем как есть — ниже оно проверяется по /usr/share/zoneinfo.
tz_from_city() {
  case "$1" in
    [Мм]осква|[Мм]оскве|[Пп]итер|[Сс]анкт*|[Кк]азань|[Сс]очи|[Рр]остов*|[Вв]оронеж|[Нн]ижний*|moscow|Moscow|MSK|msk|spb) echo Europe/Moscow ;;
    [Кк]алининград*)                                       echo Europe/Kaliningrad ;;
    [Сс]амара|[Сс]амаре|[Ии]жевск|[Сс]аратов)              echo Europe/Samara ;;
    [Пп]ермь|[Пп]ерми|[Ее]катеринбург*|[Ее]кб|[Уу]фа|[Чч]елябинск|[Тт]юмень|perm|Perm|ekb|EKB) echo Asia/Yekaterinburg ;;
    [Оо]мск|[Оо]мске)                                      echo Asia/Omsk ;;
    [Нн]овосибирск*|[Нн]овосиб|[Бб]арнаул|[Тт]омск|[Кк]емерово) echo Asia/Novosibirsk ;;
    [Кк]расноярск*|[Аа]бакан)                              echo Asia/Krasnoyarsk ;;
    [Ии]ркутск*|[Уу]лан-[Уу]дэ)                            echo Asia/Irkutsk ;;
    [Яя]кутск*|[Чч]ита)                                    echo Asia/Yakutsk ;;
    [Вв]ладивосток*|[Хх]абаровск)                          echo Asia/Vladivostok ;;
    *) echo "$1" ;;
  esac
}

say "Кого разворачиваем"
[[ -n "$AGENT_NAME" ]] || ask AGENT_NAME "Имя агента (латиницей, напр. jarvis): "
[[ "$AGENT_NAME" =~ ^[a-z][a-z0-9_-]*$ ]] || die "имя только латиницей в нижнем регистре: $AGENT_NAME"

WORKSPACE="/home/$SERVICE_USER/.claude-lab/$AGENT_NAME"
CLAUDE_DIR="$WORKSPACE/.claude"
PLUGIN_DIR="$CLAUDE_DIR/dashi-plugin-claude-code/plugin"
ENV_FILE="/etc/dashi-plugin/$AGENT_NAME/channel.env"
UNIT="dashi-$AGENT_NAME"

# Ветка обновлений: флаг → то, на чём агент уже сидит → main
if [[ -n "$BRANCH" ]]; then
  BRANCH_SRC="флаг --branch / DASHI_BRANCH"
elif [[ -f "$ENV_FILE" ]] && BRANCH="$(sed -n 's/^DASHI_BRANCH=//p' "$ENV_FILE" | head -1)" && [[ -n "$BRANCH" ]]; then
  BRANCH_SRC="из $ENV_FILE"
else
  BRANCH="main"; BRANCH_SRC="по умолчанию"
fi
ok "ветка обновлений: $BRANCH ($BRANCH_SRC)"

# Второй агент на том же хосте: ему нужны СВОЙ пользователь (иначе хуки обоих
# пишутся в один ~/.claude/settings.json) и СВОЙ порт вебхука (иначе оба
# стучатся в 8089). Без обоих флагов честно останавливаемся.
# `|| true` обязателен: на чистом сервере /etc/dashi-plugin нет, ls падает, и
# set -e с pipefail молча ронял установку прямо здесь (e2e 02.09).
OTHER_AGENTS="$(ls -1 /etc/dashi-plugin 2>/dev/null | grep -vx "$AGENT_NAME" | tr '\n' ' ' || true)"
if [[ -f "$ENV_FILE" ]]; then
  # Повторный прогон: порт и пользователь — те, что у агента уже есть
  [[ $PORT_GIVEN -eq 1 ]] || WEBHOOK_PORT="$(sed -n 's/^TELEGRAM_WEBHOOK_PORT=//p' "$ENV_FILE" | head -1)"
  WEBHOOK_PORT="${WEBHOOK_PORT:-8089}"
  ws_root="$(sed -n 's/^TELEGRAM_WORKSPACE_ROOT=//p' "$ENV_FILE" | head -1)"
  [[ -z "$ws_root" || "$ws_root" == "/home/$SERVICE_USER/"* ]] \
    || die "агент $AGENT_NAME живёт в $ws_root, а не под пользователем $SERVICE_USER — передай --user <его пользователь>"
elif [[ -n "$OTHER_AGENTS" && ( $USER_GIVEN -eq 0 || $PORT_GIVEN -eq 0 ) ]]; then
  die "на этом сервере уже есть агент: $OTHER_AGENTS— второму нужны свой пользователь и свой порт вебхука, передай ОБА флага: --user <имя> --webhook-port <порт, не 8089>"
fi
[[ "$WEBHOOK_PORT" =~ ^[0-9]{2,5}$ ]] || die "порт вебхука должен быть числом: $WEBHOOK_PORT"
ok "порт вебхука: $WEBHOOK_PORT"

# Пояс хозяина: флаг --tz → то, что уже записано в channel.env → пояс сервера.
# Помним его в конфиге, иначе повторный прогон и /update без --tz молча
# сдвинули бы утреннюю сводку на час сервера.
SERVER_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
if [[ -z "$OWNER_TZ" && -f "$ENV_FILE" ]]; then
  OWNER_TZ="$(sed -n 's/^DASHI_OWNER_TZ=//p' "$ENV_FILE" | head -1)"
fi
# Первая установка без --tz: СПРАШИВАЕМ. Сервер почти всегда в UTC или MSK, а
# хозяин живёт в другом поясе — молчаливый дефолт уводил утреннюю сводку и все
# расписания на часы, и человек об этом узнавал через неделю.
if [[ -z "$OWNER_TZ" && $ASSUME_YES -eq 0 ]] && have_tty; then
  cat <<EOF

  ЧАСОВОЙ ПОЯС ХОЗЯИНА. По нему агент считает всё время: утренняя сводка в
  09:00, ночные задачи, любое «во сколько». Сейчас на сервере $SERVER_TZ
  ($(TZ="$SERVER_TZ" date '+%H:%M')).

  Введи свой ГОРОД (или сразу код пояса):
    Москва, Питер, Казань, Сочи                  -> Europe/Moscow
    Пермь, Екатеринбург, Уфа, Челябинск, Тюмень  -> Asia/Yekaterinburg
    Самара, Ижевск -> Europe/Samara    Калининград -> Europe/Kaliningrad
    Омск -> Asia/Omsk                  Новосибирск, Томск -> Asia/Novosibirsk
    Красноярск -> Asia/Krasnoyarsk     Иркутск -> Asia/Irkutsk
    Якутск -> Asia/Yakutsk             Владивосток, Хабаровск -> Asia/Vladivostok

EOF
  while :; do
    ask __tz_in "Твой город или пояс [Enter -- как на сервере, $SERVER_TZ]: " 0
    if [[ -z "$__tz_in" ]]; then OWNER_TZ="$SERVER_TZ"; break; fi
    __tz_try="$(tz_from_city "$__tz_in")"
    if [[ ! -d /usr/share/zoneinfo || -f "/usr/share/zoneinfo/$__tz_try" ]]; then
      OWNER_TZ="$__tz_try"
      echo "    -> $OWNER_TZ, сейчас там $(TZ="$OWNER_TZ" date '+%H:%M')"
      break
    fi
    echo "    не знаю такого места: $__tz_in — введи город из списка выше или код вида Asia/Yekaterinburg"
  done
fi
OWNER_TZ="${OWNER_TZ:-$SERVER_TZ}"
OWNER_TZ="$(tz_from_city "$OWNER_TZ")"
# Проверяем по справочнику tzdata, но ТОЛЬКО если он на машине есть: на голой
# ubuntu:22.04 его ещё нет (ставится ниже вместе с системой), и жёсткая
# проверка роняла установку на первом же шаге — e2e поймал 02.09.
if [[ -d /usr/share/zoneinfo ]] && [[ ! -f "/usr/share/zoneinfo/$OWNER_TZ" ]]; then
  die "неизвестный часовой пояс: $OWNER_TZ (пример правильного: Asia/Yekaterinburg)"
fi
ok "пояс хозяина: $OWNER_TZ (сейчас там $(TZ="$OWNER_TZ" date '+%H:%M'), утренняя сводка в 09:00 по нему)"

# Часы САМОГО сервера тоже переводим на пояс хозяина — но только на ПЕРВОЙ
# установке и только когда агент на хосте один. Иначе агент читает `date`,
# логи и метки файлов в чужом поясе и называет хозяину время на 2-5 часов
# мимо: у Jarvis этот класс ошибок живёт с четырьмя напоминалками и всё равно
# повторяется (Саня 02.09). У нового агента расписаний ещё нет — переставлять
# нечего, поэтому здесь это бесплатно; на повторном прогоне НЕ трогаем, чтобы
# не сдвинуть уже стоящие задачи.
if [[ ! -f "$ENV_FILE" && -z "$OTHER_AGENTS" && "$SERVER_TZ" != "$OWNER_TZ" ]]; then
  if timedatectl set-timezone "$OWNER_TZ" 2>/dev/null; then
    SERVER_TZ="$OWNER_TZ"
    ok "часы сервера переведены на $OWNER_TZ — время в логах и у агента совпадает с твоим"
  else
    warn "не смог перевести часы сервера на $OWNER_TZ — агент будет видеть время сервера ($SERVER_TZ)"
  fi
elif [[ -f "$ENV_FILE" && "$SERVER_TZ" != "$OWNER_TZ" ]]; then
  warn "часы сервера ($SERVER_TZ) не совпадают с твоим поясом ($OWNER_TZ) — расписания пересчитываются, но время в логах серверное; смена часов сдвинет уже стоящие задачи, поэтому руками: timedatectl set-timezone $OWNER_TZ"
fi

# Токен и id спрашиваем, только если конфига ещё нет — на повторном прогоне не дёргаем.
if [[ ! -f "$ENV_FILE" ]]; then
  [[ -n "$BOT_TOKEN" ]] || ask BOT_TOKEN "Токен бота от @BotFather: "
  [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен не похож на настоящий (ожидаю 123456:AA...)"
  [[ -n "$USER_ID" ]] || ask USER_ID "Твой Telegram id от @userinfobot: "
  [[ "$USER_ID" =~ ^-?[0-9]+$ ]] || die "id должен быть числом: $USER_ID"
  # При -y необязательные ключи не спрашиваем: в неинтерактивном прогоне
  # (cloud-init, CI) /dev/tty нет, и ask() сыпал ошибками в лог
  if [[ $ASSUME_YES -eq 0 ]]; then
    [[ -n "$GROQ_KEY" ]] || ask GROQ_KEY "Ключ Groq для голосовых (Enter — пропустить): " 0
    # Память ставится и БЕЗ этого ключа (локальные эмбеддинги). Прежний текст
    # «Enter -- без неё» пугал хозяина в обратную сторону: он думал, что без
    # ключа агент останется без долгой памяти, и шёл покупать ключ зря.
    # Но и молчать о разнице нельзя: замер 26.09.2026 на 200 живых записях памяти
    # и 19 вопросах -- локальная MiniLM нашла нужное первой в 10 случаях из 19,
    # text-embedding-3-small по ключу -- в 17 (в тройке -- 19 из 19). И ключ не
    # ест оперативку (локальная -- ~0.7 ГБ).
    [[ -n "$OPENAI_KEY" ]] || ask OPENAI_KEY "Ключ OpenAI для памяти -- СОВЕТУЮ: с ним агент вспоминает заметно точнее и не тратит ~0.7 ГБ оперативки, стоит центы в месяц. Без ключа память тоже встанет (Enter — пропустить): " 0
  fi
else
  # Повторный прогон: id нужен ниже для хуков, берём из готового конфига,
  # иначе хуки встанут с пустым chat-id и прогресс-пузырёк уедет в никуда.
  USER_ID="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1)"
  [[ -n "$USER_ID" ]] || die "в $ENV_FILE нет TELEGRAM_ALLOWED_USER_IDS — почини файл или удали его и запусти снова"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  cat <<EOF

  агент:        $AGENT_NAME
  пользователь: $SERVICE_USER
  workspace:    $WORKSPACE
  сервис:       $UNIT

EOF
  read -r -p "Поехали? [Y/n] " a </dev/tty || true
  [[ -z "${a:-}" || "$a" =~ ^[YyДд] ]] || die "отменено"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Система: Node.js, Claude Code, tmux
# ─────────────────────────────────────────────────────────────────────────────
say "Система и Claude Code"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# curl ставим ПЕРВЫМ — он нужен уже для nodesource-скрипта ниже; на голой
# машине без curl прогон падал bit «command not found» до установки Node.
apt-get install -y -qq curl ca-certificates

if ! command -v node >/dev/null || [[ "$(node -v | cut -c2- | cut -d. -f1)" -lt "$NODE_MAJOR" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs
  ok "Node.js $(node -v)"
else
  skip "Node.js $(node -v)"
fi
# unzip нужен установщику Bun — без него тот падает уже после скачивания;
# tmux держит интерактивную сессию Claude под systemd
apt-get install -y -qq git unzip tmux curl jq python3

# На 1 ГБ памяти сборка и Claude Code упираются в потолок и падают молча.
# Ставим своп — дешевле, чем объяснять человеку OOM.
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
if (( mem_kb < 1800000 )) && ! swapon --show --noheadings | grep -q .; then
  make_swap() {  # make_swap fallocate|dd — файл, права, mkswap, swapon; любой сбой = false
    rm -f /swapfile
    if [[ "$1" == fallocate ]]; then fallocate -l 2G /swapfile 2>/dev/null
    else dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null; fi \
      && chmod 600 /swapfile && mkswap -q /swapfile 2>/dev/null && swapon /swapfile 2>/dev/null
  }
  # На btrfs/zfs fallocate проходит, а swapon отказывает («дырявый» файл) —
  # раньше set -e ронял всю установку; пробуем dd, не вышло — идём без свопа.
  if make_swap fallocate || make_swap dd; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "своп 2 ГБ (памяти всего $(( mem_kb / 1024 )) МБ)"
  else
    rm -f /swapfile
    warn "своп не поднялся (btrfs/zfs/контейнер?) — продолжаю без него; памяти $(( mem_kb / 1024 )) МБ, Claude может падать по OOM"
  fi
fi

# Журнал systemd без потолка за месяцы съедает гигабайты на маленьком VPS
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\n' > /etc/systemd/journald.conf.d/dashi.conf
systemctl try-restart systemd-journald 2>/dev/null || true

if ! command -v claude >/dev/null; then
  npm install -g @anthropic-ai/claude-code >/dev/null
  ok "Claude Code $(claude --version 2>/dev/null || echo установлен)"
else
  skip "Claude Code $(claude --version 2>/dev/null || true)"
fi

# Google Workspace CLI: через него агент работает с Таблицами, Документами,
# Почтой и Календарём. Ставим сразу — доставлять npm-пакет на живой сервер
# потом дороже. Вход владельца настраивается отдельно (gws auth setup/login),
# без него команда просто лежит и не мешает.
if ! command -v gws >/dev/null 2>&1; then
  if npm install -g @googleworkspace/cli >/dev/null 2>&1; then
    ok "Google-инструмент (таблицы, документы, почта) поставлен — вход настраивается отдельно"
  else
    warn "не поставился @googleworkspace/cli — Google-таблицы будут недоступны, поставь позже"
  fi
else
  skip "Google-инструмент уже стоит"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Отдельный пользователь
# ─────────────────────────────────────────────────────────────────────────────
# Под root Claude отказывается работать без подтверждений (--dangerously-skip-
# permissions «cannot be used with root»), а systemd на этом молча зацикливается.
# Поэтому агент живёт под обычным пользователем с самого начала.
say "Пользователь $SERVICE_USER"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  skip "пользователь $SERVICE_USER"
else
  adduser --disabled-password --gecos "" "$SERVICE_USER" >/dev/null
  ok "создан $SERVICE_USER"
fi
HOME_DIR="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
# Читать журнал своего сервиса без sudo (советник, самодиагностика)
usermod -aG systemd-journal "$SERVICE_USER" 2>/dev/null || true

as_agent() { su - "$SERVICE_USER" -c "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 3. Bun
# ─────────────────────────────────────────────────────────────────────────────
say "Bun"
if as_agent 'test -x ~/.bun/bin/bun'; then
  skip "bun $(as_agent '~/.bun/bin/bun --version')"
else
  as_agent "curl -fsSL https://bun.sh/install | bash -s -- '$BUN_VERSION'" >/dev/null
  as_agent 'test -x ~/.bun/bin/bun' || die "bun не встал — проверь, что unzip на месте"
  ok "bun $(as_agent '~/.bun/bin/bun --version')"
fi
# Симлинк в /usr/local/bin: скрипты плагина зовут `bun` по имени, а в
# неинтерактивном su его PATH не видит.
# ln -sf всегда: старый симлинк мог остаться от другого юзера/агента и висеть
ln -sf "/home/$SERVICE_USER/.bun/bin/bun" /usr/local/bin/bun
ok "bun доступен как команда системы"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Workspace и плагин
# ─────────────────────────────────────────────────────────────────────────────
# Плагин обязан лежать ВНУТРИ .claude workspace'а: Claude Code ищет CLAUDE.md
# вверх по дереву от рабочей папки, а MCP-сервер — относительным путём. Отсюда
# «no MCP server configured with that name» у всех, кто положил его рядом.
say "Workspace $WORKSPACE"
as_agent "mkdir -p '$CLAUDE_DIR' '$WORKSPACE/secrets' && chmod 700 '$WORKSPACE/secrets'"
# Самолечение владельца: любая root-починка руками (tmux под root, root-скрипты)
# красит файлы агента в root, и он молча теряет право писать в собственные
# папки (20-21.08: киоск, потом secrets/ — «не могу сохранить токен»). Установщик
# идёт под root, поэтому каждый прогон возвращает всё хозяйство юзеру.
if [[ -d "/home/$SERVICE_USER" ]]; then
  chown -R "$SERVICE_USER:$SERVICE_USER" "/home/$SERVICE_USER"
  ok "владелец домашней папки нормализован ($SERVICE_USER)"
fi

if [[ -d "$CLAUDE_DIR/dashi-plugin-claude-code/.git" ]]; then
  # Повторный прогон = обновление плагина, иначе фиксы моста не доезжают.
  # set-url обязателен: старые установки смотрят origin'ом в чужое репо.
  # reset --hard стирает правки в отслеживаемых файлах — как dashi-ctl update,
  # при локальных правках не трогаем (untracked reset не задевает, их не считаем).
  REPO_DIRTY="$(as_agent "git -C '$CLAUDE_DIR/dashi-plugin-claude-code' status --porcelain --untracked-files=no" 2>/dev/null \
    | awk '{print $NF}' | head -5 | tr '\n' ' ' || true)"
  if [[ -n "$REPO_DIRTY" ]]; then
    warn "в плагине есть локальные правки ($REPO_DIRTY) — обновление до $BRANCH пропускаю, чтобы их не стереть"
    warn "закоммить или откати их (git -C $CLAUDE_DIR/dashi-plugin-claude-code status) и запусти снова"
  else
    as_agent "cd '$CLAUDE_DIR/dashi-plugin-claude-code' && git remote set-url origin '$REPO_URL' && git fetch --depth 1 origin '$BRANCH' && git reset --hard FETCH_HEAD" >/dev/null 2>&1 \
      && ok "плагин обновлён до свежего $BRANCH" \
      || warn "не смог обновить плагин (нет сети до GitHub?) — работаю на том, что есть"
  fi
else
  as_agent "git clone --depth 1 --branch '$BRANCH' '$REPO_URL' '$CLAUDE_DIR/dashi-plugin-claude-code'" >/dev/null 2>&1 \
    || die "не удалось склонировать $REPO_URL"
  ok "плагин склонирован"
fi

say "Зависимости плагина"
as_agent "cd '$PLUGIN_DIR' && ~/.bun/bin/bun install --silent" >/dev/null 2>&1 || die "bun install упал"
ok "зависимости на месте"

# ─────────────────────────────────────────────────────────────────────────────
# 4b. Браузер (Playwright) — агенту регулярно нужно ходить в веб-кабинеты,
# где нет API. Ставим сразу: доставлять потом руками — это отдельный вечер.
# ─────────────────────────────────────────────────────────────────────────────
say "Браузер (Playwright)"
if [[ $SKIP_BROWSER -eq 1 ]]; then
  skip "браузер пропущен по флагу --no-browser"
elif as_agent 'test -d ~/.cache/ms-playwright/chromium-*' 2>/dev/null; then
  skip "Chromium уже стоит"
else
  as_agent "cd '$WORKSPACE' && test -f package.json || npm init -y >/dev/null 2>&1" || true
  if as_agent "cd '$WORKSPACE' && npm install --silent --no-audit --no-fund playwright" >/dev/null 2>&1; then
    # Системные библиотеки Chromium ставит root, сам браузер — уже агент,
    # иначе кэш уляжется в /root и агент его не увидит.
    as_agent "cd '$WORKSPACE' && npx playwright install-deps chromium" >/dev/null 2>&1 \
      || npx --yes playwright install-deps chromium >/dev/null 2>&1 || true
    # качаем до трёх раз: срыв закачки на слабом канале -- обычное дело,
    # а без браузера агент молча теряет все веб-кабинеты
    _chromium_ok=0
    for _try in 1 2 3; do
      if as_agent "cd '$WORKSPACE' && npx playwright install chromium" >/dev/null 2>&1; then
        _chromium_ok=1; break
      fi
      sleep 5
    done
    if [[ $_chromium_ok -eq 1 ]]; then
      ok "Chromium готов — агент умеет ходить в веб-кабинеты"
    else
      gap "Chromium не скачался с трёх попыток — веб-кабинеты (Авито, InSales, amo) агенту недоступны" \
          "su - $SERVICE_USER -c 'cd $WORKSPACE && npx playwright install chromium'"
    fi
  else
    gap "playwright не встал (npm) — веб-кабинеты будут недоступны" \
        "su - $SERVICE_USER -c 'cd $WORKSPACE && npm i -D playwright && npx playwright install chromium'"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Характер агента
# ─────────────────────────────────────────────────────────────────────────────
say "Характер (CLAUDE.md)"
if [[ -s "$CLAUDE_DIR/CLAUDE.md" ]]; then
  skip "CLAUDE.md уже написан"
else
  as_agent "cat > '$CLAUDE_DIR/CLAUDE.md'" <<EOF
# $AGENT_NAME

## Who I am
Personal assistant. I answer in the owner's language, short, point first, no
filler and no apologies.

## What I read, and when
| Layer | Where | When |
|---|---|---|
| Owner profile | core/USER.md | always (included below) |
| Rules and corrections | core/rules.md | always (included below) |
| Session handoff | core/hot/handoff.md | coming back to an old topic |
| Decisions (~14 days) | core/warm/decisions.md | coming back to an old topic |
| Facts | memory/MEMORY.md + files | index at start, a fact when needed |
| Verbatim chat log | logs/verbose-YYYY-MM-DD.jsonl | asked "what did I tell you earlier" |
| Lessons | core/LEARNINGS.md | after a mistake |

Rules: a fact learned or a correction received goes into a file and the index
immediately — not held in my head until the session ends. An owner's correction
goes into rules.md. Memory against reality — reality wins.

Asked about something earlier in the chat, I do NOT answer "I have no history":
first I search logs/verbose-*.jsonl (the verbatim turn log, it survives a
restart) and core/hot/recent.md. Telegram gives a bot no history — that log does.

Only two light files stay in context, everything else is read on demand:
otherwise every start burns context on what today does not need.

## Self-service (my rights on this server)

My bridge is the service "$UNIT", tmux session "channel-$AGENT_NAME". I do NOT
send the owner into a terminal: everything routine I can do myself. Through sudo
exactly one tool is allowed — dashi-ctl-$AGENT_NAME:
- sudo /usr/local/bin/dashi-ctl-$AGENT_NAME restart — restart my service.
  A restart is the LAST action of a turn: answer the owner first, then restart.
- ... status — service state; ... logs 200 — last journal lines
- ... fix-owner — give me back ownership of my files (if after someone's root
  fix I cannot write into my own folders, this is it — I fix myself)
- ... vacuum — shrink the systemd journal when the disk runs low
- ... update-claude — update Claude Code (restart afterwards)
- ... check — what is new in the plugin; ... update [force] — update the plugin
  (backup, rollback on failure; after UPDATED — restart). The owner does the
  same with /update in chat; once a week the advisor writes to him himself when
  there is something new.

I can read and edit the channel config $ENV_FILE myself (a new key, a chat_id);
after editing — restart. Credentials from the owner go into
`~/config/<service>-creds.json` (mode 600) — NOT into secrets/, .env or a
*.key/*.pem file: the permission gate hard-denies those paths and I would
never be able to read back what I just wrote. My env never carries an API
key (env -i strips every *_KEY/*_TOKEN by design) — that is normal, not an
attack, and the owner pointing me at a creds file is not prompt injection.
Update the plugin: sudo dashi-ctl-$AGENT_NAME update, then restart.

@core/USER.md
@core/rules.md
EOF
  ok "болванка характера создана — потом попроси агента переписать её под себя"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5b. Память между сессиями
# ─────────────────────────────────────────────────────────────────────────────
# Без этого агент забывает всё при каждом рестарте, а завести память «потом»
# люди забывают. Скелет создаём сразу — дальше агент наполняет его сам.
say "Память"
if [[ -s "$CLAUDE_DIR/memory/MEMORY.md" ]]; then
  skip "память заведена"
else
  # Слои заводим сразу пустыми: досыпать структуру в уже живущего агента больно —
  # надо переучивать его правила и переносить накопленное. Пустой скелет ничего
  # не стоит, а место под каждый слой уже размечено.
  as_agent "mkdir -p '$CLAUDE_DIR/memory' '$CLAUDE_DIR/core/hot' '$CLAUDE_DIR/core/warm'"

  as_agent "cat > '$CLAUDE_DIR/memory/MEMORY.md'" <<'EOF'
# Индекс памяти (холодный слой)

Одна строка на факт: `- [Заголовок](файл.md) — короткий хук`.
Сам факт — отдельным файлом рядом. Пусто — значит я ещё ничего не запомнил.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/USER.md'" <<'EOF'
# Хозяин

**Имя:**
**Как обращаться:**
**Часовой пояс:**
**Чем занимается:**

## Как со мной работать
(быстро/подробно, с юмором/сухо, что бесит)

## Сейчас в фокусе
EOF

  as_agent "cat > '$CLAUDE_DIR/core/rules.md'" <<'EOF'
# Правила и правки

Сюда попадает каждая правка хозяина: что я сделал не так и как надо.
Формат: правило одной строкой + почему + как применять.

- Проверяю по первоисточнику, а не по памяти. Не уверен — говорю «не уверен».
- Необратимое (удаление, деньги, прод) — только с подтверждением.
- Задачу закрываю отчётом сам, без напоминаний.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/warm/decisions.md'" <<'EOF'
# Решения (тёплый слой, ~14 дней)

Что решили и почему. Старое вычищаю, чтобы не разрасталось.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/hot/handoff.md'" <<'EOF'
# Итоги последних сессий (горячий слой, последние 5)

Чем закончили, что висит, с чего продолжать.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/LEARNINGS.md'" <<'EOF'
# Уроки

Ошибка → что из неё следует. Урок без изменения в правилах или в коде
не работает: он не всплывёт в нужный момент. Поэтому каждый урок доводим
до правки в rules.md или до проверки в скрипте.
EOF
  ok "слои памяти созданы (hot / warm / cold + профиль и правила)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Конфиг канала
# ─────────────────────────────────────────────────────────────────────────────
say "Конфиг $ENV_FILE"
if [[ -f "$ENV_FILE" ]]; then
  # 660: агент сам правит канальный конфиг (новый ключ, chat_id) без терминала
  chown "root:$SERVICE_USER" "$ENV_FILE"; chmod 660 "$ENV_FILE"
  # Ветка обновлений: старые конфиги без строки → дописать; --branch меняет.
  if grep -q "^DASHI_BRANCH=" "$ENV_FILE"; then sed -i "s#^DASHI_BRANCH=.*#DASHI_BRANCH=$BRANCH#" "$ENV_FILE"
  else echo "DASHI_BRANCH=$BRANCH" >> "$ENV_FILE"; fi
  # Пояс хозяина: /update читает его отсюда, чтобы не сдвинуть сводку.
  if grep -q "^DASHI_OWNER_TZ=" "$ENV_FILE"; then sed -i "s#^DASHI_OWNER_TZ=.*#DASHI_OWNER_TZ=$OWNER_TZ#" "$ENV_FILE"
  else echo "DASHI_OWNER_TZ=$OWNER_TZ" >> "$ENV_FILE"; fi
  # Ключ Groq писался только при первом создании конфига: повторный прогон с
  # --groq-key молча его терял, и голосовые так и не включались.
  if [[ -n "$GROQ_KEY" ]]; then
    if grep -q "^GROQ_API_KEY=" "$ENV_FILE"; then sed -i "s#^GROQ_API_KEY=.*#GROQ_API_KEY=$GROQ_KEY#" "$ENV_FILE"
    else echo "GROQ_API_KEY=$GROQ_KEY" >> "$ENV_FILE"; fi
    ok "ключ Groq записан -- голосовые включатся после перезапуска"
  fi
  # Порт вебхука: --webhook-port меняет, без флага строка не трогается.
  if [[ $PORT_GIVEN -eq 1 ]]; then
    if grep -q "^TELEGRAM_WEBHOOK_PORT=" "$ENV_FILE"; then sed -i "s#^TELEGRAM_WEBHOOK_PORT=.*#TELEGRAM_WEBHOOK_PORT=$WEBHOOK_PORT#" "$ENV_FILE"
    else echo "TELEGRAM_WEBHOOK_PORT=$WEBHOOK_PORT" >> "$ENV_FILE"; fi
  fi
  # Модель: --model меняет, без флага существующая строка не трогается.
  if [[ -n "$MODEL" ]]; then
    if grep -q "^DASHI_MODEL=" "$ENV_FILE"; then sed -i "s#^DASHI_MODEL=.*#DASHI_MODEL=$MODEL#" "$ENV_FILE"
    else echo "DASHI_MODEL=$MODEL" >> "$ENV_FILE"; fi
  fi
  skip "конфиг на месте (права обновлены: 660, ветка $BRANCH)"
else
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# dashi-channel · $AGENT_NAME — создан install-agent.sh
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_EXPECTED_BOT_ID=${BOT_TOKEN%%:*}
TELEGRAM_ALLOWED_USER_IDS=$USER_ID
TELEGRAM_ALLOWED_CHAT_IDS=$USER_ID
TELEGRAM_WORKSPACE_ROOT=$CLAUDE_DIR
TELEGRAM_STATE_DIR=$WORKSPACE/state/telegram
# Дословный журнал переписки: каждый ход пишется в $WORKSPACE/logs/verbose-ГГГГ-ММ-ДД.jsonl
# и выжимка в core/hot/recent.md. Без этого агент на вопрос «что я тебе утром
# говорил» честно отвечает «истории нет»: Telegram ботам прошлое не отдаёт, а
# своя память умирает с перезапуском (Саня 11.09.2026, агент gorbot).
TELEGRAM_MEMORY_ENABLED=1
TELEGRAM_MEMORY_WORKSPACE=$CLAUDE_DIR
TELEGRAM_MEMORY_AGENT_LABEL=$AGENT_NAME
# Приёмник событий от Claude. Без явного порта плагин берёт случайный, и хуки,
# прописанные на этот порт, стучатся в пустоту — карточка «работаю…» не появляется.
# Тот же порт читают хуки (install-hooks) и сторож моста в dashi-run.
TELEGRAM_WEBHOOK_HOST=127.0.0.1
TELEGRAM_WEBHOOK_PORT=$WEBHOOK_PORT
# Хуки без токена молча ничего не отправляют — обе стороны читают эту строку.
TELEGRAM_WEBHOOK_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
AGENT_ID=$AGENT_NAME
GROQ_API_KEY=$GROQ_KEY
DASHI_BRANCH=$BRANCH
# Пояс хозяина: утренние кроны комплекта встают на 09:00 по нему (--tz).
DASHI_OWNER_TZ=$OWNER_TZ
# Модель Claude (opus|sonnet|haiku|полный id). Пусто = дефолт аккаунта владельца.
# Поменять: вписать сюда и systemctl restart dashi-<агент>.
DASHI_MODEL=$MODEL
EOF
  chown "root:$SERVICE_USER" "$ENV_FILE"
  chmod 660 "$ENV_FILE"
  ok "конфиг записан (660 root:$SERVICE_USER — агент может править сам)"
fi

# Живая карточка «работаю…» в Telegram: в плагине выключена по умолчанию.
if as_agent "test -s '$WORKSPACE/state/telegram/config.json'"; then
  skip "карточка прогресса настроена"
else
  as_agent "mkdir -p '$WORKSPACE/state/telegram' && printf '%s\\n' '{ \"webhook\": { \"enabled\": true }, \"progress\": { \"enabled\": true } }' > '$WORKSPACE/state/telegram/config.json'"
  ok "карточка прогресса включена"
fi

# Группы. Без политики плагин работает «только личка» и любую группу молча
# выкидывает -- бота добавляли в рабочий чат, а он молчал (живая установка
# 02.10.2026). Личка владельца -- шаблон для новых групп: route master (у
# отдельной сессии нет входа в Claude, годовой токен ей не передаётся) и
# open_to_members (звать через @ может любой участник группы, Саня 02.10).
POLICY_FILE="$CLAUDE_DIR/chats/policy.yaml"
if as_agent "test -s '$POLICY_FILE'"; then
  skip "политика чатов на месте"
else
  as_agent "mkdir -p '$CLAUDE_DIR/chats' '$CLAUDE_DIR/state/multichat' && umask 077 && cat > '$POLICY_FILE'" <<EOF
version: 1
allowlist:
  chats:
    - "$USER_ID"
  users:
    - "$USER_ID"
mention_allowlist:
  - "$USER_ID"
chats:
  "$USER_ID":
    mode: private
    streaming: progress
    tmux_mirror: false
    edit_message_progress: true
    delivery: streamed
    persona_file: CLAUDE.md
    handoff_file: core/hot/handoff.md
    system_reminder: ""
    route: master
    open_to_members: true
EOF
  ok "группы включены: добавь бота в чат и позови через @ — заведётся сам"
fi
if ! grep -q "^TELEGRAM_MULTICHAT_ENABLED=" "$ENV_FILE"; then
  cat >> "$ENV_FILE" <<EOF
# Группы (политика -- $POLICY_FILE)
TELEGRAM_MULTICHAT_ENABLED=true
TELEGRAM_MULTICHAT_POLICY_PATH="$POLICY_FILE"
TELEGRAM_MULTICHAT_STATE_DIR="$CLAUDE_DIR/state/multichat"
TELEGRAM_MULTICHAT_WORKSPACE_DIR="$CLAUDE_DIR"
EOF
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Hooks
# ─────────────────────────────────────────────────────────────────────────────
say "Hooks"
# Гоняем ВСЕГДА, без skip по маркеру: install-hooks.sh идемпотентен (заменяет
# свою запись), а skip консервировал старые хуки с устаревшим matcher —
# у агента с июльским плагином шаги задач так и не попадали в карточку (20.08).
# install-hooks.sh зовёт `bun` по имени, а в неинтерактивном su его нет в PATH.
as_agent "export PATH=\$HOME/.bun/bin:\$PATH; cd '$PLUGIN_DIR' && bash scripts/install-hooks.sh \
    --settings ~/.claude/settings.json \
    --chat-id '$USER_ID' \
    --webhook-url http://127.0.0.1:$WEBHOOK_PORT/hooks/agent \
    --agent-id dashi-channel \
    --verbose-progress" >/dev/null || die "install-hooks.sh упал"
ok "хуки актуализированы"

# Сторож контекста: раз в сессию напоминает агенту сказать хозяину, что
# «память разговора» заполняется и пора /compact или /new.
WATCH="$CLAUDE_DIR/dashi-plugin-claude-code/scripts/context-watch.sh"
if as_agent "grep -q context-watch.sh ~/.claude/settings.json 2>/dev/null"; then
  skip "сторож контекста прописан"
else
  as_agent "jq --arg c '$WATCH' '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{matcher:\"\",hooks:[{type:\"command\",command:\$c}]}])' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json" \
    || die "не смог прописать сторож контекста в settings.json"
  ok "сторож контекста включён"
fi

# Автосжатие: когда разговор занял 85% памяти, агент сам подрезает его, не
# дожидаясь потолка. Без этого сессия пухнет, пока не перестаёт отвечать вовсе
# (11.09.2026: у чужого агента набежало 779k при потолке 200k -- ни /compact,
# ни команды уже не проходили, спасал только полный сброс).
AUTOC="$CLAUDE_DIR/dashi-plugin-claude-code/scripts/context-autocompact.sh"
if as_agent "grep -q context-autocompact.sh ~/.claude/settings.json 2>/dev/null"; then
  skip "автосжатие разговора прописано"
else
  as_agent "jq --arg c '$AUTOC' '.hooks.Stop = ((.hooks.Stop // []) + [{matcher:\"\",hooks:[{type:\"command\",command:\$c}]}])' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json" \
    || die "не смог прописать автосжатие в settings.json"
  ok "автосжатие разговора включено"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7b. Дисциплина (agent-kit)
# ─────────────────────────────────────────────────────────────────────────────
# Скелет выше даёт агента, который живёт и говорит. Комплект ниже даёт ему
# СПОСОБ РАБОТЫ, который Jarvis нарабатывал полгода через правки хозяина:
# конституция вместо трёх строк, гейт-хуки, реестры, три помощника.
say "Дисциплина (конституция, гейты, помощники)"
KIT_DIR="$CLAUDE_DIR/dashi-plugin-claude-code/agent-kit"
if [[ -x "$KIT_DIR/install-kit.sh" ]]; then
  # Кроны будильника и утренней сводки теперь ставит сам kit (--tz): так их
  # получает и агент, обновлённый по гайду «Update плагина», а не только свежая
  # установка (леджер молчал у обновлённых — Саня 31.08).
  as_agent "bash '$KIT_DIR/install-kit.sh' \
      --claude-dir '$CLAUDE_DIR' \
      --chat-id '$USER_ID' \
      --agent '$AGENT_NAME' \
      --settings ~/.claude/settings.json \
      --tz '$OWNER_TZ'" \
    || die "install-kit.sh упал"
  # Утренние кроны (сводка, будильник по срокам, советник по обновлениям,
  # самопроверка, отчёт о состоянии сервера) ставит сам комплект — он же
  # догоняет агентов, поднятых раньше, на каждом /update.
  # ── Канарейка планировщика ────────────────────────────────────────────────
  # Крон умеет МОЛЧА перестать выполнять задачи пользователя: одна лишняя жёсткая
  # ссылка на файле расписания — и он его не грузит (Саня, 27.08.2026: шесть часов
  # простоя, встали все ночные задачи разом, и заметить это было неоткуда).
  # Сторож живёт в systemd, а не в кроне — иначе он умрёт вместе с тем, что сторожит.
  CANARY="* * * * * /usr/bin/touch $WORKSPACE/data/cron-heartbeat"
  as_agent "mkdir -p '$WORKSPACE/data'"
  if as_agent "crontab -l 2>/dev/null | grep -q cron-heartbeat"; then
    skip "канарейка крона уже стоит"
  else
    as_agent "(crontab -l 2>/dev/null; echo '$CANARY') | crontab -" \
      && ok "канарейка крона в расписании" || warn "не смог прописать канарейку"
  fi
  cat > "/usr/local/bin/cron-canary-$AGENT_NAME" <<CANEOF
#!/bin/bash
# Канарейка протухла -> крон не выполняет задачи агента. Пишем хозяину.
f="$WORKSPACE/data/cron-heartbeat"
[ -f "\$f" ] || exit 0
age=\$(( ( \$(date +%s) - \$(stat -c %Y "\$f") ) / 60 ))
[ "\$age" -gt 10 ] || exit 0
. "$ENV_FILE"
# Отправку ПРОВЕРЯЕМ. Слепой curl >/dev/null означает: протух токен или сменился
# chat_id -- крик о мёртвом планировщике уходит в никуда, и молчат оба, и крон,
# и канарейка. Код ответа идёт в журнал службы (Jarvis 14.09.2026: у себя нашёл
# ровно это -- за десять дней ни одной строки о доставке сигнала «я поднялся»).
code=\$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \\
  "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \\
  -d chat_id="\${TELEGRAM_ALLOWED_USER_IDS%%,*}" \\
  -d text="Планировщик задач не работает: минутная задача молчит \$age мин. Ночные задачи агента $AGENT_NAME сейчас НЕ выполняются.") || code=000
if [ "\$code" = "200" ]; then
  echo "cron-canary: хозяин предупреждён (HTTP 200), простой \$age мин"
else
  echo "cron-canary: ПРЕДУПРЕДИТЬ НЕ УДАЛОСЬ (HTTP \$code), простой \$age мин" >&2
fi
CANEOF
  chmod 755 "/usr/local/bin/cron-canary-$AGENT_NAME"
  cat > "/etc/systemd/system/cron-canary-$AGENT_NAME.service" <<CANEOF
[Unit]
Description=Канарейка крона для агента $AGENT_NAME
[Service]
Type=oneshot
User=$SERVICE_USER
ExecStart=/usr/local/bin/cron-canary-$AGENT_NAME
CANEOF
  cat > "/etc/systemd/system/cron-canary-$AGENT_NAME.timer" <<CANEOF
[Unit]
Description=Проверка канарейки крона каждые 15 минут
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
CANEOF
  systemctl daemon-reload
  systemctl enable --now "cron-canary-$AGENT_NAME.timer" >/dev/null 2>&1 \
    && ok "сторож канарейки поднят (systemd-таймер, от крона не зависит)" \
    || warn "не смог поднять сторож канарейки"
  ok "комплект разложен: конституция, гейты, реестры, помощники"
else
  warn "agent-kit не найден ($KIT_DIR) — агент встанет без гейтов и реестров"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. systemd
# ─────────────────────────────────────────────────────────────────────────────
# Прожиматель стартовых диалогов: смотрит на экран и жмёт нужное. Слепой
# Down+Enter ломался, когда bypass-вопрос уже принят: Down попадал в диалог
# dev-каналов и выбирал «Exit» — сервис сам убивал Claude (кейс 20.08.2026).
say "Прожиматель стартовых диалогов"
cat > /usr/local/bin/dashi-press-dialogs <<'EOF'
#!/usr/bin/env bash
# Bypass Permissions -> Down+Enter (дефолт «No, exit»), остальные диалоги
# (dev channels, trust, внешние импорты) -> Enter. Всегда exit 0: зовётся
# фоном из dashi-run, его код возврата никого не интересует, а падение
# с ошибкой только засоряет журнал.
set -u
SESSION="${1:?usage: dashi-press-dialogs <tmux-session>}"
# Замок на панель: в неё печатает ещё и автосжатие (context-autocompact.sh),
# у которого между набором «/compact» и Enter есть пауза. Наш Enter в эту щель
# подтверждает не ту строку, а на диалоге с «No, exit» -- выбивает Claude:
# сессия умирает, systemd поднимает службу заново, и в журналетолько факт смерти.
# 11.09.2026, агент Гора: 15 таких рестартов за день. Один писатель на панель.
press() {
  ( exec 9>"/tmp/dashi-pane-${SESSION//[^a-zA-Z0-9]/_}.lock"
    flock -w 3 9 || exit 0
    tmux send-keys -t "$SESSION" "$@" ) || true
}
# 40×3с = 2 мин: на слабом VPS (1 ГБ + своп) Claude грузится дольше 45 секунд
for _ in $(seq 1 40); do
  sleep 3
  screen="$(tmux capture-pane -pt "$SESSION" 2>/dev/null)" || exit 0
  # 02.09.2026: Claude Code 2.1.25x спрашивает «Do you trust this folder?» с курсором на
  # «No, exit» — слепой Enter ВЫХОДИЛ из Claude, сервис крутился в рестартах (живой прогон
  # на Смите). Любой диалог, где выделено «No, exit», — сначала Down, потом Enter.
  if grep -qE "❯ *No, exit" <<<"$screen"; then
    press Down
    sleep 1
    press Enter
  elif grep -q "Bypass Permissions" <<<"$screen"; then
    press Down
    sleep 1
    press Enter
  # Онбординг (выбор темы и пр.) раньше проходил человек при ручном логине;
  # с годовым токеном логина нет — экраны всплывают при первом старте сервиса
  elif grep -qE "development channels|Do you trust|Enter to confirm|Light mode|Dark mode|text style|Syntax theme" <<<"$screen"; then
    press Enter
  elif grep -q "bypass permissions on" <<<"$screen"; then
    exit 0  # диалоги пройдены, Claude работает
  fi
done
exit 0
EOF
chmod 755 /usr/local/bin/dashi-press-dialogs
ok "диалоги жмутся по содержимому экрана, не вслепую"

# Держатель сессии: Type=forking с tmux ненадёжен — systemd теряет main PID
# демонизировавшегося tmux-сервера и тут же зовёт ExecStop, убивая только что
# поднятого агента (кейс 20.08.2026). Type=simple + процесс, живущий пока жива
# сессия, — проверенная схема.
cat > /usr/local/bin/dashi-run <<'EOF'
#!/usr/bin/env bash
# Поднимает tmux-сессию с Claude и живёт, пока жива она (для Type=simple).
# Плюс сторож моста: Telegram-мост (вебхук 127.0.0.1:PORT) был жив и пропал
# на 2 проверки подряд -> выходим ненулевым, systemd перезапустит всё целиком.
# Иначе классика «tmux жив, мост сдох»: systemd доволен, бот молчит, ремонт
# только терминалом. До первого подъёма моста порт не проверяем — на свежей
# установке Claude может стоять на логине сколько угодно.
# Порт: аргумент → TELEGRAM_WEBHOOK_PORT из channel.env (EnvironmentFile юнита)
# → 8089. Второй агент на хосте живёт на своём порту — сторож обязан смотреть туда же.
set -uo pipefail
SESSION="${1:?usage: dashi-run <tmux-session> <plugin-dir> [webhook-port]}"
PLUGIN="${2:?usage: dashi-run <tmux-session> <plugin-dir> [webhook-port]}"
PORT="${3:-${TELEGRAM_WEBHOOK_PORT:-8089}}"
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" \
  "/bin/bash -lc 'cd $PLUGIN && exec claude ${DASHI_MODEL:+--model $DASHI_MODEL} --dangerously-skip-permissions --dangerously-load-development-channels server:dashi-channel'"
sleep 3
# Экран сессии пишем в файл: Claude выводит всё в псевдотерминал, и когда он
# умирает, в journald долетает только «сессия умерла», без причины. Файл
# обнуляем на каждом старте -- нужен экран последнего падения, не архив.
mkdir -p "$HOME/logs"
# Предыдущий экран не стираем, а сдвигаем в .prev: причина падения видна
# ИМЕННО в том, что было до смерти сессии, а старт затирал бы её начисто.
[[ -f "$HOME/logs/tmux-pane.log" ]] && mv -f "$HOME/logs/tmux-pane.log" "$HOME/logs/tmux-pane.prev.log"
: > "$HOME/logs/tmux-pane.log"
tmux pipe-pane -o -t "$SESSION" "cat >> $HOME/logs/tmux-pane.log"
tmux has-session -t "$SESSION" 2>/dev/null || { echo "tmux session did not start" >&2; exit 1; }
/usr/local/bin/dashi-press-dialogs "$SESSION" &
# Пинг хозяину «перезапуск завершён» -- один раз, когда мост впервые поднялся.
# Без него после restart непонятно, готов агент или ещё встаёт: tmux жив, а
# сообщения до Claude пока не доезжают. Код ответа -- в журнал службы, токен
# никогда: молчаливый curl не оставляет следа, дошёл ли пинг (Jarvis 14.09.2026).
notify_online() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_ALLOWED_USER_IDS:-}" ]] || return 0
  local code
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_ALLOWED_USER_IDS%%,*}" \
    --data-urlencode "text=🟢 на связи, work hard no drama (systemd, перезапуск завершён)") || code=000
  echo "online ping: HTTP $code" >&2
}
seen_up=0 down=0
while tmux has-session -t "$SESSION" 2>/dev/null; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    (( seen_up )) || notify_online &
    seen_up=1 down=0
  elif (( seen_up )); then
    down=$((down + 1))
    (( down >= 2 )) && { echo "bridge port $PORT dead, restarting" >&2; exit 1; }
  fi
  # Лог экрана пишется постоянно (у боевого агента ~15 МБ в сутки), а сессия
  # может жить месяцами -- режем хвостом, не трогая файл как объект: pipe-pane
  # держит его открытым на дозапись, и подмена через mv увела бы вывод в
  # удалённый inode. Нужен последний экран, а не архив за месяц.
  if (( $(stat -c%s "$HOME/logs/tmux-pane.log" 2>/dev/null || echo 0) > 4194304 )); then
    tail -c 2097152 "$HOME/logs/tmux-pane.log" > "$HOME/logs/.pane-tail" \
      && cat "$HOME/logs/.pane-tail" > "$HOME/logs/tmux-pane.log"
    rm -f "$HOME/logs/.pane-tail"
  fi
  sleep 15
done
EOF
chmod 755 /usr/local/bin/dashi-run
ok "держатель сессии установлен"

say "Автозапуск ($UNIT)"
cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Dashi channel for $AGENT_NAME (Telegram -> Claude Code)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$PLUGIN_DIR
EnvironmentFile=$ENV_FILE
Environment=HOME=$HOME_DIR
Environment=PATH=$HOME_DIR/.bun/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=LANG=en_US.UTF-8

# Claude Code интерактивный — живёт в tmux (нужен TTY); dashi-run поднимает
# сессию, прожимает стартовые диалоги по содержимому экрана и живёт, пока жива
# сессия, — systemd честно видит смерть агента и перезапускает
Type=simple
ExecStart=/usr/local/bin/dashi-run channel-$AGENT_NAME $PLUGIN_DIR
ExecStop=/usr/bin/tmux kill-session -t channel-$AGENT_NAME

Restart=always
RestartSec=15s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "юнит записан"

# ─────────────────────────────────────────────────────────────────────────────
# 8a. Sudo для самообслуживания
# ─────────────────────────────────────────────────────────────────────────────
# Без этого агент не может сам перезапустить свой мост и посмотреть его логи —
# и гоняет человека в терминал под root. Права точечные: ровно свой сервис.
say "Sudo для самообслуживания"
# Никаких wildcard-прав в sudoers (journalctl * читает произвольные файлы через
# --file=, chown по глобу эскалируется через симлинки). Вместо этого один
# root-owned скрипт с зашитыми путями — валидация аргументов внутри него.
CTL="/usr/local/bin/dashi-ctl-$AGENT_NAME"
REPO_DIR="$CLAUDE_DIR/dashi-plugin-claude-code"
cat > "$CTL" <<EOF
#!/usr/bin/env bash
# Самообслуживание агента $AGENT_NAME. Принадлежит root, зовётся через sudo.
set -euo pipefail
case "\${1:-}" in
  restart)       exec systemctl restart $UNIT ;;
  status)        exec systemctl status $UNIT --no-pager ;;
  logs)          n="\${2:-100}"; [[ "\$n" =~ ^[0-9]{1,5}\$ ]] || exit 2
                 exec journalctl -u $UNIT -n "\$n" --no-pager ;;
  fix-owner)     exec chown -R $SERVICE_USER:$SERVICE_USER /home/$SERVICE_USER ;;
  vacuum)        exec journalctl --vacuum-size=500M ;;
  cleanup)       CLEANUP_LOG=/var/log/dashi-$AGENT_NAME-cleanup.log exec /usr/local/bin/dashi-cleanup-$AGENT_NAME "$SERVICE_USER" "\${2:-}" ;;
  update-claude) exec npm install -g @anthropic-ai/claude-code ;;
  check)         # что нового в origin/main — список коммитов, пусто = свежий
                 runuser -u $SERVICE_USER -- git -C $REPO_DIR fetch -q --depth 30 origin $BRANCH
                 exec runuser -u $SERVICE_USER -- git -C $REPO_DIR log --oneline HEAD..FETCH_HEAD ;;
  update)        # Обновление плагина из чата (/update). Одно слово статуса в stdout:
                 # DIRTY <файлы> | UPTODATE | NOFETCH | UPDATED <n> <sha> | ROLLBACK.
                 # Бэкап рядом (.bak), падение reset/bun = откат на бэкап. Рестарт НЕ
                 # делает — его зовёт плагин отдельно, чтобы ответ успел уйти в чат.
                 g() { runuser -u $SERVICE_USER -- git -C $REPO_DIR "\$@"; }
                 dirty="\$(g status --porcelain -- . ':!plugin/bun.lock' | awk '{print \$2}' | head -5 | tr '\n' ' ')"
                 if [[ -n "\$dirty" && "\${2:-}" != force ]]; then echo "DIRTY \$dirty"; exit 3; fi
                 g fetch -q --depth 30 origin $BRANCH || { echo NOFETCH; exit 5; }
                 n="\$(g rev-list --count HEAD..FETCH_HEAD)"
                 [[ "\$n" == 0 ]] && { echo UPTODATE; exit 0; }
                 rm -rf $REPO_DIR.bak; cp -a $REPO_DIR $REPO_DIR.bak
                 if g reset -q --hard FETCH_HEAD \\
                    && runuser -u $SERVICE_USER -- bash -lc "cd '$PLUGIN_DIR' && ~/.bun/bin/bun install --silent"; then
                   # Комплект дисциплины лежит КОПИЯМИ в ~/.claude, а не читается из
                   # репозитория — без этого прогона новые гейты и реестры доезжают
                   # до кода, но не до агента. Скрипт идемпотентен и не трогает
                   # правки хозяина, поэтому гоняем на каждом обновлении.
                   # Пояс хозяина и settings.json — те же, что у установщика: иначе
                   # сводка съезжает на час сервера, а хуки регистрируются дважды.
                   KIT=$REPO_DIR/agent-kit/install-kit.sh
                   tz="\$(sed -n 's/^DASHI_OWNER_TZ=//p' $ENV_FILE | head -1)"
                   [[ -x "\$KIT" ]] && runuser -u $SERVICE_USER -- bash "\$KIT" \\
                     --claude-dir '$CLAUDE_DIR' --chat-id '$USER_ID' --agent '$AGENT_NAME' \\
                     --settings '/home/$SERVICE_USER/.claude/settings.json' --tz "\$tz" >/dev/null 2>&1 || true
                   echo "UPDATED \$n \$(g rev-parse --short HEAD)"
                 else
                   rm -rf $REPO_DIR; mv $REPO_DIR.bak $REPO_DIR; echo ROLLBACK; exit 4
                 fi ;;
  *) echo "usage: dashi-ctl-$AGENT_NAME restart|status|logs [N]|fix-owner|vacuum|cleanup [--dry-run]|update-claude|check|update [force]" >&2; exit 2 ;;
esac
EOF
chmod 755 "$CTL"
SUDOERS_FILE="/etc/sudoers.d/dashi-$AGENT_NAME"
# На минимальных образах (без пакета sudo) каталога нет, и установка падала
# здесь целиком -- шаги после этого места не выполнялись вовсе (11.09.2026).
mkdir -p /etc/sudoers.d
cat > "$SUDOERS_FILE" <<EOF
# Агент $AGENT_NAME обслуживает себя ТОЛЬКО через root-owned dashi-ctl
$SERVICE_USER ALL=(root) NOPASSWD: $CTL
EOF
chmod 440 "$SUDOERS_FILE"
if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
  ok "агент может сам: restart/status/логи/fix-owner/vacuum/update-claude/check/update"
else
  rm -f "$SUDOERS_FILE"
  warn "sudoers не прошёл проверку visudo — пропускаю (агент не сможет сам перезапускаться)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8b. Предохранитель
# ─────────────────────────────────────────────────────────────────────────────
# Раз в неделю смотрит на цифры (объём памяти, падения, диск) и, если что-то
# переросло текущую схему, сам пишет хозяину — что пора сделать и почему.
# Без этого человек узнаёт о проблеме, только когда она уже мешает.
say "Предохранитель"
cat > "/etc/cron.d/dashi-$AGENT_NAME-advisor" <<EOF
# Советы по обслуживанию агента $AGENT_NAME — понедельник, 10:00
SHELL=/bin/bash
# Не root: скрипт лежит в agent-owned папке — root-кроном отсюда исполнять
# нельзя (перезапись файла = произвольный код под root)
0 10 * * 1 $SERVICE_USER /bin/bash $CLAUDE_DIR/dashi-plugin-claude-code/scripts/agent-advisor.sh $AGENT_NAME >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-advisor"
ok "советник включён (по понедельникам в 10:00)"

# Прожиматель модалок: «Switch model?» и подобные вопросы Claude блокируют
# очередь сообщений, пока кто-то не нажмёт 1 — жмём из крона раз в минуту.
cat > "/etc/cron.d/dashi-$AGENT_NAME-modal" <<EOF
* * * * * $SERVICE_USER /bin/bash $CLAUDE_DIR/dashi-plugin-claude-code/scripts/modal-watch.sh channel-$AGENT_NAME >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-modal"
ok "прожиматель модалок включён"

# Обновление Claude Code: сам себя он обновить не может -- крутится под
# service-юзером без прав на свою папку установки, и на экране висит
# «Auto-update failed». Обновляем под root раз в неделю ночью; часы сервера
# уже переведены на пояс хозяина выше, так что 04:30 -- это его ночь.
cat > "/etc/cron.d/dashi-$AGENT_NAME-claude-update" <<EOF
30 4 * * 1 root /usr/local/bin/dashi-ctl-$AGENT_NAME update-claude >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-claude-update"
ok "еженедельное обновление Claude включено (понедельник 04:30)"

# Еженедельная уборка диска: остановленные контейнеры, неиспользуемые образы,
# кэши пакетов, старый /tmp, большие логи (обрезка). Живое не трогает. Root-копия
# скрипта — root-крон не исполняет файлы, которые может переписать агент.
# Итог пишется в журнал уборки; советник в понедельник шлёт его хозяину.
install -o root -g root -m 755 "$REPO_DIR/scripts/disk-cleanup.sh" "/usr/local/bin/dashi-cleanup-$AGENT_NAME"
cat > "/etc/cron.d/dashi-$AGENT_NAME-cleanup" <<EOF
30 3 * * 1 root /usr/local/bin/dashi-ctl-$AGENT_NAME cleanup >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-cleanup"
ok "еженедельная уборка диска включена (понедельник 03:30)"

# ─────────────────────────────────────────────────────────────────────────────
# 8d. Шифрованный бэкап (по желанию)
# ─────────────────────────────────────────────────────────────────────────────
# Память агента, его характер и секреты живут ТОЛЬКО на этом сервере (в git их
# нет). Умрёт VPS — всё пропадёт. Бэкап шифрует эти данные и, если подключить
# облако, кладёт копию за пределы сервера. По желанию: человек сам решает.
say "Шифрованный бэкап (по желанию)"
cat <<'EOF'
    Память, характер и секреты агента лежат только на этом сервере — в GitHub их
    нет. Если сервер умрёт, всё это пропадёт безвозвратно. Бэкап делает
    шифрованный слепок этих данных раз в сутки. Если подключишь облако (Google
    Drive через rclone) — копия уедет за пределы сервера, и тогда после смерти
    VPS агента можно поднять заново из бэкапа.
    ВАЖНО: пароль от бэкапа сохрани ОТДЕЛЬНО (не только на этом сервере) — иначе
    облачную копию нечем будет расшифровать, когда сервер пропадёт.
EOF
setup_backup=0
if [[ $ASSUME_YES -eq 1 ]]; then
  setup_backup=1   # неинтерактивно: включаем (данные важнее, off-site настроят потом)
else
  # Без терминала read падает, __b остаётся неопределённой, и set -u ронял весь
  # установщик на «unbound variable» (02.10.2026, разбор под инструкцию). Пусто = «да».
  __b=""
  read -r -p "    Включить шифрованный бэкап? [Y/n] " __b </dev/tty || true
  [[ ! "$__b" =~ ^[Nn] ]] && setup_backup=1
fi
if [[ $setup_backup -eq 1 ]]; then
  PASS_FILE="$WORKSPACE/secrets/backup.pass"
  if ! as_agent "test -s '$PASS_FILE'"; then
    BK_PASS="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
    # Пароль через stdin, не в командной строке su — иначе он виден в ps любому
    printf '%s\n' "$BK_PASS" | su - "$SERVICE_USER" -c "umask 077; cat > '$PASS_FILE'"
    printf '\n    \033[1;33mПАРОЛЬ ОТ БЭКАПА (сохрани отдельно от сервера!):\033[0m %s\n\n' "$BK_PASS"
    [[ $ASSUME_YES -eq 0 ]] && read -r -p "    Сохранил пароль? Enter для продолжения " _ </dev/tty || true
  else
    skip "пароль бэкапа уже есть ($PASS_FILE)"
  fi
  cat > "/etc/cron.d/dashi-$AGENT_NAME-backup" <<EOF
# Шифрованный бэкап агента $AGENT_NAME — каждый день в 03:40
SHELL=/bin/bash
40 3 * * * $SERVICE_USER DASHI_AGENT=$AGENT_NAME DASHI_WORKSPACE=$WORKSPACE /bin/bash $CLAUDE_DIR/dashi-plugin-claude-code/scripts/agent-backup.sh >/dev/null 2>&1
EOF
  chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-backup"
  ok "бэкап включён (ежедневно 03:40, локально в $WORKSPACE/backups)"
  # Первый архив -- сразу, а не ночью: иначе до первой ночи проверка здоровья
  # пишет «бэкап не настроен», и у свежего агента нет ни одной копии (Смит,
  # переустановка 26.09.2026). Прогон занимает секунды.
  if runuser -u "$SERVICE_USER" -- env DASHI_AGENT="$AGENT_NAME" DASHI_WORKSPACE="$WORKSPACE" \
       /bin/bash "$CLAUDE_DIR/dashi-plugin-claude-code/scripts/agent-backup.sh" >/dev/null 2>&1 \
     && ls "$WORKSPACE"/backups/*.gpg >/dev/null 2>&1; then
    ok "первый бэкап сделан"
  else
    warn "первый бэкап не получился -- ночной прогон попробует снова"
  fi
  # rclone ставим ВСЕГДА: без него облачная копия невозможна в принципе, а
  # хозяин узнавал об этом уже после смерти сервера (Саня 27.08.2026).
  command -v rclone >/dev/null 2>&1 || apt-get install -y -qq rclone >/dev/null 2>&1 || true
  if as_agent "command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q ."; then
    ok "rclone-remote найден — копия уедет off-site автоматически"
  elif [[ $ASSUME_YES -eq 0 ]]; then
    # Спрашиваем прямо здесь: облачная копия — единственное, что переживает
    # смерть VPS, а «настрою потом» не наступает никогда (Саня 27.08.2026).
    cat <<EOF

    Подключаем Google Drive — это займёт 5 минут и делается один раз.
    Вход в гугл требует браузера, поэтому сделай это на СВОЁМ компьютере
    (в отдельном окне терминала, НЕ внутри ssh на сервер):
    СНАЧАЛА заведи свой ключ Google — без него rclone ходит под общим ключом,
    одним на всех пользователей в мире, и в часы пик бэкап падает с «квота
    превышена». Это бесплатно, карта и биллинг не нужны:
      1) console.cloud.google.com под тем гуглом, где будет лежать бэкап →
         создай проект (имя любое, например dashi-backups)
      2) «APIs & Services» → «Library» → найди «Google Drive API» → Enable
      3) «APIs & Services» → «OAuth consent screen» → тип External →
         заполни обязательные поля → «Audience» → «Test users» → «+ Add users»:
         ТОТ адрес, которым войдёшь в шаге 7 (иначе «Ошибка 403: access_denied»)
         и там же «Publish app» → «Confirm» (иначе через 7 дней Google гасит
         вход и копии молча перестают уезжать в облако)
      4) «APIs & Services» → «Credentials» → «Create credentials» →
         «OAuth client ID» → тип «Desktop app» → скопируй Client ID и Client secret

    ПОТОМ вход в гугл — он требует браузера, поэтому делай на СВОЁМ компьютере
    (в отдельном окне терминала, НЕ внутри ssh на сервер):
      5) поставь rclone (brew не нужен). mac — команды по одной:
           cd ~/Downloads
           A=\$(uname -m | sed s/x86_64/amd64/)
           curl -fsSLO https://downloads.rclone.org/rclone-current-osx-\$A.zip
           unzip -o rclone-current-osx-\$A.zip
           cd rclone-*-osx-\$A
         windows — скачай zip с rclone.org/downloads, распакуй, открой
         в этой папке PowerShell и пиши .\\rclone.exe вместо ./rclone
      6) выполни, подставив свои значения из шага 4:
         ./rclone authorize "drive" ВАШ_ID ВАШ_SECRET   (ID и SECRET через пробел, без флагов)
      7) войди в гугл, разреши доступ — в терминале появится строка
         вида {"access_token":...}
    Вставь сюда Client ID, Client secret и эту строку. Пропустить — просто Enter
    (тогда бэкап останется только на этом сервере).

EOF
    ask GDRIVE_CLIENT_ID "    Client ID (шаг 4, пусто = общий ключ и падения по квоте): " 0
    ask GDRIVE_CLIENT_SECRET "    Client secret: " 0
    ask GDRIVE_TOKEN "    Строка токена: " 0
    if [[ -n "${GDRIVE_TOKEN:-}" ]]; then
      TOKFILE="$(mktemp)"; printf '%s' "$GDRIVE_TOKEN" > "$TOKFILE"
      chmod 600 "$TOKFILE"; chown "$SERVICE_USER:$SERVICE_USER" "$TOKFILE"
      # Пишем секцию в конфиг руками: `rclone config create ... token` на старых
      # версиях (1.53 в Ubuntu 22.04) игнорирует готовый токен и всё равно лезет
      # в интерактивный OAuth — на сервере это тупик.
      # Свой client_id — не косметика: на общем ключе rclone бэкап падает по квоте
      # в часы пик (агент Лены, 4 дня подряд, 11.09.2026).
      GD_KEYS=""
      if [[ -n "${GDRIVE_CLIENT_ID:-}" && -n "${GDRIVE_CLIENT_SECRET:-}" ]]; then
        GD_KEYS="client_id = ${GDRIVE_CLIENT_ID}\nclient_secret = ${GDRIVE_CLIENT_SECRET}\n"
      fi
      as_agent "mkdir -p ~/.config/rclone && umask 077 && { grep -q '^\[gdrive\]' ~/.config/rclone/rclone.conf 2>/dev/null || printf '[gdrive]\ntype = drive\nscope = drive\n${GD_KEYS}token = %s\n' \"\$(cat '$TOKFILE')\" >> ~/.config/rclone/rclone.conf; }"
      # Причину показываем словами rclone: «403 quota» — это не битый токен, а лимит Google
      # на минуту, конфиг уже записан и ночью заработает сам (живой прогон 02.09).
      rc_err="$(as_agent "rclone lsd gdrive: --retries 1 --low-level-retries 1 --timeout 20s 2>&1 >/dev/null" | tail -1 | cut -c1-160)"
      if [[ -z "$rc_err" ]]; then
        ok "Google Drive подключён — ночная копия уедет в облако"
      elif grep -qiE "quota|rate ?limit|403" <<<"$rc_err"; then
        if [[ -z "${GDRIVE_CLIENT_ID:-}" ]]; then
          gap "Google ответил лимитом (${rc_err#*: }) — это ОБЩИЙ ключ rclone, падения повторятся" \
              "заведи свой ключ (шаги 1-4 выше) и перезапиши секцию gdrive в ~/.config/rclone/rclone.conf"
        else
          warn "Google ответил лимитом (${rc_err#*: }) — токен записан, копия уедет ночью; проверить: rclone lsd gdrive:"
        fi
      else
        warn "Drive не подключился: ${rc_err} — проверь строку токена: rclone config create gdrive drive token '<строка>'"
      fi
      rm -f "$TOKFILE"
    else
      gap "off-site пропущен: копия лежит на этом же сервере и умрёт вместе с ним" \
        "повторить установку с подключением Drive либо настроить rclone вручную"
    fi
  else
    gap "off-site НЕ настроен: копия лежит на этом же сервере и умрёт вместе с ним."
    cat <<EOF

    Подключить Google Drive (10 минут; вход в гугл требует браузера, а на сервере
    его нет — поэтому вход делается на СВОЁМ компьютере, НЕ внутри ssh).

    СНАЧАЛА свой ключ Google — без него rclone ходит под общим ключом, одним на
    всех в мире, и в часы пик бэкап падает с «квота превышена». Бесплатно, карта
    не нужна:
      1) console.cloud.google.com под тем гуглом, где будет лежать бэкап →
         создай проект (имя любое, например dashi-backups)
      2) «APIs & Services» → «Library» → «Google Drive API» → Enable
      3) «APIs & Services» → «OAuth consent screen» → тип External →
         заполни обязательные поля → «Audience» → «Test users» → «+ Add users»:
         ТОТ адрес, которым войдёшь (иначе «Ошибка 403: access_denied»)
         и там же «Publish app» → «Confirm» (иначе через 7 дней Google гасит
         вход и копии молча перестают уезжать в облако)
      4) «APIs & Services» → «Credentials» → «Create credentials» →
         «OAuth client ID» → «Desktop app» → скопируй Client ID и Client secret

    ПОТОМ вход:
      5) на своём компьютере поставь rclone (brew не нужен). mac — по одной:
           cd ~/Downloads
           A=\$(uname -m | sed s/x86_64/amd64/)
           curl -fsSLO https://downloads.rclone.org/rclone-current-osx-\$A.zip
           unzip -o rclone-current-osx-\$A.zip
           cd rclone-*-osx-\$A
         windows — zip с rclone.org/downloads, распакуй, PowerShell в папке,
         пиши .\\rclone.exe вместо ./rclone
      6) там же выполни, подставив свои значения из шага 4:
         ./rclone authorize "drive" ВАШ_ID ВАШ_SECRET   (ID и SECRET через пробел, без флагов)
      7) он напечатает строку вида {"access_token":...} — скопируй её целиком
      8) на СЕРВЕРЕ создай конфиг СО СВОИМ ключом (одной командой):
           sudo -u $SERVICE_USER rclone config create gdrive drive \
             client_id ВАШ_ID client_secret ВАШ_SECRET token '<строка>'
      9) проверь: sudo -u $SERVICE_USER rclone lsd gdrive:
    Дальше ночной бэкап сам начнёт уезжать в облако.

EOF
  fi
else
  skip "бэкап пропущен по выбору пользователя"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. Вход в Claude — годовой токен, чтобы не перелогиниваться раз в месяц
# ─────────────────────────────────────────────────────────────────────────────
# Обычный вход по ссылке живёт ~30 дней (refresh-токен) и протухает молча.
# `claude setup-token` тем же жестом (ссылка в браузер + код) выдаёт токен на
# ГОД; кладём его в channel.env — systemd передаёт его Claude через окружение
# (CLAUDE_CODE_OAUTH_TOKEN), и диалога логина просто нет.
logged_in()  { as_agent 'test -s ~/.claude/.credentials.json' 2>/dev/null; }
have_token() { grep -q '^CLAUDE_CODE_OAUTH_TOKEN=sk-ant-' "$ENV_FILE" 2>/dev/null; }
TOKEN_WRITTEN=0
# Токен на экране pty переносится на две строки, и вставляют его тоже двумя —
# поэтому склеиваем всё, что похоже на пробел, ПЕРЕД проверкой (27.08.2026:
# установка встала на «это не похоже на токен», хотя токен был верный).
strip_ws() { printf '%s' "${1//[[:space:]]/}"; }

# Выкусываем токен из лога экрана: сначала блок между «valid for 1 year» и
# «Store this token», потом снимаем цветовые коды, потом склеиваем переносы,
# потом отрезаем прилипший хвост. Токен на экране ПОКРАШЕН: на переносе строки
# внутрь попадала ESC-последовательность, длинный кусок распадался на два
# коротких, порог {80,} не срабатывал — и экстрактор молча сдавался, вываливая
# человека в ручной ввод (живая установка 06.09.2026).
extract_token() {
  sed -n '/valid for .*year/,/Store this token/p' "$1" 2>/dev/null \
    | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | tr -d ' \r\n' | sed 's/Storethis.*$//' \
    | grep -aoE 'sk-ant-[A-Za-z0-9_-]{80,}' | tail -1
}

write_token() {
  set -- "$(strip_ws "$1")"
  # Настоящий токен ~101 знак после sk-ant-; порог ниже реального ловит обрезок
  # (pty перенёс строку посреди токена — сервис бы молча не завёлся), но с запасом
  [[ "$1" =~ ^sk-ant-[A-Za-z0-9_-]{80,}$ ]] || die "это не похоже на токен Claude (жду sk-ant-oat01-..., целиком)"
  if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^CLAUDE_CODE_OAUTH_TOKEN=.*#CLAUDE_CODE_OAUTH_TOKEN=$1#" "$ENV_FILE"
  else
    echo "CLAUDE_CODE_OAUTH_TOKEN=$1" >> "$ENV_FILE"
  fi
  TOKEN_WRITTEN=1
  ok "годовой токен записан в $ENV_FILE"
}

say "Вход в Claude (годовой токен)"
if [[ -n "$CLAUDE_TOKEN" ]]; then
  write_token "$CLAUDE_TOKEN"
elif have_token; then
  skip "годовой токен уже в конфиге"
elif logged_in; then
  gap "вход обычный — протухнет примерно через 30 дней, и агент встанет молча" \
      "su - $SERVICE_USER -c 'claude setup-token', затем прогон с --claude-token TOKEN"
elif ! have_tty; then
  cat <<EOF

──────────────────────────────────────────────────────────────
  Остался вход в Claude (терминала нет, сам не проведу).

  1) su - $SERVICE_USER -c 'claude setup-token'
  2) открой ссылку в браузере, войди, вставь код обратно
  3) скопируй напечатанный токен (sk-ant-oat01-...)
  4) снова: sudo bash $0 --name $AGENT_NAME --claude-token ТОКЕН

  Четвёртый пункт доделает остальное — повторный запуск ничего не сломает.
──────────────────────────────────────────────────────────────
EOF
  exit 0
else
  cat <<EOF

  Сейчас проведу вход в Claude (нужна подписка Pro/Max):
    1) на экране появится ссылка — открой её в браузере на любом устройстве
    2) войди в свой аккаунт Claude и разреши доступ
    3) скопируй код со страницы и вставь обратно в этот терминал
  Токен получается сразу на год — перелогиниваться раз в месяц не придётся.

EOF
  TOKEN_LOG="$(mktemp)"; chmod 600 "$TOKEN_LOG"
  trap 'rm -f "${TOKEN_LOG:-}"' INT TERM EXIT   # в логе экрана лежит токен — не оставлять в /tmp
  # script(1) даёт setup-token настоящий TTY и параллельно пишет экран в файл —
  # оттуда сами выловим напечатанный токен, чтобы человек его не копировал.
  script -qec "su - $SERVICE_USER -c 'claude setup-token'" "$TOKEN_LOG" </dev/tty >/dev/tty 2>&1 || true
  CLAUDE_TOKEN="$(extract_token "$TOKEN_LOG" || true)"
  rm -f "$TOKEN_LOG"; trap - INT TERM EXIT
  if [[ -n "$CLAUDE_TOKEN" ]]; then
    # Выловили сами — стираем экран И прокрутку: годовой токен на виду уезжал в
    # скриншоты и демонстрацию экрана (живая установка 02.10.2026).
    { printf '\033[H\033[2J\033[3J' >/dev/tty; } 2>/dev/null || true
    ok "токен Claude выловлен и стёрт с экрана — скриншотить можно"
  fi
  if [[ -z "$CLAUDE_TOKEN" ]]; then
    warn "не смог выловить токен с экрана"
    # Токен печатается в ДВЕ строки — вставка второй улетала в shell, а первая
    # (обрезок) роняла установку. Собираем построчно, пока не наберётся целый.
    warn "он напечатан выше в ДВЕ строки — вставь обе, каждую с Enter"
    CLAUDE_TOKEN=""
    for _ in 1 2 3 4; do
      ask TOKEN_PART "Вставь токен (или его очередной кусок), Enter: "
      CLAUDE_TOKEN="$(strip_ws "$CLAUDE_TOKEN$TOKEN_PART")"
      # Первым куском вставляют что угодно — чаще всего код авторизации со
      # страницы. Без сброса он отравлял накопитель НАВСЕГДА: токен дописывался
      # к мусору, проверка не совпадала ни разу, все четыре попытки сгорали
      # впустую (живая установка 06.09.2026). Держим хвост от последнего sk-ant-.
      [[ "$CLAUDE_TOKEN" == *sk-ant-* ]] && CLAUDE_TOKEN="sk-ant-${CLAUDE_TOKEN##*sk-ant-}"
      [[ "$CLAUDE_TOKEN" =~ ^sk-ant-[A-Za-z0-9_-]{80,}$ ]] && break
    done
  fi
  write_token "$CLAUDE_TOKEN"
fi

# Без пройденного онбординга интерактивный Claude рисует «Select login method»
# даже при валидном токене в окружении (проверено живым e2e на v2.1.245) —
# помечаем онбординг пройденным, входа по ссылке всё равно не будет
# Смотрим на САМ ФЛАГ, а не на наличие файла: от прошлой попытки мог остаться
# ~/.claude.json без него — и выбор логина рисовался снова (27.08.2026).
as_agent 'grep -qs hasCompletedOnboarding ~/.claude.json' \
  || as_agent 'cp -f ~/.claude.json ~/.claude.json.bak 2>/dev/null; printf "%s" "{\"hasCompletedOnboarding\": true, \"theme\": \"dark\"}" > ~/.claude.json'

# ─────────────────────────────────────────────────────────────────────────────
# 5c. Superpowers (навыки: планирование, отладка, ревью)
# ─────────────────────────────────────────────────────────────────────────────
say "Superpowers"
if as_agent 'test -d ~/.claude/plugins/marketplaces/superpowers-dev'; then
  skip "superpowers на месте"
elif as_agent "set -a; . '$ENV_FILE' 2>/dev/null; set +a;
               claude plugin marketplace add obra/superpowers >/dev/null 2>&1 &&
               claude plugin install superpowers@superpowers-dev >/dev/null 2>&1"; then
  ok "superpowers установлены"
else
  # Не критично: агент работает и без них, поэтому не роняем всю установку
  printf '    \033[33m!\033[0m superpowers не встали — поставь потом вручную:\n'
  printf '      claude plugin marketplace add obra/superpowers\n'
  printf '      claude plugin install superpowers@superpowers-dev\n'
fi


# ─────────────────────────────────────────────────────────────────────────────
# 5d. Семантическая память OpenViking (опция: --openai-key)
# ─────────────────────────────────────────────────────────────────────────────
# Файловая память (MEMORY.md) ищет по словам; OpenViking — по смыслу, по всей
# истории разговоров. Сервер — docker-контейнер (~400 МБ RAM, host-network,
# 127.0.0.1:1933). Эмбеддинги по умолчанию СВОИ, локальной моделью на машине
# агента (agent-kit/scripts/setup-memory.sh) — ключ OpenAI не нужен и нужен
# только как запасной путь, если локальная модель не помещается в память.
# Entrypoint образа биндит 0.0.0.0, если не сказать иначе (OPENVIKING_SERVER_HOST) —
# с host-network это открыло бы память наружу; dev-auth сам отказывается так стартовать.
# ponytail: один агент на машину — порт 1933 зашит; второй агент на том же
# хосте переиспользует тот же контейнер (запись идёт под своим agentId).
say "Память OpenViking"
OV_DIR="/home/$SERVICE_USER/.openviking"
if [[ -z "$OPENAI_KEY" && ! -s "$OV_DIR/ov.conf" ]]; then
  # Ключа нет -- это не повод оставлять агента без памяти. В комплекте лежит
  # второй путь: эмбеддинги локальной моделью, пересказы на ключе, который уже
  # есть на этой машине. 20.09.2026 Смит встал без памяти именно потому, что
  # установщик знал только про OpenAI и молча пропускал шаг.
  KIT_MEM="/home/$SERVICE_USER/.claude-lab/$AGENT_NAME/.claude/dashi-plugin-claude-code/agent-kit/scripts/setup-memory.sh"
  if [[ -x "$KIT_MEM" || -f "$KIT_MEM" ]]; then
    # Вывод в лог, а не в /dev/null: именно молчание этого шага сделало провал
    # памяти на Смите (20.09) неразбираемым.
    MEM_LOG="/home/$SERVICE_USER/.claude-lab/$AGENT_NAME/logs/setup-memory.log"
    mkdir -p "$(dirname "$MEM_LOG")"
    if bash "$KIT_MEM" --workspace "/home/$SERVICE_USER/.claude-lab/$AGENT_NAME" --agent "$AGENT_NAME" >"$MEM_LOG" 2>&1 \
       && curl -sf -m 5 http://127.0.0.1:1933/health >/dev/null 2>&1; then
      ok "память на локальных эмбеддингах (ключ OpenAI не нужен)"
    else
      skip "память не поднялась локально ($MEM_LOG) -- прогон с --openai-key KEY поставит её на OpenAI"
    fi
  else
    skip "без семантической памяти (повторный прогон с --openai-key KEY включит)"
  fi
else
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y -qq docker.io >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 \
      || die "docker не встал — поставь руками (apt install docker.io) и повтори"
    ok "docker установлен"
  fi
  as_agent "mkdir -p '$OV_DIR/claude-code-memory-plugin'"
  if [[ -n "$OPENAI_KEY" ]]; then
    # Ключ только в этом файле (600, владелец — агент). Повторный прогон с ключом
    # перезаписывает его (смена ключа), без ключа — оставляет как есть.
    # Была локальная память -- вектора другой размерности (384 против 1536), со
    # старой базой новая модель не сработает. Запоминаем, чтобы пересчитать ниже.
    OV_OLD_DIM="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["embedding"]["dense"].get("dimension",""))' "$OV_DIR/ov.conf" 2>/dev/null || true)"
    cat > "$OV_DIR/ov.conf" <<EOF
{
  "server": { "host": "127.0.0.1", "port": 1933 },
  "embedding": {
    "dense": {
      "provider": "openai", "api_base": "https://api.openai.com/v1",
      "api_key": "$OPENAI_KEY", "model": "text-embedding-3-small", "dimension": 1536
    }
  },
  "vlm": {
    "provider": "openai", "api_base": "https://api.openai.com/v1",
    "api_key": "$OPENAI_KEY", "model": "gpt-4o-mini", "max_tokens": 16000
  }
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$OV_DIR/ov.conf"; chmod 600 "$OV_DIR/ov.conf"
    ok "ov.conf записан"
    # max_tokens: OpenViking 0.4.20 по умолчанию просит 32768, gpt-4o-mini даёт не
    # больше 16384 -- без потолка память молча ничего не сохраняла (Смит, 26.09.2026).
    if [[ -n "$OV_OLD_DIM" && "$OV_OLD_DIM" != 1536 && -d "$OV_DIR/appdata/vectordb" ]]; then
      docker stop openviking >/dev/null 2>&1 || true
      mv "$OV_DIR/appdata/vectordb" "$OV_DIR/appdata/vectordb.local-$(date +%F)"
      OV_REINDEX=1
      ok "старая база векторов (локальная модель) отложена -- пересчитаю по ключу"
    fi
  fi
  if [[ ! -s "$OV_DIR/claude-code-memory-plugin/config.json" ]]; then
    cat > "$OV_DIR/claude-code-memory-plugin/config.json" <<EOF
{
  "mode": "local",
  "agentId": "$AGENT_NAME",
  "recallLimit": 3,
  "scoreThreshold": 0.25,
  "captureMode": "semantic",
  "captureTimeoutMs": 30000,
  "captureAssistantTurns": false
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$OV_DIR/claude-code-memory-plugin/config.json"
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx openviking; then
    docker start openviking >/dev/null 2>&1 || true
    skip "контейнер openviking на месте"
  else
    # appdata -> /app/data обязательно: без него вся память живёт внутри
    # контейнера и пропадает при его пересоздании (обновление образа). Так же
    # монтирует agent-kit/scripts/setup-memory.sh и контейнер у Jarvis.
    as_agent "mkdir -p '$OV_DIR/appdata'"
    docker run -d --name openviking --network host --restart unless-stopped \
      -v "$OV_DIR:/app/.openviking" -v "$OV_DIR/appdata:/app/data" \
      -e OPENVIKING_CONFIG_FILE=/app/.openviking/ov.conf \
      -e OPENVIKING_SERVER_HOST=127.0.0.1 \
      "$OPENVIKING_IMAGE" >/dev/null 2>&1 || die "контейнер openviking не запустился (docker logs openviking)"
    ok "контейнер openviking запущен"
  fi
  for _ in $(seq 1 45); do
    curl -s -o /dev/null http://127.0.0.1:1933/ 2>/dev/null && break; sleep 2
  done
  if [[ "${OV_REINDEX:-0}" == 1 ]]; then
    # Память лежит файлами, вектора -- производная: пересчитываем их новой моделью.
    for u in viking://user viking://resources; do
      curl -s -m 600 -X POST http://127.0.0.1:1933/api/v1/content/reindex \
        -H 'Content-Type: application/json' -d "{\"uri\":\"$u\",\"mode\":\"vectors_only\"}" >/dev/null 2>&1 || true
    done
    ok "память пересчитана под ключ OpenAI"
  fi
  if [[ -n "$OPENAI_KEY" && -f /etc/systemd/system/dashi-embed.service ]]; then
    # Память переехала на ключ -- локальная модель больше не нужна, а держала
    # ~0.7 ГБ: на 4 ГБ без подкачки агента Гора за двое суток 4 раза прибило
    # по памяти (03.10.2026). Юнит уносим из systemd целиком: health-check
    # узнаёт службу по файлу и иначе кричал бы «служба эмбеддингов лежит».
    systemctl disable --now -q dashi-embed 2>/dev/null || true
    mv /etc/systemd/system/dashi-embed.service "/root/dashi-embed.service.retired-$(date +%F)"
    systemctl daemon-reload
    ok "локальная модель памяти выключена -- оперативка освобождена"
  fi
  curl -s -o /dev/null http://127.0.0.1:1933/ 2>/dev/null && ok "сервер памяти отвечает на 1933" \
    || warn "сервер памяти не ответил за 90 сек — смотри docker logs openviking; плагин подхватит, когда поднимется"
  # Плагин Claude Code: env в settings.json + marketplace + install (всё под агентом)
  as_agent "jq --arg a '$OV_DIR/ov.conf' --arg b '$OV_DIR/claude-code-memory-plugin/config.json' \
    '.env.OPENVIKING_CONFIG_FILE=\$a | .env.OPENVIKING_CC_CONFIG_FILE=\$b
     | .extraKnownMarketplaces[\"openviking-plugin\"]={source:{source:\"github\",repo:\"Castor6/openviking-plugins\"}}' \
    ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json" \
    || die "не смог прописать OpenViking в settings.json"
  if as_agent 'test -d ~/.claude/plugins/marketplaces/openviking-plugin'; then
    skip "плагин памяти на месте"
  elif as_agent 'claude plugin marketplace add Castor6/openviking-plugins >/dev/null 2>&1 &&
                 claude plugin install claude-code-memory-plugin@openviking-plugin >/dev/null 2>&1'; then
    ok "плагин памяти установлен (вспоминает при каждом сообщении, запоминает сам)"
  else
    warn "плагин памяти не встал — потом руками: claude plugin marketplace add Castor6/openviking-plugins && claude plugin install claude-code-memory-plugin@openviking-plugin"
  fi
  # Свои хуки вместо плагинных auto-capture/auto-recall (21.08.2026). Плагин писал в
  # память каждое сообщение как есть, с телеграм-обёрткой (chat_id, message_id), и
  # искал сырым промптом — всё было похоже на всё, попадание ~1 из 3, подсказки
  # сыпались даже на «ок». Хуки из scripts/memory/: Stop кладёт выжимку хода
  # (чистый вопрос + ответ, который оператор реально видел), UserPromptSubmit ищет
  # по очищенному вопросу с порогом и молчит на пустяках. MCP-тулы memory_recall /
  # memory_store плагина остаются. Хуки читаются из репо — обновляются вместе с ним.
  as_agent "jq '.autoRecall=false | .autoCapture=false' '$OV_DIR/claude-code-memory-plugin/config.json' \
    > '$OV_DIR/claude-code-memory-plugin/config.json.new' \
    && mv '$OV_DIR/claude-code-memory-plugin/config.json.new' '$OV_DIR/claude-code-memory-plugin/config.json'" \
    || warn "не смог выключить плагинный auto-capture/auto-recall — хуки будут дублировать подсказки"
  OV_HOOKS="$REPO_DIR/scripts/memory"
  as_agent "jq --arg r '$OV_HOOKS/ov-recall.py' --arg c '$OV_HOOKS/ov-digest-capture.py' '
      def add(ev; cmd; t): .hooks[ev] = ((.hooks[ev] // [])
        | if any(.[]; .hooks[]?.command == cmd) then .
          else . + [{matcher: \"\", hooks: [{type: \"command\", command: cmd, timeout: t}]}] end);
      add(\"UserPromptSubmit\"; \$r; 8) | add(\"Stop\"; \$c; 10)' \
    ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json" \
    && ok "хуки памяти прописаны (чистая запись + подсказки с порогом)" \
    || die "не смог прописать хуки памяти в settings.json"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 10. Поднимаем
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# 9b. Ремонтник — бот-страховка на случай «агент лёг и молчит» (опция)
# ─────────────────────────────────────────────────────────────────────────────
# Отдельный простой бот (pip claude-code-telegram) со СВОИМ токеном BotFather:
# живёт отдельным процессом вне tmux-моста, поэтому переживает смерть агента.
# Через него хозяин руками чинит сервер: «перезапусти агента», «покажи логи».
# Права — те же, что у агента (sudo только на dashi-ctl-<имя>). Списан с живого
# Томми/Richard (/opt/richard, claude-richard.service).
say "Ремонтник (бот-страховка)"
[[ -z "$REPAIR_TOKEN" || "$REPAIR_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
  || die "--repair-token не похож на токен бота (жду 123456:AA...)"
if [[ -n "$REPAIR_TOKEN" && "$REPAIR_TOKEN" == "$BOT_TOKEN" ]]; then
  die "ремонтнику нужен СВОЙ бот — два процесса на одном токене дерутся за поллинг"
fi
R_DIR="/opt/repair-$AGENT_NAME"
R_UNIT="claude-repair-$AGENT_NAME"
# Спрашиваем токен прямо тут. Раньше ремонтник ставился ТОЛЬКО флагом
# --repair-token: хозяин с готовым токеном на руках доходил до конца установки
# и уезжал без ремонтника, ничего об этом не узнав (Саня 27.08.2026).
if [[ -z "$REPAIR_TOKEN" && ! -s "$R_DIR/.env" && $ASSUME_YES -eq 0 ]]; then
  echo "    Ремонтник — ВТОРОЙ бот (@BotFather → /newbot). Чинит агента, когда тот молчит."
  ask REPAIR_TOKEN "    Токен бота-ремонтника (Enter — пропустить): " 0
  # На повторном прогоне основной токен не спрашивали — достаём из конфига,
  # иначе проверку «свой бот» нечем сделать и оба процесса подерутся за поллинг.
  [[ -n "$BOT_TOKEN" || ! -f "$ENV_FILE" ]] \
    || BOT_TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -1)"
  # Проверки выше уже отработали (флаг был пуст) — повторяем их для введённого руками
  [[ -z "$REPAIR_TOKEN" || "$REPAIR_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
    || die "токен ремонтника не похож на настоящий (жду 123456:AA...)"
  [[ -z "$REPAIR_TOKEN" || "$REPAIR_TOKEN" != "$BOT_TOKEN" ]] \
    || die "ремонтнику нужен СВОЙ бот — два процесса на одном токене дерутся за поллинг"
fi
if [[ -z "$REPAIR_TOKEN" && ! -s "$R_DIR/.env" ]]; then
  skip "без ремонтника (повторный прогон с --repair-token TOKEN включит; токен = ещё один /newbot)"
else
  if [[ ! -x "$R_DIR/venv/bin/claude-telegram-bot" ]]; then
    apt-get install -y -qq git >/dev/null 2>&1 || true
    # Пакет живёт на GitHub (не в PyPI) и требует Python >=3.11, а на Ubuntu 22.04
    # системный 3.10 — uv приносит свой CPython и не трогает системный
    command -v uv >/dev/null 2>&1 \
      || curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null 2>&1 \
      || die "не встал uv — проверь сеть и повтори"
    # Коммит запинен: ровно тот, что месяцами работает у живого Томми/Richard.
    # UV_PYTHON_INSTALL_DIR обязателен: без него uv (мы под root) кладёт CPython
    # в /root (0700), venv-симлинк туда — и сервис под agent умирает с EACCES
    export UV_PYTHON_INSTALL_DIR="$R_DIR/python"
    uv venv "$R_DIR/venv" --python 3.12 >/dev/null 2>&1 \
      && uv pip install --python "$R_DIR/venv/bin/python" -q \
           'git+https://github.com/RichardAtCT/claude-code-telegram@4c63df52c5767f03c5031f8f9f956485a4d9eda5' \
      || die "не встал claude-code-telegram — проверь сеть и повтори"
  fi
  # httpx логирует ПОЛНЫЙ url запроса на INFO, а Telegram держит токен бота прямо
  # в пути url — токен ремонтника уходил в системный журнал открытым текстом
  # каждые 10 секунд (Саня, 28.08.2026). Гасим болтовню транспорта, логи бота живы.
  R_MAIN="$(ls -d "$R_DIR"/venv/lib/python3.*/site-packages/src/main.py 2>/dev/null | head -1)"
  if [[ -n "$R_MAIN" ]] && ! grep -q _noisy "$R_MAIN"; then
    python3 -c 'import sys,pathlib;p=pathlib.Path(sys.argv[1]);s=p.read_text();a="        stream=sys.stdout,\n    )\n";x=a+"\n    for _noisy in (\"httpx\",\"httpcore\"):\n        logging.getLogger(_noisy).setLevel(logging.WARNING)\n";p.write_text(s.replace(a,x,1)) if a in s else None' "$R_MAIN" \
      && ok "ремонтник не пишет свой токен в системный журнал"
  fi
  R_CLI="$(command -v claude)" || die "не нашёл claude в PATH -- ремонтнику нужен общий бинарь"
  if [[ -n "$REPAIR_TOKEN" ]]; then
    # URL с токеном — через --config со stdin, чтобы токен не светился в ps
    R_USERNAME="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$REPAIR_TOKEN" \
      | curl -sm 10 --config - \
      | grep -o '"username":"[^"]*"' | cut -d'"' -f4 || true)"
    # Годовой токен Claude — тот же, что у агента: ремонтник тоже говорит с Claude
    R_CLAUDE_TOKEN="$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$ENV_FILE" | head -1)"
    cat > "$R_DIR/.env" <<EOF
# Ремонтник $AGENT_NAME — создан install-agent.sh (образец: Richard v3)
TELEGRAM_BOT_TOKEN=$REPAIR_TOKEN
TELEGRAM_BOT_USERNAME=$R_USERNAME
USE_SDK=true
CLAUDE_CLI_PATH=$R_CLI
ALLOWED_USERS=$USER_ID
APPROVED_DIRECTORY=/home/$SERVICE_USER
CLAUDE_CODE_OAUTH_TOKEN=$R_CLAUDE_TOKEN
ENVIRONMENT=production
DEVELOPMENT_MODE=false
DISABLE_TOOL_VALIDATION=false
ENABLE_MCP=false
CLAUDE_ALLOWED_TOOLS=Read,Write,Edit,Bash,Glob,Grep,LS,Task,WebFetch,WebSearch
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$R_DIR/.env"; chmod 600 "$R_DIR/.env"
  fi
  # Пустой CLAUDE_CLI_PATH = SDK берёт СВОЙ встроенный claude, замороженный на версии
  # пакета и никогда не обновляемый. 23.09.2026 Томми так встал на 2.1.117 и на новой
  # модели отвечал «400 claude_code_version_too_old». Ремонтник обязан ходить через
  # тот же claude, что и агент (его обновляет `update-claude`). Чиним и старые .env.
  if [[ -f "$R_DIR/.env" ]] && grep -q '^CLAUDE_CLI_PATH=$' "$R_DIR/.env"; then
    sed -i "s#^CLAUDE_CLI_PATH=\$#CLAUDE_CLI_PATH=$R_CLI#" "$R_DIR/.env"
    ok "ремонтник ходит через общий claude ($R_CLI), а не встроенную копию"
  fi
  chown -R "$SERVICE_USER:$SERVICE_USER" "$R_DIR"
  cat > "/etc/systemd/system/$R_UNIT.service" <<EOF
[Unit]
Description=Repair bot for $AGENT_NAME (safety net, claude-code-telegram)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$R_DIR
EnvironmentFile=$R_DIR/.env
Environment=HOME=$HOME_DIR
Environment=PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$R_DIR/venv/bin/claude-telegram-bot
Restart=on-failure
RestartSec=10
SyslogIdentifier=$R_UNIT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  # restart, не enable --now: на повторном прогоне живой ремонтник иначе не перечитает .env
  systemctl enable "$R_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$R_UNIT" >/dev/null 2>&1 || true
  systemctl is-active --quiet "$R_UNIT" \
    && ok "ремонтник поднят (юнит $R_UNIT)" \
    || warn "ремонтник не стартовал — journalctl -u $R_UNIT -n 30"
fi

say "Запуск"
# Токен только что записан, а сервис уже крутился — перезапуск, чтобы Claude
# подхватил CLAUDE_CODE_OAUTH_TOKEN из окружения
# Перезапускаем ВСЕГДА, а не только при новом токене: хуки и плагин читаются
# один раз при старте сессии, и повторный прогон «всё сделал», но живой агент
# продолжал крутиться со старыми хуками — карточка прогресса так и оставалась
# пустой (Саня 27.08.2026).
if systemctl is-active --quiet "$UNIT"; then
  warn "агент $AGENT_NAME сейчас работает — перезапускаю, чтобы он подхватил новые хуки и плагин:"
  warn "связь моргнёт, текущий ход агента (если он что-то делал) оборвётся; после старта он снова на связи"
fi
systemctl stop "$UNIT" >/dev/null 2>&1 || true
# stop возвращается раньше, чем Claude внутри tmux допишет ~/.claude.json при выходе —
# ждём, пока процесс claude агента исчезнет (до 20 с), иначе регистрация ниже стирается.
for _ in $(seq 1 20); do pgrep -u "$SERVICE_USER" -x claude >/dev/null 2>&1 || break; sleep 1; done
sleep 1
# Регистрация моста — ТОЛЬКО при остановленном агенте: живой Claude при выходе переписывает
# ~/.claude.json своей копией и стирает всё, что дописали снаружи (Смит 02.09, второй прогон).
# 02.09.2026, живой прогон на Смите: Claude Code 2.1.258 молча НЕ читал plugin/.mcp.json —
# Claude работал, а мост в Telegram не стартовал («No MCP servers configured»). Регистрируем
# мост на уровне пользователя: не зависит от доверия к папке и одобрения проектных серверов.
# Не проверять через `claude mcp get`: он видит запись из plugin/.mcp.json и отвечает «есть»,
# хотя в user-scope пусто — регистрация молча пропускалась (Смит 02.09, три прогона подряд).
# Всегда снять и поставить заново — идемпотентно.
if as_agent "cd '$PLUGIN_DIR' && { claude mcp remove -s user dashi-channel >/dev/null 2>&1 || true; } && claude mcp add -s user dashi-channel -- bun ./src/server.ts >/dev/null 2>&1"; then
  ok "мост dashi-channel зарегистрирован в Claude (user-scope)"
else
  warn "не смог зарегистрировать мост: su - $SERVICE_USER -c 'cd $PLUGIN_DIR && claude mcp add -s user dashi-channel -- bun ./src/server.ts'"
fi
# Рабочие группы: владелец + люди + агент. Бот по умолчанию видит в группе только
# сообщения с упоминанием (Telegram privacy mode). Этого хватает, чтобы к агенту
# обращались через @имя_бота, но без упоминания он глух -- и это ловится только
# живьём. Спрашиваем Telegram напрямую: getMe.can_read_all_group_messages.
say "Рабочие группы"
BOT_NAME="$(curl -s -m 20 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')"
if curl -s -m 20 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | grep -q '"can_read_all_group_messages":true'; then
  ok "бот читает все сообщения группы — в группе он отвечает и на упоминания, и на обращения по смыслу"
else
  cat <<EOF

    Для работы в группе бота НАДО сделать администратором группы.
    Сейчас он в «режиме приватности» Telegram: в группе почти ничего не
    получает, даже @${BOT_NAME:-имя_бота} (в списке участников у него
    «не имеет доступа к сообщениям»). Порядок:
      1) добавь бота в группу и назначь администратором (права можно снять)
         либо @BotFather → /setprivacy → выбери бота → Disable,
         потом удали бота из группы и добавь заново
      2) первым напиши в группе сам: @${BOT_NAME:-имя_бота} привет

EOF
  # НЕ gap: без групп агент полностью рабочий, а «НЕ ЗАКРЫТО» владелец читал
  # как поломку (Саня 11.09.2026). Но и «отвечает на @ сразу» было неправдой:
  # 02.10.2026 у живого агента в privacy mode Telegram не отдал ни одного
  # @упоминания из группы (offset бота не сдвинулся); лечение -- админ группы.
  warn "в группах бот заработает, когда станет админом группы — см. выше"
fi

systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
sleep 8

if systemctl is-active --quiet "$UNIT"; then
  cat <<EOF

  ✓ Готово. Агент $AGENT_NAME поднят и стартует сам после перезагрузки.

  Напиши своему боту в Telegram — он ответит.
$(if ((${#GAPS[@]})); then
    printf '\n  НЕ ЗАКРЫТО (%d) — установка прошла, но вот это работать не будет:\n' "${#GAPS[@]}"
    for g in "${GAPS[@]}"; do printf '    · %s\n' "$g"; done
  fi)
  Не ответил:  journalctl -u $UNIT -n 50 --no-pager
               su - $SERVICE_USER -c 'tmux attach -t channel-$AGENT_NAME'
  Перезапуск:  systemctl restart $UNIT

EOF
else
  die "сервис не поднялся. Смотри: journalctl -u $UNIT -n 50 --no-pager"
fi
