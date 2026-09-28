#!/usr/bin/env bash
# install-kit.sh — lay the discipline layer on top of the bare agent.
#
# install-agent.sh gives a working agent: it starts, talks to its owner, remembers.
# This kit gives it the WAY OF WORKING that Jarvis needed months of operator
# corrections to grow: the constitution, the gate hooks that fire on their own, the
# registries, and the three subagents.
#
# Idempotent: re-running replaces files and never double-registers a hook.
#
# Usage: install-kit.sh --claude-dir DIR [--chat-id ID] [--agent NAME] [--settings FILE] [--tz TZ]
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR=""; CHAT_ID=""; AGENT=""; SETTINGS=""; OWNER_TZ=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
    --chat-id)    CHAT_ID="$2";    shift 2 ;;
    --agent)      AGENT="$2";      shift 2 ;;
    --settings)   SETTINGS="$2";   shift 2 ;;
    --tz)         OWNER_TZ="$2";   shift 2 ;;   # пояс ХОЗЯИНА: сводка в 09:00 по нему
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$CLAUDE_DIR" ]] || { echo "--claude-dir required" >&2; exit 2; }
SETTINGS="${SETTINGS:-$CLAUDE_DIR/settings.json}"
AGENT="${AGENT:-agent}"
WORKSPACE="$(dirname "$CLAUDE_DIR")"

mkdir -p "$CLAUDE_DIR"/{hooks,core,agents} "$WORKSPACE/bin" "$WORKSPACE/logs" "$WORKSPACE/data"

# Placeholders are substituted on copy — the kit itself stays host-agnostic.
# A file that already exists AND differs is copied to .kit-backup/<stamp>/<same
# relative path> first: the kit refreshes hooks/bin/agents/constitution on a
# living agent, and a local tweak lost without a copy is a silent regression.
BACKUP_DIR="$WORKSPACE/.kit-backup/$(date +%Y%m%d-%H%M)"
BACKED=0
render() {
  local tmp; tmp="$(mktemp)"
  sed -e "s|__CLAUDE_DIR__|$CLAUDE_DIR|g" \
      -e "s|__WORKSPACE__|$WORKSPACE|g" \
      -e "s|__CHAT_ID__|$CHAT_ID|g" \
      -e "s|__AGENT__|$AGENT|g" "$1" > "$tmp"
  if [[ -f "$2" ]] && ! cmp -s "$tmp" "$2"; then
    local rel="${2#"$WORKSPACE"/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -p "$2" "$BACKUP_DIR/$rel"
    BACKED=$((BACKED + 1))
  fi
  cat "$tmp" > "$2"; rm -f "$tmp"
}

