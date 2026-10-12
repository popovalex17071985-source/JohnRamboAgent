#!/usr/bin/env bash
# Smoke: health-daily.sh -- the morning server report is a phone-friendly list,
# not a <pre> table: problems on top, skipped checks in their own block (never
# dropped, never an alarm), «В норме (N)», time in the OWNER's zone, no English
# «Verdict:». Seams: HEALTH_CHECK (stub table), DASHI_TG_SEND (stub sender),
# HEALTH_NOW (fixed epoch). The second half runs the real health-check.sh so the
# list and the table it parses cannot drift apart.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
WS="$T/ws"; CD="$WS/.claude"; mkdir -p "$WS/bin" "$WS/logs" "$WS/data" "$CD/core"
fail() { echo "✗ $*"; printf '%s\n' "${MSG:-}" | sed 's/^/    /'; exit 1; }

render() {  # same substitution install-kit.sh does on copy
  sed -e "s|__CLAUDE_DIR__|$CD|g" -e "s|__WORKSPACE__|$WS|g" \
      -e "s|__CHAT_ID__|42|g" -e "s|__AGENT__|smoke|g" "$1" > "$2"
}
render "$ROOT/agent-kit/bin/health-daily.sh" "$WS/bin/health-daily.sh"

# Stub check: the exact row format of health-check.sh render_row.
STUB="$T/check.sh"
stub() {  # $1 = exit code
  cat > "$STUB" <<SH
#!/usr/bin/env bash
sep="+----------------------+------+-----------------------------------------"
echo "\$sep"
printf '| %-20s | %-4s | %s\n' "Проверка" "Стат" "Детали"
echo "\$sep"
printf '| %-20s | %-4s | %s\n' "Диск /"        "OK"   "45%"
printf '| %-20s | %-4s | %s\n' "RAM"           "OK"   "54% (2148M / 3911M)"
printf '| %-20s | %-4s | %s\n' "Карантин"      "WARN" "a <b> & c | d"
printf '| %-20s | %-4s | %s\n' "Срок входа"    "skip" "не удалось прочитать"
printf '| %-20s | %-4s | %s\n' "Бэкап"         "FAIL" "50ч назад (>48ч)"
printf '| %-20s | %-4s | %s\n' "Долгая память" "ok"   "сервис памяти отвечает"
echo "\$sep"
exit $1
SH
}
NOW=1760245200        # fixed moment; the owner's zone decides what clock it shows
OWNER=Pacific/Kiritimati   # UTC+14: far from any server, so a server-zone time cannot pass
echo "$OWNER" > "$CD/core/owner-tz"
dry() { HEALTH_CHECK="$STUB" HEALTH_NOW="$NOW" DRY=1 bash "$WS/bin/health-daily.sh"; }

stub 2; MSG="$(dry)"
[ "$(printf '%s\n' "$MSG" | sed -n 1p)" = "<b>Сервер: есть проблемы</b>" ] || fail "заголовок при коде 2"
want="$(hostname) · $(TZ="$OWNER" date -d "@$NOW" '+%d.%m.%Y %H:%M')"
[ "$(printf '%s\n' "$MSG" | sed -n 2p)" = "$want" ] || fail "вторая строка: ждали «$want» (сервер + время хозяина)"
grep -q 'Verdict' <<<"$MSG" && fail "английская строка Verdict в сообщении"
grep -q '<pre>' <<<"$MSG" && fail "таблица в <pre> вместо списка"
grep -qx '<b>Требует внимания</b>' <<<"$MSG" || fail "нет блока «Требует внимания»"
att="$(sed -n '/^<b>Требует внимания<\/b>$/,/^$/p' <<<"$MSG")"
[ "$(grep -c ' -- ' <<<"$att")" = 2 ] || fail "в «Требует внимания» ждали ровно 2 строки"
[ "$(grep -n 'Бэкап' <<<"$att" | cut -d: -f1)" -lt "$(grep -n 'Карантин' <<<"$att" | cut -d: -f1)" ] \
  || fail "сбой должен стоять выше предупреждения"
grep -q 'Срок входа' <<<"$att" && fail "пропущенная проверка попала в тревогу"
grep -qF 'a &lt;b&gt; &amp; c | d' <<<"$MSG" || fail "детали не экранированы или обрезаны по |"
grep -qx '<b>Не проверено</b>' <<<"$MSG" || fail "нет блока «Не проверено»"
grep -qx 'Срок входа -- не удалось прочитать' <<<"$MSG" || fail "пропущенная проверка пропала"
grep -qx '<b>В норме (3)</b>' <<<"$MSG" || fail "счётчик «В норме» не 3"
grep -qx 'RAM -- 54% (2148M / 3911M)' <<<"$MSG" || fail "строка RAM"
grep -qx 'Долгая память -- сервис памяти отвечает' <<<"$MSG" || fail "строчный ok не попал в норму"

