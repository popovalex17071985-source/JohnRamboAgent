#!/usr/bin/env bash
# install-codex.sh — разворачивает Codex-агента в Telegram на чистом сервере
# одной командой. Аналог install-agent.sh, но для Codex (подписка ChatGPT).
#
# Заменяет ручные части 2–8 из artifacts/codex-agent-guide-vps.md. Скрипт
# идемпотентный: гоняй сколько угодно раз, он доделывает недостающее и не
# трогает готовое. Прерваться на входе в ChatGPT — нормально, запусти снова.
#
# Что человек делает сам (автоматизировать нельзя):
#   1. арендует VPS и заходит на него root'ом
#   2. заводит ДВУХ ботов у @BotFather и узнаёт свой id у @userinfobot
#   3. логинится в ChatGPT по ссылке (codex login) — скрипт остановится и скажет как
#   4. правит характер агента в ~/.codex/AGENTS.md (шаблон скрипт положит сам)
#
# Использование:
#   bash install-codex.sh                 # спросит всё интерактивно
#   bash install-codex.sh --token 123:AA... --watchdog-token 456:BB... --chat-id 140141496
#   ... --openai-key sk-...   # память по смыслу через OpenAI: не ест оперативку сервера
#
set -euo pipefail

MAIN_DIR=/root/agent-main
WATCH_DIR=/root/agent-watchdog
CODEX_HOME=/root/.codex

BOT_TOKEN=""; WATCH_TOKEN=""; CHAT_ID=""; GROQ_KEY=""; OPENAI_KEY=""; ASSUME_YES=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m· %s (уже сделано)\033[0m\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)          BOT_TOKEN="$2";   shift 2 ;;
    --watchdog-token) WATCH_TOKEN="$2"; shift 2 ;;
    --chat-id)        CHAT_ID="$2";     shift 2 ;;
    --groq-key)       GROQ_KEY="$2";    shift 2 ;;
    --openai-key)     OPENAI_KEY="$2";  shift 2 ;;
    --yes|-y)         ASSUME_YES=1;     shift ;;
    --help|-h)        usage ;;
    *) die "неизвестный аргумент: $1 (--help для справки)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0"