# -f: каталоги (например __pycache__ после прогона тестов) раскладке не подлежат.
for f in "$KIT"/hooks/*; do [[ -f "$f" ]] && render "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"; done
for f in "$KIT"/bin/*;   do [[ -f "$f" ]] && render "$f" "$WORKSPACE/bin/$(basename "$f")"; done
for f in "$KIT"/agents/*; do [[ -f "$f" ]] && render "$f" "$CLAUDE_DIR/agents/$(basename "$f")"; done
chmod +x "$CLAUDE_DIR"/hooks/* "$WORKSPACE"/bin/* 2>/dev/null || true

# Registries: never clobber a ledger the agent has already been writing into.
# The constitution is ours and is refreshed with the kit; core/rules.md is the
# owner's own log of corrections and must never be clobbered.
render "$KIT/core/constitution.md" "$CLAUDE_DIR/core/constitution.md"
if [[ -s "$CLAUDE_DIR/CLAUDE.md" ]] && ! grep -q "core/constitution.md" "$CLAUDE_DIR/CLAUDE.md"; then
  printf '\n@core/constitution.md\n' >> "$CLAUDE_DIR/CLAUDE.md"
  echo "  + @core/constitution.md подключён в CLAUDE.md"
fi
for f in SOURCES.md open-threads.md; do
  if [[ -s "$CLAUDE_DIR/core/$f" ]]; then
    echo "  = core/$f уже есть, не трогаю"
  else
    render "$KIT/core/$f" "$CLAUDE_DIR/core/$f"
  fi
done
mkdir -p "$CLAUDE_DIR/docs"
render "$KIT/docs/agent-self-audit.md" "$CLAUDE_DIR/docs/agent-self-audit.md"
(( BACKED == 0 )) || echo "  сохранил $BACKED старых файлов в $BACKUP_DIR"

# Hook registration. Matchers mirror what the gates actually intercept.
python3 - "$SETTINGS" "$CLAUDE_DIR" <<'PY'
import json, pathlib, sys

settings, claude_dir = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(settings.read_text()) if settings.exists() else {}
hooks = data.setdefault("hooks", {})

WIRING = [
    ("PreToolUse",  "Bash",                 "block-dangerous.sh",        5),
    ("PreToolUse",  "Bash",                 "block-selfmatching-pgrep.sh", 5),
    ("PreToolUse",  "Write|Edit|MultiEdit", "block-red-zone.sh",         5),
    ("PreToolUse",  "Bash|Write|Edit",      "block-masked-secret.sh",    5),
    ("PostToolUse", "Bash",                 "truncate-bash-output.sh",   5),
    ("PostToolUse", "Edit|Write|MultiEdit", "lesson-needs-mechanism.sh", 5),
    ("PostToolUse", "Edit|Write|MultiEdit", "cyrillic-guard.sh",         5),
    ("PostToolUse", "Edit|Write|MultiEdit", "ruff-check.sh",             5),
    ("PostToolUse", "Bash",                 "log-commands.sh",           5),
    ("PreToolUse",  "Write|Edit|MultiEdit", "protect-archive.sh",        5),
    ("PreToolUse",  "Bash",                 "nudge-context-economy.sh",  5),
    ("PreToolUse",  "Bash",                 "tz-guard.sh",               5),
    ("PreToolUse",  "mcp__dashi-channel__reply", "owner-time-guard.sh",  5),
    ("SessionStart", "",                   "session-start-hint.sh",     5),
    ("PreCompact",  "",                     "precompact-save.sh",       10),
    # Слив в долгую память: без него сервер OpenViking стоит, а писать в него нечем.
    ("PreCompact",  "",                     "flush-to-openviking.sh",   90),
    ("UserPromptSubmit", "",                "echo-last-turn-cost.sh",    5),
    ("UserPromptSubmit", "",                "owner-clock.sh",            5),
    ("UserPromptSubmit", "",                "register-mirror.sh",        5),
    ("UserPromptSubmit", "",                "rule-inject.sh",            5),
    # Долгая память в обе стороны: подсказка прошлых ходов на входе и
    # запись эпизода на выходе. Без них сервер памяти стоит вхолостую.
    ("UserPromptSubmit", "",                "ov-recall.py",              8),
    ("Stop",        "",                     "ov-digest-capture.py",     10),
    # Конец хода оставляет состояние на диске: что правил, что закоммитил,
    # что назвал следующим шагом. Иначе обрыв сессии уносит это с собой.
    ("Stop",        "",                     "session-state.py",         15),
    ("Stop",        "",                     "usage-logger.py",          10),
    ("Stop",        "",                     "stop-check-syntax.sh",     10),
    ("UserPromptSubmit", "",                "correction-detector.sh",    5),
    ("Stop",        "",                     "capture-open-threads.py",  10),
    ("Stop",        "",                     "stop-verify-gate.py",      10),
    ("Stop",        "",                     "stop-proxy-gate.py",       10),
    ("Stop",        "",                     "stop-register-gate.py",    10),
    ("Stop",        "",                     "stop-closeout-gate.py",    10),
    ("Stop",        "",                     "stop-blocker-gate.py",     10),
    ("Stop",        "",                     "promise-alarm.py",         25),
]

added = 0
for event, matcher, name, timeout in WIRING:
    path = f"{claude_dir}/hooks/{name}"
    cmd = path if name.endswith(".sh") else f"/usr/bin/python3 {path}"
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == cmd for e in entries for h in e.get("hooks", [])):
        continue
    slot = next((e for e in entries if e.get("matcher", "") == matcher), None)
    if slot is None:
        slot = {"matcher": matcher, "hooks": []}
        entries.append(slot)
    slot["hooks"].append({"type": "command", "command": cmd, "timeout": timeout})
    added += 1

# Окно контекста: без него Claude Code считает потолок в 200k, и автосжатие
# дёргает разговор вдвое чаще нужного. Хозяин 11.09.2026: «сделай тоже 400».
env = data.setdefault("env", {})
env.setdefault("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "400000")

settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"  хуков зарегистрировано: {added} (уже стояло: {len(WIRING) - added})")
PY

# Утренние задачи в кроне: будильник по срокам, сводка леджера, советник по
# обновлениям, самопроверка, отчёт о состоянии сервера. Раньше их ставил только
# полный install-agent.sh — агент, обновлённый по гайду «Update плагина» или
# через /update, получал скрипты, но кроны ему молчали (Саня 31.08). Теперь
# кроны — часть комплекта: этот скрипт гоняется и установщиком, и на каждом
# /update (dashi-ctl update), так что доезжает и до агентов, поднятых раньше.
# Крон живёт по часам СЕРВЕРА, сводку читает хозяин — считаем час под его 09:00.
# KIT_NO_CRON=1 — раскладка без правки крона (песочница, чужой тест): иначе
# прогон переписал бы боевой крон того, кто его гоняет.
OWNER_TZ="${OWNER_TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
# Пояс хозяина файлом: его читает rule-inject.sh, чтобы напоминать про время
# в ЕГО часах, а не в серверных. Без файла хук про время молчит.
printf '%s\n' "$OWNER_TZ" > "$CLAUDE_DIR/core/owner-tz"
# python3 -c, не heredoc: вложенный heredoc внутри $( ) вешал установку на stdin.
DIG_H="$(OWNER_TZ="$OWNER_TZ" python3 -c 'import os,datetime as dt,zoneinfo; own=zoneinfo.ZoneInfo(os.environ["OWNER_TZ"]); srv=dt.datetime.now().astimezone().tzinfo; print(dt.datetime.now(own).replace(hour=9,minute=0,second=0,microsecond=0).astimezone(srv).hour)' 2>/dev/null || true)"
[[ -n "$DIG_H" ]] || { DIG_H=7; echo "  ! не смог посчитать пояс ($OWNER_TZ, нет tzdata?) — сводка в 07:00 по серверу"; }
# Порядок утра (минуты после часа сводки): 00 сводка, 10 советник по обновлениям
# (что вышло нового + напоминание про /update), 20 самопроверка (хуки, крон,
# канарейка, модель, память — шлёт ТОЛЬКО подозрения), 30 будильник по срокам
# и отчёт о сервере (диск, память, сервисы, вход в Claude — шлётся всегда).
CRON_SCRIPTS=(promise-sweeper.py open-threads-digest.py update-notify.sh self-audit-morning.sh health-daily.sh job-watch.py job-fail-watch.py memory-index-trim.py fallback-reply-sweeper.sh claude-link-guard.sh auth-alive-watch.sh multichat-nudge.sh dead-letter-digest.py stack-updates-check.py api-fail-watch.py)
CRON_LINES=(
  "0 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/open-threads-digest.py --send >> $WORKSPACE/logs/open-threads-digest.log 2>&1"
  "10 $DIG_H * * * /bin/bash $WORKSPACE/bin/update-notify.sh >> $WORKSPACE/logs/update-notify.log 2>&1"
  "20 $DIG_H * * * /bin/bash $WORKSPACE/bin/self-audit-morning.sh >> $WORKSPACE/logs/self-audit.log 2>&1"
  "30 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/promise-sweeper.py >> $WORKSPACE/logs/promise-sweeper.log 2>&1"
  "30 $DIG_H * * * /bin/bash $WORKSPACE/bin/health-daily.sh >> $WORKSPACE/logs/health-daily.log 2>&1"
  "40 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/dead-letter-digest.py >> $WORKSPACE/logs/dead-letter.log 2>&1"
  # Индекс памяти грузится в каждую сессию целиком: перерос лимит -- молча
  # обрезается, и агент теряет часть памяти. Раз в сутки ужимаем сами.
  "40 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/memory-index-trim.py --apply >> $WORKSPACE/logs/memory-trim.log 2>&1"
  # Сторож фоновых задач: старт без финиша + мёртвый процесс = сообщение хозяину.
  # Интервал в минутах, от часового пояса не зависит.
  "*/2 * * * * /usr/bin/python3 $WORKSPACE/bin/job-watch.py >> $WORKSPACE/logs/job-watch.log 2>&1"
  # Сторож провалов: след ошибки в логах -> задание агенту чинить самому, а не
  # счётчик «ошибок N» хозяину в чат. Интервал в минутах, пояс не при чём.
  "*/20 * * * * /usr/bin/python3 $WORKSPACE/bin/job-fail-watch.py >> $WORKSPACE/logs/job-fail-watch.log 2>&1"
  # Догоняльщик ответов: Stop-хук читает финальный текст из транскрипта и на
  # разросшемся файле не успевает к сбросу на диск -- ответ хозяину пропадает
  # молча (gorbot 19.09.2026, три вопроса из группы). Повторный прогон того же
  # хука досылает; дубль невозможен, у хука своя отметка. Минуты, пояс не при чём.
  "*/2 * * * * /bin/bash $WORKSPACE/bin/fallback-reply-sweeper.sh $WORKSPACE $AGENT >> $WORKSPACE/logs/fallback-sweeper.log 2>&1"
  # Канарейка крона: минутная задача трогает файл, самопроверка утром смотрит
  # его свежесть. Без неё смерть расписания не видна ниоткуда (27.08.2026 -- 6
  # часов простоя), а self-audit.py каждое утро кричит «КРОН НЕ РАБОТАЕТ».
  "* * * * * /usr/bin/touch $WORKSPACE/data/cron-heartbeat"
  # Ярлык claude после автообновления замыкался сам на себя, и ВСЕ фоновые
  # задачи молча падали (координатор, 29.08.2026). Сторож чинит, а не жалуется.
  "*/15 * * * * /bin/bash $WORKSPACE/bin/claude-link-guard.sh $WORKSPACE >> $WORKSPACE/logs/claude-link-guard.log 2>&1"
  # Вход протухает по жёсткому сроку и ничем не продлевается: агент просто
  # замолкает, и хозяин узнаёт это из тишины. Пробный запрос раз в 6 часов.
  "7 */6 * * * /bin/bash $WORKSPACE/bin/auth-alive-watch.sh $WORKSPACE >> $WORKSPACE/logs/auth-alive-watch.log 2>&1"
  # Вопрос из группы лежит в inbox и ждёт, пока сессия освободится: у
  # координатора такой провисел полтора часа (29.08.2026). Толкаем сессию.
  "*/2 * * * * /bin/bash $WORKSPACE/bin/multichat-nudge.sh $WORKSPACE >> $WORKSPACE/logs/multichat-nudge.log 2>&1"
  # Weekly versions digest (Monday, after the morning slots): Claude Code, bun,
  # the bridge, long-term memory. REPORT-ONLY -- it never updates anything.
  "50 $DIG_H * * 1 /usr/bin/python3 $WORKSPACE/bin/stack-updates-check.py --send >> $WORKSPACE/logs/stack-updates.log 2>&1"
  # An external API answering 401/403 or empty three times in a row goes silent
  # otherwise: one message to the owner per source per day. Minutes, no tz.
  "*/30 * * * * /usr/bin/python3 $WORKSPACE/bin/api-fail-watch.py >> $WORKSPACE/logs/api-fail-watch.log 2>&1"
)
if [[ -n "${KIT_NO_CRON:-}" ]]; then
  echo "  крон не трогаю (KIT_NO_CRON)"
