#!/usr/bin/env bash
# Утренний отчёт о состоянии сервера: диск, память, процессор, сервисы агента,
# вход в Claude, планировщик, бэкап. Шлётся хозяину КАЖДОЕ утро, даже когда всё
# зелено — это единственная строчка, по которой видно, что сервер вообще жив.
#
# Отличие от самопроверки (self-audit-morning.sh): та молчит, когда всё хорошо,
# и следит за внутренностями агента. Эта — про железо и сервисы, и говорит всегда.
#
# Вид — список, не таблица: <pre> с колонками по байтам на телефоне разъезжался
# (кириллица в два байта), и два агента хозяев переписали отчёт сами (12.10.2026).
# Сверху «Требует внимания», затем «Не проверено» (пропуск — не тревога, но и не
# молчание), затем «В норме (N)». Время — по поясу хозяина из core/owner-tz.
#
# DRY=1 — напечатать вместо отправки. Швы для тестов: HEALTH_CHECK (своя
# проверка), DASHI_TG_SEND (свой отправщик), HEALTH_NOW (момент, epoch).
set -uo pipefail
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="__CLAUDE_DIR__"
case "$CLAUDE_DIR" in __*) CLAUDE_DIR="$WORKSPACE/.claude" ;; esac
CHECK="${HEALTH_CHECK:-$WORKSPACE/bin/health-check.sh}"
TG_SEND="${DASHI_TG_SEND:-$WORKSPACE/bin/tg-send.py}"
NOW="${HEALTH_NOW:-$(date +%s)}"

OUT=$(bash "$CHECK" 2>&1); EXIT=$?
CLEAN=$(printf '%s\n' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')

case $EXIT in
  0) HEADER="Сервер: всё в порядке" ;;
  1) HEADER="Сервер: есть предупреждения" ;;
  2) HEADER="Сервер: есть проблемы" ;;
  *) HEADER="Сервер: проверка сама упала (код $EXIT)" ;;
esac

# Пояс хозяина пишет установщик (install-kit.sh --tz). Пусто или зоны такой нет —
# время сервера: date с неизвестной TZ молча печатает UTC, и это было бы враньё.
OWNER_TZ="$(head -n1 "$CLAUDE_DIR/core/owner-tz" 2>/dev/null | tr -d '[:space:]')"
if [ -n "$OWNER_TZ" ] && [ -e "/usr/share/zoneinfo/$OWNER_TZ" ]; then
  TS="$(TZ="$OWNER_TZ" date -d "@$NOW" '+%d.%m.%Y %H:%M')"
else
  TS="$(date -d "@$NOW" '+%d.%m.%Y %H:%M')"
fi

# Разбираем строки «| Проверка | Стат | Детали» из health-check.sh.
MSG=$(HEADER="$HEADER" HOST="$(hostname)" TS="$TS" CLEAN="$CLEAN" \
      PYTHONUTF8=1 PYTHONIOENCODING=utf-8 /usr/bin/python3 - <<'PY'
import html
import os

OK = {"OK"}
SKIP = {"SKIP", "ПРОПУЩЕНО", ""}      # пустой статус = проверка ничего не вернула
BAD = {"FAIL": "сбой", "CRIT": "сбой", "ERR": "сбой", "WARN": "внимание"}

rows = []
for ln in os.environ["CLEAN"].splitlines():
    if not ln.startswith("| "):
        continue
    cells = [c.strip() for c in ln[2:].split(" | ")]
    if len(cells) < 2:
        continue
    name, status = cells[0], cells[1].upper()
    detail = " | ".join(cells[2:]).strip()
    if status in OK or status in SKIP or status in BAD:
        rows.append((name, status, detail))

e = html.escape
line = lambda n, d: f"{e(n)} -- {e(d)}" if d else e(n)
bad = sorted((r for r in rows if r[1] in BAD), key=lambda r: BAD[r[1]] != "сбой")
skipped = [r for r in rows if r[1] in SKIP]
good = [r for r in rows if r[1] in OK]

out = [f"<b>{e(os.environ['HEADER'])}</b>", f"{e(os.environ['HOST'])} · {e(os.environ['TS'])}"]
if bad:
    out += ["", "<b>Требует внимания</b>"]
    out += [f"<b>{e(n)}</b> [{BAD[s]}] -- {e(d)}" for n, s, d in bad]
if skipped:
    out += ["", "<b>Не проверено</b>"]
    out += [line(n, d or "проверка ничего не вернула") for n, _, d in skipped]
if good:
    out += ["", f"<b>В норме ({len(good)})</b>"]
    out += [line(n, d) for n, _, d in good]
if not rows:
    out += ["", "<pre>" + e(os.environ["CLEAN"][-3000:]) + "</pre>"]
print("\n".join(out))
PY
)

[ -n "${DRY:-}" ] && { printf '%s\n' "$MSG"; exit 0; }
# След на диске обязателен: без него «отчёт не пришёл» и «отчёт не запускался»
# неотличимы, а самопроверка судит живость задачи по возрасту её лога.
printf '%s [health-daily] %s\n' "$(date -Is)" "$(printf '%s' "$CLEAN" | tr '\n' ' ' | cut -c1-400)" \
  >> "$WORKSPACE/logs/health-daily.log"
/usr/bin/python3 "$TG_SEND" "$MSG" --html