ask() {  # ask VAR "приглашение"
  local __var="$1" __prompt="$2" __val=""
  while :; do
    read -r -p "$__prompt" __val </dev/tty || true
    [[ -n "$__val" ]] && break
    echo "    поле обязательное"
  done
  printf -v "$__var" '%s' "$__val"
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Секреты: спрашиваем только то, чего ещё нет
# ─────────────────────────────────────────────────────────────────────────────
say "Секреты"
if [[ ! -f "$MAIN_DIR/.env" ]]; then
  [[ -n "$BOT_TOKEN" ]] || ask BOT_TOKEN "Токен ОСНОВНОГО бота от @BotFather: "
  [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен не похож на настоящий (ожидаю 123456:AA...)"
fi
if [[ ! -f "$WATCH_DIR/.env" ]]; then
  [[ -n "$WATCH_TOKEN" ]] || ask WATCH_TOKEN "Токен бота-РЕМОНТНИКА от @BotFather: "
  [[ "$WATCH_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен ремонтника не похож на настоящий"
fi
if [[ ! -f "$MAIN_DIR/.env" || ! -f "$WATCH_DIR/.env" ]]; then
  [[ -n "$CHAT_ID" ]] || ask CHAT_ID "Твой Telegram id от @userinfobot: "
  [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || die "id должен быть числом: $CHAT_ID"
  if [[ -z "$GROQ_KEY" ]]; then
    read -r -p "Ключ Groq для голосовых (Enter — пропустить): " GROQ_KEY </dev/tty || true
  fi
fi
[[ -f "$MAIN_DIR/.env" && -f "$WATCH_DIR/.env" ]] && skip "оба .env на месте"
# Память по смыслу: без ключа локальная модель просит ~2 ГБ оперативки, на
# типичном VPS в 4 ГБ это половина. Спрашиваем один раз, пока настройки нет.
if [[ -z "$OPENAI_KEY" && ! -s "$MAIN_DIR/memsearch.conf" && $ASSUME_YES -eq 0 ]] \
   && ! systemctl is-enabled --quiet codex-embed 2>/dev/null; then
  read -r -p "Ключ OpenAI для памяти по смыслу (Enter — локальная модель, ~2 ГБ оперативки): " OPENAI_KEY </dev/tty || true
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Ставим Codex-агента (основной + ремонтник)? [Y/n] " a </dev/tty || true
  [[ -z "${a:-}" || "$a" =~ ^[YyДд] ]] || die "отменено"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Система: пакеты и своп
# ─────────────────────────────────────────────────────────────────────────────
say "Система"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq nano poppler-utils python3-openpyxl python3-xlrd

# На 1 ГБ памяти Codex упирается в потолок и падает молча.
# Своп дешевле, чем объяснять человеку OOM.
if ! swapon --show --noheadings | grep -q . && [[ "$(free -m | awk '/^Mem:/{print $2}')" -lt 1900 ]]; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "своп 2 ГБ включён"
else
  skip "своп/память в порядке"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Codex CLI
# ─────────────────────────────────────────────────────────────────────────────
say "Codex"
export PATH="$HOME/.local/bin:$PATH"
if command -v codex >/dev/null; then
  skip "codex $(codex --version 2>/dev/null | head -1)"
else
  # Установщик Codex спрашивает «Start Codex now?» — глушим stdin (</dev/null), чтобы он
  # не запускал интерактивный Codex. Скачиваем в файл: при «curl | sh </dev/null» sh
  # читает скрипт из /dev/null вместо трубы, curl падает с (23) и Codex не ставится
  # (25.09.2026, живая установка у Сани).
  _cx=$(mktemp)
  curl -fsSL https://chatgpt.com/codex/install.sh -o "$_cx" && sh "$_cx" </dev/null || true
  rm -f "$_cx"
  command -v codex >/dev/null || die "codex не встал — прогони установку руками: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
  ok "codex $(codex --version 2>/dev/null | head -1)"
fi
CODEX_BIN="$(command -v codex)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Конфиг и характер
# ─────────────────────────────────────────────────────────────────────────────
say "Конфиг Codex"
mkdir -p "$CODEX_HOME"
if [[ -f "$CODEX_HOME/config.toml" ]]; then
  # Старые установки прибивали model = "gpt-5.5" -- на части подписок это 404.
  if grep -q '^model = "gpt-5.5"' "$CODEX_HOME/config.toml"; then
    sed -i '/^model = "gpt-5.5"/d' "$CODEX_HOME/config.toml"
    ok "убрал прибитую модель gpt-5.5 из config.toml"
  fi
  skip "config.toml на месте"
else
  cat > "$CODEX_HOME/config.toml" <<'EOF'
# Модель не задаём: Codex сам берёт ту, что доступна на твоей подписке
# (прибитая gpt-5.5 давала 404 «model does not exist» на части аккаунтов, 25.09.2026)

# "never" = агент не переспрашивает на каждом шаге (нужно для автономной работы)
approval_policy = "never"

# Песочница: агент пишет только в рабочей папке — безопасный режим
sandbox_mode = "workspace-write"
EOF
  ok "config.toml записан"
fi

# Раздел памяти держим свежим и в своей AGENTS.md (характер переписан вручную):
# старый раздел «# Память» вырезаем до следующего заголовка, новый -- в конец.
# Характер не трогаем, бэкап рядом. Метка версии -- строка про history/.
MEMORY_SECTION=$(cat <<'EOF'
# Память
Память у тебя долгая и живёт только в файлах рабочей папки. Между сессиями в голове
ничего не остаётся — есть только то, что записано.
- MEMORY.md — индекс (одна строка на тему) → memory/<тема>.md — факты по темам.
- open-threads.md — открытые задачи: тема, что сделано, на чём остановились, следующий шаг.
- history/ГГГГ-ММ-ДД.md — полный журнал нашей переписки, его пишет мост сам.
Как пользоваться:
- В начале КАЖДОЙ задачи прочитай MEMORY.md и open-threads.md.
- Блок «[Мост: из памяти по смыслу…]» в конце сообщения — найденное в памяти по
  смыслу. Пригодилось — открой указанный файл и опирайся на него; не в тему — игнорируй.
- Я ссылаюсь на прошлое («вернёмся к…», «помнишь…», «мы обсуждали…», незнакомая тема) —
  сначала ищи: rg -i по memory/, open-threads.md и history/ (несколько вариантов слова),
  прочитай найденное и продолжай с того места, где остановились. «Не помню» — только
  после поиска.
- Сохраняй САМ, без команды «запомни»: факты обо мне и моих делах, решения,
  договорённости, как делать задачи → memory/<тема>.md + строка в MEMORY.md.
- Начали, продвинули или закрыли задачу — обнови open-threads.md (закрытое — [x]).
- «Запомнил» пиши ТОЛЬКО после того, как команда записи в файл выполнилась.
- Пароли, токены и ключи в память не пиши.
EOF
)
if [[ -f "$CODEX_HOME/AGENTS.md" ]]; then
  if grep -q "Мост: из памяти по смыслу" "$CODEX_HOME/AGENTS.md"; then
    skip "AGENTS.md на месте (характер не трогаю)"
  else
    cp "$CODEX_HOME/AGENTS.md" "$CODEX_HOME/AGENTS.md.bak-$(date +%Y%m%d%H%M%S)"
    awk '/^# Память$/{skip=1; next} skip && /^# /{skip=0} !skip' "$CODEX_HOME/AGENTS.md" > "$CODEX_HOME/AGENTS.md.new"
    printf '\n%s\n' "$MEMORY_SECTION" >> "$CODEX_HOME/AGENTS.md.new"
    mv "$CODEX_HOME/AGENTS.md.new" "$CODEX_HOME/AGENTS.md"
    ok "AGENTS.md: раздел долгой памяти обновлён (характер не тронут, бэкап рядом)"
  fi
else
  cat > "$CODEX_HOME/AGENTS.md" <<'EOF'
# Кто ты

Ты — мой личный ассистент. Общаешься со мной в Telegram. Я читаю Telegram,
а не терминал — поэтому весь ответ пиши как сообщение в чат.

# Как ты общаешься
- Язык: русский.
- Коротко и по делу, без воды и извинений.
- Сначала — суть или результат, потом пояснения.
- Задача непонятна — задай уточняющий вопрос, не выдумывай.

# Память
Память у тебя долгая и живёт только в файлах рабочей папки. Между сессиями в голове
ничего не остаётся — есть только то, что записано.
- MEMORY.md — индекс (одна строка на тему) → memory/<тема>.md — факты по темам.
- open-threads.md — открытые задачи: тема, что сделано, на чём остановились, следующий шаг.
- history/ГГГГ-ММ-ДД.md — полный журнал нашей переписки, его пишет мост сам.
Как пользоваться:
- В начале КАЖДОЙ задачи прочитай MEMORY.md и open-threads.md.
- Блок «[Мост: из памяти по смыслу…]» в конце сообщения — найденное в памяти по
  смыслу. Пригодилось — открой указанный файл и опирайся на него; не в тему — игнорируй.
- Я ссылаюсь на прошлое («вернёмся к…», «помнишь…», «мы обсуждали…», незнакомая тема) —
  сначала ищи: rg -i по memory/, open-threads.md и history/ (несколько вариантов слова),
  прочитай найденное и продолжай с того места, где остановились. «Не помню» — только
  после поиска.
- Сохраняй САМ, без команды «запомни»: факты обо мне и моих делах, решения,
  договорённости, как делать задачи → memory/<тема>.md + строка в MEMORY.md.
- Начали, продвинули или закрыли задачу — обнови open-threads.md (закрытое — [x]).
- «Запомнил» пиши ТОЛЬКО после того, как команда записи в файл выполнилась.
- Пароли, токены и ключи в память не пиши.

# Правила безопасности (красные линии)
- Никогда не удаляй файлы и данные без моей явной просьбы.
- Никогда не показывай пароли, токены и ключи.
- Не пиши никому от моего имени без разрешения.
- Сомневаешься в опасном/необратимом действии — сначала спроси меня.
EOF
  ok "AGENTS.md записан (шаблон — потом отредактируй под себя: nano $CODEX_HOME/AGENTS.md)"
fi

# Заготовка памяти в рабочей папке: индекс есть с первого дня, агенту есть что читать.
mkdir -p "$MAIN_DIR/workspace/memory"
[[ -f "$MAIN_DIR/workspace/MEMORY.md" ]] || printf '# Память -- индекс (одна строка на тему)\n' > "$MAIN_DIR/workspace/MEMORY.md"
[[ -f "$MAIN_DIR/workspace/open-threads.md" ]] || printf '# Открытые задачи -- тема, что сделано, на чём остановились, следующий шаг\n' > "$MAIN_DIR/workspace/open-threads.md"
mkdir -p "$MAIN_DIR/workspace/history"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Основной агент: .env + мост Telegram ↔ Codex
# ─────────────────────────────────────────────────────────────────────────────
say "Основной агент (мост)"
mkdir -p "$MAIN_DIR/workspace"
if [[ ! -f "$MAIN_DIR/.env" ]]; then
  cat > "$MAIN_DIR/.env" <<EOF
TELEGRAM_TOKEN=$BOT_TOKEN
TELEGRAM_CHAT_ID=$CHAT_ID
GROQ_API_KEY=$GROQ_KEY
EOF
  chmod 600 "$MAIN_DIR/.env"
  ok ".env записан"
else
  # дозапись ключа голосовых в существующий конфиг
  if [[ -n "$GROQ_KEY" ]] && ! grep -q '^GROQ_API_KEY=' "$MAIN_DIR/.env"; then
    echo "GROQ_API_KEY=$GROQ_KEY" >> "$MAIN_DIR/.env"
    ok "ключ Groq дописан в .env"
  else
    skip ".env на месте"
  fi
fi

# Мост пишем сами, детерминированно — а не просим Codex сгенерировать:
# у ста человек получится один и тот же проверенный код, а не сто вариантов.
cat > "$MAIN_DIR/bridge.sh" <<BRIDGE
#!/usr/bin/env bash
# Мост Telegram ↔ Codex: long-polling, одно сообщение = один codex exec.
# ponytail: без памяти диалога — каждый вопрос Codex видит с чистого листа;
# контекст держи в сообщении или проси его читать файлы в workspace/.
set -u
cd "\$(dirname "\$0")"
. ./.env
API="https://api.telegram.org/bot\$TELEGRAM_TOKEN"
CODEX=$CODEX_BIN
WORKDIR="\$(pwd)/workspace"
OFFSET=\$(cat .offset 2>/dev/null || echo 0)

log() { printf '%s %s\n' "\$(date '+%F %T')" "\$*" >> err.log; }

# Долгая память: выжимка диалога в файлы памяти. Зовём перед /new и каждые
# SAVE_EVERY сообщений -- как PreCompact-хук у Claude-агентов, чтобы важное не
# жило только в контексте сессии.
SAVE_EVERY=15
SAVE_PROMPT="Служебное от моста, не от владельца. Сохрани в память всё важное из этого диалога, чего там ещё нет: факты о владельце и его делах, решения, договорённости -> memory/<тема>.md + строка в MEMORY.md; начатые и незакрытые задачи и на чём остановились -> open-threads.md. Ответь одной строкой: что записал."
save_memory() {
  [ -f .session_started ] || return 0
  timeout 300 "\$CODEX" exec --json --skip-git-repo-check --cd "\$WORKDIR" resume --last "\$SAVE_PROMPT" < /dev/null >> codex.log 2>&1 \
    || log "сохранение памяти не прошло"
  echo 0 > .turns
}

send() {  # режем на куски ≤4000, Telegram больше не принимает
  local text="\$1" chunk
  while [ -n "\$text" ]; do
    chunk="\${text:0:4000}"; text="\${text:4000}"
    curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="\$chunk" >/dev/null || log "sendMessage не ушёл"
  done
}

# Текст из файла для агента: PDF и Excel разбираем заранее, агент читает .txt.
# Печатает путь к .txt или ничего (формат не наш -- агент сам посмотрит файл).
extract_text() {
  local path="\$1" name="\$2"
  case "\${name,,}" in
    *.pdf) pdftotext -layout "\$path" "\$path.txt" 2>/dev/null && echo "\$path.txt" ;;
    *.xlsx|*.xlsm|*.xls) python3 - "\$path" > "\$path.txt" 2>/dev/null <<'XLS' && echo "\$path.txt"
import sys
path = sys.argv[1]
if path.lower().endswith(".xls"):
    import xlrd
    book = xlrd.open_workbook(path)
    for sh in book.sheets():
        print(f"=== лист: {sh.name}")
        for r in range(sh.nrows):
            print("\t".join(str(c.value) for c in sh.row(r)))
else:
    import openpyxl
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    for ws in wb.worksheets:
        print(f"=== лист: {ws.title}")
        for row in ws.iter_rows(values_only=True):
            print("\t".join("" if v is None else str(v) for v in row))
XLS
    ;;
  esac
}

# Файл больше 20 МБ Telegram боту не отдаёт -- его присылают ссылкой на Яндекс
# Диск или Google Drive. Качаем сами в inbox. Печатает путь к файлу или ничего.
LINK_MAX_BYTES=524288000   # 500 МБ: больше -- не качаем, диск VPS не резиновый
fetch_link() {  # код возврата: 0 -- скачан, 1 -- нет доступа/не файл, 2 -- слишком большой
  local url="\$1" dir tmp href="" id name="" size=0 meta f dest
  dir="\$WORKDIR/inbox"; mkdir -p "\$dir"
  case "\$url" in
    *disk.yandex.*|*yadi.sk*)
      # Имя и размер -- из описания ресурса: ссылка на скачивание имени не несёт
      meta=\$(curl -s -m 30 --get "https://cloud-api.yandex.net/v1/disk/public/resources" \
        --data-urlencode "public_key=\$url")
      name=\$(printf '%s' "\$meta" | jq -r '.name // empty')
      size=\$(printf '%s' "\$meta" | jq -r '.size // 0')
      [ "\$(printf '%s' "\$meta" | jq -r '.type // empty')" = "dir" ] && name="\$name.zip"
      href=\$(curl -s -m 30 --get "https://cloud-api.yandex.net/v1/disk/public/resources/download" \
        --data-urlencode "public_key=\$url" | jq -r '.href // empty') ;;
    *drive.google.com*|*docs.google.com*)
      id=\$(printf '%s' "\$url" | grep -oE '(/d/|id=)[A-Za-z0-9_-]{20,}' | head -1 | sed -E 's#^(/d/|id=)##')
      [ -n "\$id" ] && href="https://drive.usercontent.google.com/download?id=\$id&export=download&confirm=t" ;;
  esac
  [ -n "\$href" ] || return 1
  [ "\$size" -gt "\$LINK_MAX_BYTES" ] 2>/dev/null && return 2
  tmp=\$(mktemp -d "\$dir/.dl-XXXX")
  if [ -n "\$name" ]; then
    name=\$(printf '%s' "\$name" | tr '/' '_' | tr -d '\000-\037' | cut -c1-120)
    curl -sfL -m 1800 --max-filesize "\$LINK_MAX_BYTES" -o "\$tmp/\$name" "\$href"
  else
    ( cd "\$tmp" && curl -sfL -m 1800 --max-filesize "\$LINK_MAX_BYTES" -OJ "\$href" )
  fi
  case \$? in 0) ;; 63) rm -rf "\$tmp"; return 2 ;; *) rm -rf "\$tmp"; return 1 ;; esac
  f=\$(find "\$tmp" -maxdepth 1 -type f | head -1)
  # Google отдаёт HTML-страницу вместо файла, если доступа по ссылке нет
  if [ -z "\$f" ] || head -c 512 "\$f" | grep -qi '<html'; then rm -rf "\$tmp"; return 1; fi
  dest="\$dir/\$(date +%Y%m%d-%H%M%S)-\$(basename "\$f" | tr -d '\000-\037' | cut -c1-120)"
  mv "\$f" "\$dest"; rm -rf "\$tmp"
  echo "\$dest"
}