else
  # Смотрим ТОЛЬКО на строки этого workspace: у второго агента под тем же
  # пользователем свои строки, чужие не трогаем. Час мог измениться (--tz) или
  # добавился новый скрипт — тогда свои строки переписываем, а не пропускаем.
  # Расписание принадлежит ПОЛЬЗОВАТЕЛЮ агента, а не тому, кто запустил
  # установщик. Из-под root строки уезжали в рутовское расписание, а у агента
  # оставались свои старые: те же задачи выполнялись ДВАЖДЫ, и логи в папке
  # агента создавались от root, так что сам агент в них писать уже не мог
  # (найдено у gorbot 20.09.2026 -- семь задач-двойников).
  WS_OWNER="$(stat -c %U "$WORKSPACE" 2>/dev/null || id -un)"
  if [[ "$(id -u)" -eq 0 && "$WS_OWNER" != "$(id -un)" ]]; then
    SCHED=(crontab -u "$WS_OWNER")
  else
    SCHED=(crontab)
  fi
  CUR="$("${SCHED[@]}" -l 2>/dev/null || true)"
  MISSING=0
  for line in "${CRON_LINES[@]}"; do grep -qxF "$line" <<<"$CUR" || MISSING=1; done
  if (( MISSING == 0 )); then
    echo "  утренние задачи уже в кроне: 09:00 по $OWNER_TZ (на сервере $DIG_H:00)"
  else
    OWN=(); for s in "${CRON_SCRIPTS[@]}"; do OWN+=(-e "$WORKSPACE/bin/$s"); done
    # The heartbeat line names no bin/ script: without it here every rewrite
    # kept the old copy and appended a new one (Smith, 28.09.2026 -- two copies).
    OWN+=(-e "$WORKSPACE/data/cron-heartbeat")
    if grep -qF "${OWN[@]}" <<<"$CUR"; then verb="переставлены на"; else verb="в кроне:"; fi
    { grep -vF "${OWN[@]}" <<<"$CUR" || true
      printf '%s\n' "${CRON_LINES[@]}"; } | "${SCHED[@]}" - \
      && echo "  утренние задачи (сводка, советник, самопроверка, будильник, отчёт о сервере) $verb 09:00 по $OWNER_TZ (на сервере $DIG_H:00)" \
      || echo "  ! не смог прописать крон — поставь руками"
  fi
fi

# Долгая память (OpenViking). Ставим сразу, с заделом на будущее: денег не
# стоит -- эмбеддинги локальные, пересказы на ключе, который уже лежит на этой
# машине. Не хватает железа или нет docker -- скрипт сам пропускает шаг, а
# агент попросит ключ у хозяина, когда память наберёт вес (bin/memory-key-ask.py).
# KIT_NO_MEMORY=1 -- раскладка без долгой памяти (песочница, слабый VPS).
if [ "${KIT_NO_MEMORY:-0}" != "1" ] && [ -x "$KIT/scripts/setup-memory.sh" ]; then
  "$KIT/scripts/setup-memory.sh" --workspace "$WORKSPACE" --agent "$AGENT" \
    || echo "  ! долгая память не встала -- смотри вывод выше"
fi

echo "  комплект разложен в $CLAUDE_DIR"