stub 1; MSG="$(dry)"
[ "$(sed -n 1p <<<"$MSG")" = "<b>Сервер: есть предупреждения</b>" ] || fail "заголовок при коде 1"
stub 0; MSG="$(dry)"
[ "$(sed -n 1p <<<"$MSG")" = "<b>Сервер: всё в порядке</b>" ] || fail "заголовок при коде 0"

# A broken zone file must not print a wrong clock labelled as the owner's.
echo "Nowhere/Atlantis" > "$CD/core/owner-tz"; MSG="$(dry)"
want="$(hostname) · $(date -d "@$NOW" '+%d.%m.%Y %H:%M')"
[ "$(sed -n 2p <<<"$MSG")" = "$want" ] || fail "битый пояс: ждали время сервера"
echo "$OWNER" > "$CD/core/owner-tz"

# The check itself crashed with no rows: say so and show its raw output, escaped.
printf '#!/bin/sh\necho "boom <x>"\nexit 7\n' > "$STUB"; MSG="$(dry)"
[ "$(sed -n 1p <<<"$MSG")" = "<b>Сервер: проверка сама упала (код 7)</b>" ] || fail "заголовок при падении"
grep -qF 'boom &lt;x&gt;' <<<"$MSG" || fail "сырой вывод упавшей проверки не показан"

# Real send path: same text, --html, a trace in the log.
stub 1
cat > "$T/tg-send.py" <<PY
import sys
open("$T/sent.txt", "w").write(sys.argv[1])
open("$T/argv.txt", "w").write(" ".join(sys.argv[2:]))
PY
MSG="$(HEALTH_CHECK="$STUB" HEALTH_NOW="$NOW" DASHI_TG_SEND="$T/tg-send.py" bash "$WS/bin/health-daily.sh")"
[ "$(cat "$T/sent.txt" 2>/dev/null)" = "$(stub 1; HEALTH_CHECK="$STUB" HEALTH_NOW="$NOW" DRY=1 bash "$WS/bin/health-daily.sh")" ] \
  || fail "отправленный текст не совпал с DRY"
grep -qx -- '--html' "$T/argv.txt" || fail "отправка без --html"
grep -q '\[health-daily\]' "$WS/logs/health-daily.log" || fail "нет следа в логе"

# Real health-check.sh: every check of the table reaches the list, none repeats
# its own name in the details.
render "$ROOT/agent-kit/bin/health-check.sh" "$WS/bin/health-check.sh"
HEALTH_TEST=1 bash "$WS/bin/health-check.sh" >"$T/selftest.txt" 2>&1 \
  || { cat "$T/selftest.txt"; fail "самотесты health-check.sh"; }
export CRED_PATH="$T/none.json" TOKEN_ENV="$T/none.env" HOME="$T/home"; mkdir -p "$HOME"
TABLE="$(bash "$WS/bin/health-check.sh" 2>&1)"
MSG="$(HEALTH_NOW="$NOW" DRY=1 bash "$WS/bin/health-daily.sh")"
names="$(grep '^| ' <<<"$TABLE" | awk -F' [|] ' 'NR>1{sub(/^\| /,"",$1); sub(/ +$/,"",$1); print $1}')"
[ "$(grep -c . <<<"$names")" -ge 13 ] || fail "в таблице меньше 13 проверок"
plain="$(sed -E 's#</?b>##g; s/ \[[^]]*\] -- / -- /' <<<"$MSG")"   # tags and [сбой] off
while IFS= read -r n; do
  awk -v p="$n -- " 'index($0, p) == 1 {f = 1} END {exit !f}' <<<"$plain" || fail "проверка «$n» пропала из сообщения"
done <<<"$names"
grep -q 'Verdict' <<<"$MSG" && fail "Verdict в сообщении с настоящей проверкой"
grep -qE '^RAM -- [0-9]+% \([0-9]+M / [0-9]+M\)$' <<<"$plain" || fail "RAM: ждали «RAM -- N% (used / total)»"
grep -qiE '^Бэкап -- бэкап' <<<"$plain" && fail "Бэкап повторяет своё имя"
grep -qiE '^Планировщик -- крон:' <<<"$plain" && fail "Планировщик повторяет «крон:»"
grep -qE '^Диск / -- / ' <<<"$plain" && fail "Диск повторяет «/»"
grep -qE '^CPU load \(1m\) -- load' <<<"$plain" && fail "CPU повторяет «load»"
echo "✓ health-daily smoke ok"