while :; do
  UPDATES=\$(curl -s --max-time 40 "\$API/getUpdates?timeout=30&offset=\$OFFSET") || { log "getUpdates: сеть"; sleep 5; continue; }
  [ "\$(printf '%s' "\$UPDATES" | jq -r .ok 2>/dev/null)" = "true" ] || { log "getUpdates: \$UPDATES"; sleep 5; continue; }
  for row in \$(printf '%s' "\$UPDATES" | jq -r '.result[] | @base64'); do
    upd() { printf '%s' "\$row" | base64 -d | jq -r "\$1"; }
    OFFSET=\$(( \$(upd .update_id) + 1 )); printf '%s' "\$OFFSET" > .offset
    FROM=\$(upd '.message.chat.id // empty'); TEXT=\$(upd '.message.text // empty')
    [ "\$FROM" = "\$TELEGRAM_CHAT_ID" ] || continue
    VOICE=\$(upd '.message.voice.file_id // empty')
    # фото: берём последний размер (самый большой), подпись = промпт
    PHOTO=\$(upd '[.message.photo[]?.file_id] | last // empty')
    IMGARG=""; rm -f "\$WORKDIR/photo.jpg"
    if [ -n "\$PHOTO" ]; then
      FP=\$(curl -s "\$API/getFile?file_id=\$PHOTO" | jq -r '.result.file_path // empty')
      if [ -n "\$FP" ] && curl -sf -o "\$WORKDIR/photo.jpg" "https://api.telegram.org/file/bot\$TELEGRAM_TOKEN/\$FP"; then
        IMGARG="--image \$WORKDIR/photo.jpg"
        [ -z "\$TEXT" ] && TEXT=\$(upd '.message.caption // empty')
        [ -z "\$TEXT" ] && TEXT="Что на фото? Опиши и скажи, что с этим делать."
      else log "фото не скачалось"; fi
    fi
    # Файл (PDF, Excel, Word, csv...): мост сам качает его в workspace/inbox и,
    # где умеет, заранее вытаскивает текст -- Codex читает готовый .txt. Раньше
    # вложения молча терялись, и агент отвечал «нет доступа к мосту» (28.09.2026).
    DOC=\$(upd '.message.document.file_id // empty')
    if [ -n "\$DOC" ]; then
      DNAME=\$(upd '.message.document.file_name // "file"' | tr '/' '_' | tr -d '\000-\037' | cut -c1-120)
      DSIZE=\$(upd '.message.document.file_size // 0')
      mkdir -p "\$WORKDIR/inbox"; DPATH="\$WORKDIR/inbox/\$(date +%Y%m%d-%H%M%S)-\$DNAME"
      FP=\$(curl -s "\$API/getFile?file_id=\$DOC" | jq -r '.result.file_path // empty')
      if [ -n "\$FP" ] && curl -sf -o "\$DPATH" "https://api.telegram.org/file/bot\$TELEGRAM_TOKEN/\$FP"; then
        DTXT=\$(extract_text "\$DPATH" "\$DNAME")
        [ -z "\$TEXT" ] && TEXT=\$(upd '.message.caption // empty')
        [ -z "\$TEXT" ] && TEXT="Разбери присланный файл: что в нём и что с этим делать."
        TEXT="\$TEXT

[Мост: прислан файл \$DNAME, сохранён: \$DPATH\${DTXT:+; текст из него уже вытащен в \$DTXT -- читай его}]"
      else
        log "файл не скачался (\$DNAME, \$DSIZE байт)"
        if [ "\$DSIZE" -gt 20000000 ] 2>/dev/null; then
          send "Файл больше 20 МБ -- Telegram не отдаёт такие ботам. Положи его на Яндекс Диск или Google Drive и пришли ссылку -- скачаю сам."
        else send "Файл не скачался, пришли ещё раз."; fi
        continue
      fi
    fi
    if [ -z "\$TEXT" ] && [ -n "\$VOICE" ] && [ -n "\${GROQ_API_KEY:-}" ]; then
      # голосовое -> текст через Groq Whisper
      FP=\$(curl -s "\$API/getFile?file_id=\$VOICE" | jq -r '.result.file_path // empty')
      if [ -n "\$FP" ]; then
        curl -s -o voice.ogg "https://api.telegram.org/file/bot\$TELEGRAM_TOKEN/\$FP"
        TEXT=\$(curl -s https://api.groq.com/openai/v1/audio/transcriptions \
          -H "Authorization: Bearer \$GROQ_API_KEY" \
          -F "file=@voice.ogg" -F "model=whisper-large-v3" | jq -r '.text // empty')
        rm -f voice.ogg
        [ -z "\$TEXT" ] && log "распознавание голосового не вернуло текст"
      fi
    fi
    if [ -z "\$TEXT" ]; then
      if [ -n "\$VOICE" ]; then send "Не разобрал голосовое. Голосовые работают при заданном ключе Groq (см. гайд, раздел про голосовые)."
      else send "Понимаю текст, голосовые, фото и файлы (PDF, Excel)."; fi
      continue
    fi
    # Ссылка на облако в сообщении -> качаем файл и разбираем, как вложение
    LINK=\$(printf '%s' "\$TEXT" | grep -oE 'https?://(disk\.yandex\.[a-z]+|yadi\.sk|drive\.google\.com|docs\.google\.com)/[^[:space:]]+' | head -1)
    if [ -n "\$LINK" ]; then
      send "Качаю файл по ссылке..."
      LPATH=\$(fetch_link "\$LINK"); LRC=\$?
      if [ \$LRC -eq 0 ] && [ -n "\$LPATH" ]; then
        LTXT=\$(extract_text "\$LPATH" "\$LPATH")
        TEXT="\$TEXT

[Мост: файл по ссылке скачан: \$LPATH\${LTXT:+; текст из него уже вытащен в \$LTXT -- читай его}]"
      elif [ \$LRC -eq 2 ]; then
        log "ссылка: файл больше лимита: \$LINK"
        TEXT="\$TEXT

[Мост: файл по ссылке больше 500 МБ -- не качал, чтобы не забить диск. Попроси прислать нужную часть.]"
      else
        log "ссылка не скачалась: \$LINK"
        TEXT="\$TEXT

[Мост: файл по ссылке скачать не удалось -- скорее всего, доступ только по приглашению. Попроси открыть доступ «всем, у кого есть ссылка» или прислать файл иначе.]"
      fi
    fi
    if [ "\$TEXT" = "/new" ]; then
      send "Сохраняю важное из диалога в память и начинаю новую сессию..."
      save_memory
      rm -f .session_started
      send "Новая сессия. Всё важное -- в памяти, прошлые разговоры найду по журналу."
      continue
    fi
    # Живой прогресс: статус-сообщение в чате обновляется последней строкой работы
    # Codex каждые 5 сек — видно, что агент не завис.
    MSGID=\$(curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="⏳ Работаю..." | jq -r '.result.message_id // empty')
    # Непрерывность диалога: продолжаем прошлую сессию Codex (resume --last),
    # /new — начать с чистого листа
    RESUME=""
    [ -f .session_started ] && RESUME="resume --last"
    OUT=\$(mktemp); : > task.log
    # Опции exec -- ДО «resume»: у подкоманды resume нет --cd, и «exec resume --cd» падал
    # с «Usage: codex exec resume ...» на каждом втором сообщении (25.09.2026).
    # --json: шаги работы идут событиями в events.jsonl, карточка пишет их по-людски.
    : > events.jsonl
    # Память по смыслу: найденное в журнале и файлах памяти мост подкладывает к
    # сообщению сам -- как recall-хук у Claude-агентов. Нет службы -- пусто, не мешает.
    PROMPT="\$TEXT"
    MEMHITS=\$(timeout 30 python3 ./memsearch.py query "\$TEXT" 2>/dev/null)
    [ -n "\$MEMHITS" ] && PROMPT="\$TEXT

[Мост: из памяти по смыслу, может пригодиться -- подробности в указанных файлах:
\$MEMHITS]"
    timeout 600 "\$CODEX" exec --json --skip-git-repo-check --cd "\$WORKDIR" --output-last-message "\$OUT" \$RESUME \$IMGARG "\$PROMPT" < /dev/null > events.jsonl 2> task.log &
    PID=\$!
    PREV=""; START=\$(date +%s)
    while kill -0 "\$PID" 2>/dev/null; do
      sleep 5
      # Карточка как у dashi: «работаю — Nс» + последние шаги, текущий со стрелкой
      STEPS=\$(jq -Rr 'fromjson? | if .type=="error" then "Связь с ChatGPT: переподключаюсь"
        elif .type=="item.started" then (.item | if .type=="command_execution" then "Выполняю: " + ((.command|tostring)[0:90])
          elif .type=="reasoning" then "Думаю" elif .type=="file_change" then "Правлю файлы"
          elif .type=="web_search" then "Ищу в интернете" elif .type=="mcp_tool_call" then "Инструмент: " + (.tool // "?")
          elif .type=="todo_list" then "Составляю план" elif .type=="agent_message" then "Пишу ответ" else empty end)
        else empty end' events.jsonl 2>/dev/null | uniq | tail -3)
      [ -z "\$STEPS" ] && STEPS="Думаю"
      N=\$(printf '%s\n' "\$STEPS" | wc -l)
      CARD="⏳ Работаю — \$(( \$(date +%s) - START ))с"
      i=0
      while IFS= read -r st; do
        i=\$((i+1))
        [ -z "\$st" ] && continue
        if [ "\$i" -eq "\$N" ]; then CARD="\$CARD
→ \$st"; else CARD="\$CARD
✓ \$st"; fi
      done <<STEPS_EOF
\$STEPS
STEPS_EOF
      if [ -n "\$MSGID" ] && [ "\$CARD" != "\$PREV" ]; then
        curl -s -X POST "\$API/editMessageText" \
          --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
          -d message_id="\$MSGID" \
          --data-urlencode text="\$CARD" >/dev/null
        PREV="\$CARD"
      fi
    done
    wait "\$PID"; RC=\$?
    if [ \$RC -ne 0 ] && [ -n "\$RESUME" ]; then
      # resume не взлетел (сессия протухла/не найдена) — повтор с чистого листа
      log "resume rc=\$RC, повтор без resume"
      rm -f .session_started
      timeout 600 "\$CODEX" exec --json --skip-git-repo-check --cd "\$WORKDIR" --output-last-message "\$OUT" \$IMGARG "\$PROMPT" < /dev/null >> events.jsonl 2>> task.log
      RC=\$?
    fi
    [ \$RC -eq 0 ] && touch .session_started
    cat events.jsonl task.log >> codex.log
    [ -n "\$MSGID" ] && curl -s -X POST "\$API/deleteMessage" \
      -d chat_id="\$TELEGRAM_CHAT_ID" -d message_id="\$MSGID" >/dev/null
    ANSWER=\$(cat "\$OUT" 2>/dev/null); rm -f "\$OUT"
    if [ -z "\$ANSWER" ]; then
      if [ \$RC -eq 124 ]; then
        ANSWER="Codex думал дольше 10 минут — оборвал. Попробуй задачу помельче."
        log "codex exec timeout"
      elif [ \$RC -ne 0 ]; then
        ERR=\$( { jq -Rr 'fromjson? | select(.type=="error" or .type=="turn.failed") | (.message // .error.message // empty)' events.jsonl 2>/dev/null; grep -v '^[[:space:]]*\$' task.log; } | tail -4 | cut -c1-300)
        ANSWER="Codex споткнулся (код \$RC):
\$ERR"
        log "codex exec rc=\$RC"
      else
        ANSWER="(Codex вернул пустой ответ — смотри codex.log на сервере)"
      fi
    fi
    send "\$ANSWER"
    # Журнал переписки -- агент ищет по нему, когда владелец ссылается на прошлое.
    mkdir -p "\$WORKDIR/history"
    printf '\n## %s\n**Владелец:** %s\n\n**Агент:** %s\n' "\$(date '+%H:%M')" "\$TEXT" "\$ANSWER" >> "\$WORKDIR/history/\$(date +%F).md"
    TURNS=\$(( \$(cat .turns 2>/dev/null || echo 0) + 1 )); echo "\$TURNS" > .turns
    [ "\$TURNS" -ge "\$SAVE_EVERY" ] && save_memory
    ( timeout 600 python3 ./memsearch.py index >/dev/null 2>&1 & )
  done
done
BRIDGE
chmod +x "$MAIN_DIR/bridge.sh"
ok "bridge.sh записан"

# Журнал до появления долгой памяти: разговоры и так лежат в сессиях Codex --
# переносим их в history/ один раз, чтобы агент нашёл и то, что было раньше.
if [[ -z "$(ls -A "$MAIN_DIR/workspace/history" 2>/dev/null)" ]]; then
  n=0
  for f in "$CODEX_HOME"/sessions/*/*/*/rollout-*.jsonl; do
    [[ -f "$f" ]] || continue
    # только сессии основного агента (у ремонтника своя папка)
    [[ "$(head -n 1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)" == "$MAIN_DIR/workspace" ]] || continue
    jq -r 'select(.type=="response_item" and .payload.type=="message" and (.payload.role=="user" or .payload.role=="assistant"))
      | ([.payload.content[]?.text // empty] | join("\n")) as $t
      | select($t != "" and ($t | startswith("# AGENTS.md") | not) and ($t | startswith("<") | not))
      | [.timestamp[0:10], .timestamp[11:16], (if .payload.role=="user" then "Владелец" else "Агент" end), $t] | @json' "$f" 2>/dev/null
  done | while IFS= read -r row; do
    d=$(jq -r '.[0]' <<<"$row"); printf '\n## %s (UTC)\n**%s:** %s\n' "$(jq -r '.[1]' <<<"$row")" "$(jq -r '.[2]' <<<"$row")" "$(jq -r '.[3]' <<<"$row")" >> "$MAIN_DIR/workspace/history/$d.md"
  done
  n=$(ls "$MAIN_DIR/workspace/history" 2>/dev/null | wc -l)
  ok "журнал прошлых разговоров перенесён в history/ (дней: $n)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4b. Память по смыслу: по ключу OpenAI или локальной моделью
# ─────────────────────────────────────────────────────────────────────────────
# Есть ключ OpenAI -- вектора считает text-embedding-3-large: на сервере ноль
# памяти, центы в месяц. Замер 26.09.2026 на тестовой памяти: все 8 вопросов
# нашли свою запись (в т.ч. «ДНС» -> запись про DNS, 0.42), чужие темы не выше
# 0.30 -> порог 0.40. text-embedding-3-small тот же тест провалил.
# Нет ключа -- локальная multilingual-e5-large (замер 25.09.2026), держит ~2 ГБ,
# поэтому нужен запас RAM+своп; нет запаса -- пропускаем, поиск по словам (rg)
# остаётся.
say "Память по смыслу"
cat > "$MAIN_DIR/memsearch.py" <<'EOF'
#!/usr/bin/env python3
"""Semantic search over the Codex agent's memory: history/, memory/, open-threads.md.

Embeddings come either from the local embed server (fastembed, multilingual-e5-large
on 127.0.0.1:1934: no key, but ~2 GB RAM) or, when memsearch.conf next to this script
holds an OpenAI key, from the OpenAI API (no RAM, cents a month). The index is a JSON cache keyed by chunk hash: re-indexing only
embeds what is new.
  memsearch.py index         -- embed new chunks
  memsearch.py query "text"  -- print hits above the threshold
Always exits 0: memory is a convenience, never a blocker.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
import urllib.request
from pathlib import Path

WS = Path(os.environ.get("MEM_WORKSPACE", Path(__file__).resolve().parent / "workspace"))
INDEX = WS / ".memindex.json"

def _conf() -> dict[str, str]:
    """KEY=VALUE lines from memsearch.conf (mode 600); the environment wins."""
    out: dict[str, str] = {}
    try:
        for line in (Path(__file__).resolve().parent / "memsearch.conf").read_text().splitlines():
            k, sep, v = line.partition("=")
            if sep and not k.strip().startswith("#"):
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return {**out, **{k: v for k, v in os.environ.items() if k.startswith("MEM_")}}


CONF = _conf()
URL = CONF.get("MEM_EMBED_URL", "http://127.0.0.1:1934/v1/embeddings")
API_KEY = CONF.get("MEM_EMBED_KEY", "")
MODEL = CONF.get("MEM_EMBED_MODEL", "")
# e5 wants the "query: "/"passage: " prefixes; OpenAI models do not.
PREFIX = CONF.get("MEM_PREFIX", "0" if API_KEY else "1") == "1"
# multilingual-e5-large: scores sit high and close together. Measured 25.09.2026 on
# the agent box (cosine + lexical bonus): relevant 0.80-0.90, off-topic best 0.77.
# Borderline noise reaches the agent as «может пригодиться», and it ignores it.
# e5 wants the "query: "/"passage: " prefixes, without them ranking degrades.
# The installer writes the threshold measured for the OpenAI model into the conf.
THRESHOLD = float(CONF.get("MEM_THRESHOLD", "0.78"))
BACKEND = f"{URL}|{MODEL}|{PREFIX}"  # vectors of different models do not mix
TOP = 3
CHUNK_CHARS = 1500
SNIPPET_CHARS = 400
BATCH = 32


def embed(texts: list[str]) -> list[list[float]]:
    out: list[list[float]] = []
    for i in range(0, len(texts), BATCH):
        payload: dict = {"input": texts[i:i + BATCH]}
        headers = {"Content-Type": "application/json"}
        if MODEL:
            payload["model"] = MODEL
        if API_KEY:
            headers["Authorization"] = f"Bearer {API_KEY}"
        req = urllib.request.Request(URL, json.dumps(payload).encode(), headers)
        with urllib.request.urlopen(req, timeout=120) as r:
            out += [d["embedding"] for d in json.load(r)["data"]]
    return out


def chunks() -> list[tuple[str, str]]:
    """(label, text) for every searchable piece of memory."""
    res: list[tuple[str, str]] = []
    for f in sorted((WS / "history").glob("*.md")):
        for block in re.split(r"\n(?=## )", f.read_text(errors="ignore")):
            block = block.strip()
            if len(block) > 20:
                head = block.splitlines()[0].lstrip("# ").strip()
                res.append((f"history/{f.name} {head}", block[:CHUNK_CHARS]))
    for f in sorted((WS / "memory").glob("*.md")):
        res.append((f"memory/{f.name}", f.read_text(errors="ignore")[:CHUNK_CHARS]))
    ot = WS / "open-threads.md"
    if ot.exists():
        for block in re.split(r"\n(?=## )", ot.read_text(errors="ignore")):
            if block.startswith("## "):
                res.append(("open-threads.md " + block.splitlines()[0][3:60], block[:CHUNK_CHARS]))
    return res


def key(text: str) -> str:
    return hashlib.sha1(text.encode()).hexdigest()


def load() -> dict:
    try:
        idx = json.loads(INDEX.read_text())
    except (OSError, ValueError):
        return {}
    # Switched model: the old vectors are useless, rebuild from scratch.
    if idx.pop("__backend__", None) != BACKEND:
        return {}
    return idx


def index() -> dict:
    old = load()
    items = chunks()
    new = {key(t): {"label": l, "text": t} for l, t in items}
    todo = [h for h in new if h not in old]
    if todo:
        for h, v in zip(todo, embed([("passage: " if PREFIX else "") + new[h]["text"] for h in todo])):
            new[h]["vec"] = v
    for h in new:
        if "vec" not in new[h]:
            new[h]["vec"] = old[h]["vec"]
    INDEX.write_text(json.dumps({**new, "__backend__": BACKEND}, ensure_ascii=False))
    return new


def cos(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a)); nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


# Conversational filler drowns the topic: «давай вернёмся к вопросу про ДНС, на чём
# остановились» scored the DNS note below small talk (25.09.2026). Strip it, then add
# a lexical bonus with Cyrillic->Latin transliteration (ДНС -> dns).
STOP = set("""давай давайте вернемся вернёмся вернуться вопрос вопросу про на чем чём мы там
остановились остановились что как это а и в во по с со у о об же ну ка ли слушай помнишь
обсуждали говорили было были тот та то тогда еще ещё мне меня мой моя ты тебя""".split())
TRANSLIT = str.maketrans("абвгдезийклмнопрстуфхцыэ", "abvgdezijklmnoprstufhcye")
LEX_WEIGHT = 0.1


def content_words(q: str) -> list[str]:
    return [w for w in re.findall(r"[\w-]+", q.lower()) if len(w) >= 2 and w not in STOP]


def lexical(words: list[str], text: str) -> float:
    if not words:
        return 0.0
    t = text.lower()
    hit = sum(1 for w in words if w in t or w.translate(TRANSLIT) in t)
    return hit / len(words)


def query(q: str) -> str:
    idx = load() or index()
    if not idx or len(q.strip()) < 12:  # «привет», «живой?» -- искать нечего
        return ""
    words = content_words(q)
    qv = embed([("query: " if PREFIX else "") + (" ".join(words) or q)])[0]
    scored = sorted(((cos(qv, v["vec"]) + LEX_WEIGHT * lexical(words, v["text"]), v)
                     for v in idx.values()), key=lambda s: -s[0])
    lines = []
    for score, v in scored[:TOP]:
        if score < THRESHOLD:
            break
        snip = re.sub(r"\s+", " ", v["text"])[:SNIPPET_CHARS]
        lines.append(f"- [{score:.2f}] {v['label']}: {snip}")
    return "\n".join(lines)


def main() -> None:
    try:
        if sys.argv[1:2] == ["index"]:
            n = len(index())
            print(f"chunks: {n}")
        elif sys.argv[1:2] == ["query"]:
            print(query(" ".join(sys.argv[2:])))
        else:
            print(__doc__)
    except Exception as e:  # memory must never break the bridge
        print(f"memsearch: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
EOF
chmod +x "$MAIN_DIR/memsearch.py"
MEM_CONF="$MAIN_DIR/memsearch.conf"
MEM_OPENAI_MODEL="text-embedding-3-large"
MEM_OPENAI_THRESHOLD="0.40"
if [[ -n "$OPENAI_KEY" ]]; then
  # Ключ проверяем живым запросом: битый ключ молча оставил бы агента без памяти.
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 30 https://api.openai.com/v1/embeddings \
    -H "Authorization: Bearer $OPENAI_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MEM_OPENAI_MODEL\",\"input\":\"проверка\"}" || true)"
  if [[ "$code" == 200 ]]; then
    ( umask 077; printf 'MEM_EMBED_URL=https://api.openai.com/v1/embeddings\nMEM_EMBED_KEY=%s\nMEM_EMBED_MODEL=%s\nMEM_THRESHOLD=%s\n' \
        "$OPENAI_KEY" "$MEM_OPENAI_MODEL" "$MEM_OPENAI_THRESHOLD" > "$MEM_CONF" )
    ok "память по смыслу -- по ключу OpenAI, оперативку сервера не ест"
  else
    warn "ключ OpenAI не принят (HTTP $code) -- ставлю локальную модель"
  fi
fi
if grep -q '^MEM_EMBED_KEY=.' "$MEM_CONF" 2>/dev/null; then
  # Перешли на ключ -- локальная модель больше не нужна, отдаём её 2 ГБ обратно.
  if systemctl is-enabled --quiet codex-embed 2>/dev/null; then
    systemctl disable -q --now codex-embed && ok "локальная модель памяти выключена"
  fi
  ( cd "$MAIN_DIR" && nohup timeout 1800 python3 ./memsearch.py index >/dev/null 2>&1 & )
  skip "память по смыслу на ключе OpenAI"
else
mem_mb() { awk '/MemTotal|SwapTotal/{s+=$2} END{print int(s/1024)}' /proc/meminfo; }
if (( $(mem_mb) < 5500 )) && ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile \
    && { grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; } \
    && ok "своп 2 ГБ для модели памяти"
fi
if (( $(mem_mb) < 5500 )); then
  skip "памяти мало ($(mem_mb) МБ RAM+своп) -- поиск по смыслу пропускаю, по словам работает; с ключом OpenAI (--openai-key) встанет без нагрузки на память"
else
  if ! python3 -c 'import fastembed, fastapi, uvicorn' >/dev/null 2>&1; then
    python3 -m pip --version >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-pip >/dev/null 2>&1; }
    for attempt in 1 2; do
      python3 -m pip install -q --user fastembed fastapi uvicorn >> "$MAIN_DIR/embed-install.log" 2>&1 && break
      sleep 5
    done
  fi
  if python3 -c 'import fastembed, fastapi, uvicorn' >/dev/null 2>&1; then
    cat > "$MAIN_DIR/embed-server.py" <<'EOF'
#!/usr/bin/env python3
"""Minimal OpenAI-compatible embeddings server on fastembed (CPU, ~400 MB RSS).

Serves POST /v1/embeddings so OpenViking's `provider: openai` path can use a
local model: no API key, no money, no outbound traffic. Bound to loopback.
"""
from __future__ import annotations

import os
from typing import Any

from fastapi import FastAPI
from fastembed import TextEmbedding
from pydantic import BaseModel

MODEL_NAME = os.environ.get("EMBED_MODEL", "intfloat/multilingual-e5-small")
MAX_CHARS = int(os.environ.get("EMBED_MAX_CHARS", "8000"))

app = FastAPI()
_model = TextEmbedding(model_name=MODEL_NAME, threads=1)


class EmbedRequest(BaseModel):
    input: str | list[str]
    model: str | None = None


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/v1/embeddings")
def embeddings(req: EmbedRequest) -> dict[str, Any]:
    texts = [req.input] if isinstance(req.input, str) else list(req.input)
    # The model truncates internally at its context window; cap the payload so a
    # huge chunk cannot stall the single worker thread.
    texts = [t[:MAX_CHARS] for t in texts]
    vectors = list(_model.embed(texts))
    data = [
        {"object": "embedding", "index": i, "embedding": [float(x) for x in vec]}
        for i, vec in enumerate(vectors)
    ]
    return {"object": "list", "data": data, "model": MODEL_NAME}
EOF
    cat > /etc/systemd/system/codex-embed.service <<UNIT
[Unit]
Description=Local embeddings for Codex agent memory (semantic search)
After=network.target

[Service]
Environment=HOME=/root
Environment=OMP_NUM_THREADS=1
Environment=EMBED_MODEL=intfloat/multilingual-e5-large
ExecStart=/root/.local/bin/uvicorn embed-server:app --host 127.0.0.1 --port 1934
WorkingDirectory=$MAIN_DIR
Restart=always
MemoryMax=3000M

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable -q codex-embed; systemctl restart codex-embed
    # первый старт качает модель (~2 ГБ) -- ждём до 10 минут
    for _ in $(seq 1 120); do sleep 5; curl -sf -m 5 http://127.0.0.1:1934/health >/dev/null && break; done
    if curl -sf -m 5 http://127.0.0.1:1934/health >/dev/null; then
      ( cd "$MAIN_DIR" && nohup timeout 1800 python3 ./memsearch.py index >/dev/null 2>&1 & )
      ok "поиск по смыслу работает (индекс журнала строится в фоне)"
    else
      warn "модель памяти не поднялась -- journalctl -u codex-embed; поиск по словам работает"
    fi
  else
    warn "не встали пакеты модели памяти ($MAIN_DIR/embed-install.log) -- поиск по словам работает"
  fi
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Ремонтник: .env + watchdog
# ─────────────────────────────────────────────────────────────────────────────
say "Ремонтник"
mkdir -p "$WATCH_DIR/workspace"
if [[ ! -f "$WATCH_DIR/.env" ]]; then
  cat > "$WATCH_DIR/.env" <<EOF
TELEGRAM_TOKEN=$WATCH_TOKEN
TELEGRAM_CHAT_ID=$CHAT_ID
EOF
  chmod 600 "$WATCH_DIR/.env"
  ok ".env записан"
else
  skip ".env на месте"
fi

cat > "$WATCH_DIR/watchdog.sh" <<WATCHDOG
#!/usr/bin/env bash
# Ремонтник: следит за agent-main, перезапускает упавшего, отвечает в свой чат.
# ponytail: детект только через systemctl is-active; зависание живого процесса
# ловится командой «перезапусти» руками.
set -u
cd "\$(dirname "\$0")"
. ./.env
API="https://api.telegram.org/bot\$TELEGRAM_TOKEN"
CODEX=$CODEX_BIN
WORKDIR="\$(pwd)/workspace"
OFFSET=\$(cat .offset 2>/dev/null || echo 0)

log() { printf '%s %s\n' "\$(date '+%F %T')" "\$*" >> err.log; }
send() {
  local text="\$1" chunk
  while [ -n "\$text" ]; do
    chunk="\${text:0:4000}"; text="\${text:4000}"
    curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="\$chunk" >/dev/null || log "sendMessage не ушёл"
  done
}

# Фоновая проверка раз в 60 сек: основной лежит — поднять и доложить.
(
  while :; do
    if ! systemctl is-active --quiet agent-main; then
      systemctl restart agent-main
      sleep 10
      send "Основной агент падал — перезапустил. Хвост его лога:
\$(tail -3 /root/agent-main/err.log 2>/dev/null || echo нет)"
    fi
    sleep 60
  done
) &

status_text() {
  printf 'agent-main: %s\nХвост err.log:\n%s' \
    "\$(systemctl is-active agent-main)" \
    "\$(tail -3 /root/agent-main/err.log 2>/dev/null || echo 'пусто')"
}

while :; do
  UPDATES=\$(curl -s --max-time 40 "\$API/getUpdates?timeout=30&offset=\$OFFSET") || { log "getUpdates: сеть"; sleep 5; continue; }
  [ "\$(printf '%s' "\$UPDATES" | jq -r .ok 2>/dev/null)" = "true" ] || { log "getUpdates: \$UPDATES"; sleep 5; continue; }
  for row in \$(printf '%s' "\$UPDATES" | jq -r '.result[] | @base64'); do
    upd() { printf '%s' "\$row" | base64 -d | jq -r "\$1"; }
    OFFSET=\$(( \$(upd .update_id) + 1 )); printf '%s' "\$OFFSET" > .offset
    FROM=\$(upd '.message.chat.id // empty'); TEXT=\$(upd '.message.text // empty')
    [ "\$FROM" = "\$TELEGRAM_CHAT_ID" ] || continue
    [ -n "\$TEXT" ] || continue
    LOWER=\$(printf '%s' "\$TEXT" | tr '[:upper:]' '[:lower:]')
    case "\$LOWER" in
      *перезапус*|*restart*)
        systemctl restart agent-main; sleep 5
        send "Перезапустил основного. Сейчас он: \$(systemctl is-active agent-main)" ;;
      *статус*|*status*|*"как там"*)
        send "\$(status_text)" ;;
      *)
        curl -s "\$API/sendChatAction" -d chat_id="\$TELEGRAM_CHAT_ID" -d action=typing >/dev/null
        OUT=\$(mktemp)
        timeout 300 "\$CODEX" exec --skip-git-repo-check --cd "\$WORKDIR" --output-last-message "\$OUT" \
          "Ты — агент-ремонтник на сервере. Состояние основного агента: \$(status_text). Вопрос хозяина: \$TEXT" >> codex.log 2>&1
        ANSWER=\$(cat "\$OUT" 2>/dev/null); rm -f "\$OUT"
        send "\${ANSWER:-Не смог ответить — смотри codex.log ремонтника}" ;;
    esac
  done
done
WATCHDOG
chmod +x "$WATCH_DIR/watchdog.sh"
ok "watchdog.sh записан"

# ─────────────────────────────────────────────────────────────────────────────
# 6. systemd: оба сервиса
# ─────────────────────────────────────────────────────────────────────────────
say "Автозапуск (systemd)"
for pair in "agent-main:$MAIN_DIR/bridge.sh" "agent-watchdog:$WATCH_DIR/watchdog.sh"; do
  name="${pair%%:*}"; script="${pair#*:}"
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$name (Codex Telegram agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$(dirname "$script")
ExecStart=$script
Restart=always
RestartSec=5
Environment=PATH=$(dirname "$CODEX_BIN"):/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
ok "юниты записаны"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Вход в ChatGPT — единственное, что нельзя сделать за человека
# ─────────────────────────────────────────────────────────────────────────────
# Проверяем файл с токенами, а не `codex login status`: у части версий CLI такой
# подкоманды нет, и её ошибка неотличима от «не залогинен» — путь к вечному циклу.
if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
  cat <<EOF

──────────────────────────────────────────────────────────────
  Осталось войти в ChatGPT — руками, за тебя это никто не сделает.

  0) СНАЧАЛА включи вход по коду (у OpenAI он по умолчанию выключен,
     без него код не примется): chatgpt.com → аватарка → Настройки →
     Безопасность → «Авторизация с помощью кода устройства» → включить.
  1) $CODEX_BIN login --device-auth
  2) Codex покажет КОРОТКИЙ КОД и адрес — открой адрес в браузере
     на любом устройстве, войди в аккаунт ChatGPT (тот, где оплачена
     подписка) и введи код.
  3) В консоли появится «signed in».
  4) Запусти ту же команду установки ещё раз (стрелка вверх → Enter).

  Запасной путь (если device-auth не сработал): с компьютера
  «ssh -L 1455:localhost:1455 root@$(hostname -I 2>/dev/null | awk '{print $1}')»,
  там «$CODEX_BIN login», ссылку склеить в одну строку и открыть
  в браузере ТОГО ЖЕ компьютера.

  Повторный запуск доделает остальное и ничего не сломает.
──────────────────────────────────────────────────────────────
EOF
  exit 0
fi
ok "вход в ChatGPT выполнен"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Поднимаем
# ─────────────────────────────────────────────────────────────────────────────
say "Запуск"
systemctl enable agent-main agent-watchdog >/dev/null 2>&1 || true
# restart, а не только enable --now: повторный прогон переписывает bridge.sh,
# и уже работающий сервис должен подхватить свежий код
systemctl restart agent-main agent-watchdog >/dev/null 2>&1 || true
sleep 5

if systemctl is-active --quiet agent-main && systemctl is-active --quiet agent-watchdog; then
  cat <<EOF

  ✓ Готово. Оба агента подняты и стартуют сами после перезагрузки.

  Напиши ОСНОВНОМУ боту в Telegram «привет, ты живой?» — ответит за 5–20 сек.
  Ремонтнику напиши «статус» — покажет состояние основного.

  Характер агента:  nano /root/.codex/AGENTS.md  (потом: systemctl restart agent-main)
  Логи основного:   journalctl -u agent-main -n 50
  Перезапуск:       systemctl restart agent-main

EOF
else
  die "какой-то сервис не поднялся. Смотри: systemctl status agent-main agent-watchdog"
fi
