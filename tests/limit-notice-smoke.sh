#!/usr/bin/env bash
# Смоук: уведомление о лимите подписки. Подсовываем скрипту текст панели и
# фальшивый отправитель, проверяем: одно уведомление на окно с верным HH:MM,
# без повтора на следующей минуте, старый текст (сброс в прошлом) не считается
# лимитом, «снова на связи» ровно один раз, вывод команд с той же фразой мимо.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LN="$ROOT/scripts/limit-notice.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"; mkdir -p "$WS/.claude/core" "$WS/data"
echo "Asia/Yekaterinburg" > "$WS/.claude/core/owner-tz"
SENT="$TMP/sent"; : > "$SENT"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
printf '%s\n---\n' "\$1" >> "$SENT"
EOF
chmod +x "$TMP/notify"
export DASHI_WORKSPACE="$WS" LIMIT_NOTIFY_CMD="$TMP/notify" LIMIT_PANE_FILE="$TMP/pane"

fail() { echo "FAIL: $1" >&2; echo "--- sent:" >&2; cat "$SENT" >&2; exit 1; }
# epoch <«YYYY-MM-DD HH:MM» по Перми>
epoch() { TZ=Asia/Yekaterinburg date -d "$1" +%s; }
run() { LIMIT_NOW="$(epoch "$1")" python3 "$LN" channel-test; }   # run <время по Перми>
count() { grep -c -- '^---$' "$SENT" || true; }
pane() {  # pane <строка лимита или пусто> -- экран агента с этой строкой над вводом
  {
    echo "⏺ Готово, отчёт отправил."
    echo
    [[ -n "$1" ]] && printf '%s\n' "$1"
    echo
    echo "────────────────────────────────────────"
    echo "❯ "
    echo "────────────────────────────────────────"
    echo "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    printf '\n\n\n'
  } > "$TMP/pane"
}

# Точный формат с живого агента (Claude Code 2.1.292, 09.10.2026)
LIVE="⏺ You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)"

# 1. Первый упор: одно уведомление, время 15:40 по Перми, ссылка на страницу лимитов
pane "$LIVE"
run "2026-10-09 11:10"
[[ "$(count)" == 1 ]] || fail "на первом упоре должно уйти ровно одно уведомление"
grep -q 'Братан, лимит кончился, давай на перекур. Вернусь примерно в 15:40 (по Перми), сам продолжу как только откроется, дёргать не надо.' "$SENT" \
  || fail "текст уведомления или время не те"
grep -q 'https://claude.ai/settings/usage' "$SENT" || fail "нет ссылки на страницу лимитов"
echo "✓ первый упор: одно уведомление, «в 15:40 (по Перми)»"

# 2. Следующая минута, тот же текст -- молчим
run "2026-10-09 11:11"; run "2026-10-09 12:30"
[[ "$(count)" == 1 ]] || fail "повтор уведомления в том же окне"
echo "✓ в том же окне не повторяется"

# 3. Сброс прошёл, на экране остался старый текст -- это не лимит: «снова на связи» один раз
run "2026-10-09 15:41"
[[ "$(count)" == 2 ]] || fail "после сброса нет сообщения «снова на связи»"
tail -2 "$SENT" | head -1 | grep -qx 'Лимит отпустил, я снова на связи.' || fail "не тот текст возврата"
run "2026-10-09 15:42"; run "2026-10-09 16:30"
[[ "$(count)" == 2 ]] || fail "«снова на связи» повторилось, или старый текст принят за новый упор"
echo "✓ возврат: одно «снова на связи», старый текст после сброса не будит"

# 4. Без состояния: старый текст лимита (сброс уже прошёл) игнорируется
rm -f "$WS/data/limit-notice.state"; : > "$SENT"
run "2026-10-09 16:00"
pane "⏺ You've hit your weekly limit · resets Oct 8, 9am (Asia/Yekaterinburg)"
run "2026-10-09 16:01"
[[ "$(count)" == 0 ]] || fail "старый текст лимита (сброс в прошлом) принят за упор"
echo "✓ старый текст (сброс в прошлом) не считается"

# 5. Вывод команд с той же фразой -- мимо
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
cat > "$TMP/pane" <<'EOF'
⏺ Bash(grep -r "You've hit your" logs/)
  ⎿  logs/verbose.jsonl:{"text": "You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)"}
     logs/watch.log:You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)
     === report.txt === You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)
← dashi-channel: глянь, что значит You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)
⏺ You've hit your monthly spend limit · raise it at https://claude.ai/settings/usage · your session limit resets 3:40pm (Asia/Yekaterinburg)
⏺ You've hit your fast limit · resets in 5m

────────────────────────────────────────
❯ You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)
────────────────────────────────────────
EOF
run "2026-10-09 11:10"
[[ "$(count)" == 0 ]] || fail "вывод команды / траты / быстрый режим / ввод приняты за лимит подписки"
echo "✓ вывод команд, лимит трат и строка ввода не считаются"

# 6. Недельный лимит с датой, перенос строки узкой панелью; время не сегодня -> с датой
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
pane "⏺ You've hit your weekly limit · resets Oct 12, 9am
  (Asia/Yekaterinburg)"
run "2026-10-09 11:10"
grep -q 'Вернусь примерно 12.10 в 09:00 (по Перми)' "$SENT" || fail "недельный лимит с датой/переносом разобран неверно"
echo "✓ недельный лимит: «12.10 в 09:00», перенос строки не мешает"

# 7. Сессия ночью: «resets 2am» в 23:00 -- это завтра, живой лимит, а не старый
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
pane "⏺ You've hit your session limit · resets 2am (Asia/Yekaterinburg) · progress saved"
run "2026-10-09 23:00"
grep -q 'Вернусь примерно 10.10 в 02:00 (по Перми)' "$SENT" || fail "сброс после полуночи не распознан"
# ...а та же строка в 08:00 -- старая (окно сессии не длиннее 5 ч)
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
run "2026-10-10 08:00"
[[ "$(count)" == 0 ]] || fail "строка «resets 2am» в 08:00 принята за живой лимит"
echo "✓ сброс через полночь живой, тот же текст утром -- старый"

# 8. Не Пермь -- просто HH:MM, без «(по Перми)»; время в поясе хозяина
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
echo "Europe/Moscow" > "$WS/.claude/core/owner-tz"
pane "$LIVE"
run "2026-10-09 11:10"
grep -q 'Вернусь примерно в 13:40, сам' "$SENT" || fail "для Москвы ожидалось «в 13:40» без пометки"
echo "✓ другой пояс хозяина: «в 13:40» без «(по Перми)»"

# 9. Окно лимита висит 10+ минут после сброса -- одна эскалация, клавиш не жмём
echo "Asia/Yekaterinburg" > "$WS/.claude/core/owner-tz"
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
pane "$LIVE"; run "2026-10-09 11:10"
cat > "$TMP/pane" <<'EOF'
⏺ You've hit your session limit · resets 3:40pm (Asia/Yekaterinburg)

 What do you want to do?
 ❯ 1. Stop and wait for limit to reset
   2. Upgrade your plan
EOF
run "2026-10-09 15:45"
[[ "$(count)" == 1 ]] || fail "окно лимита ещё открыто -- рано говорить «снова на связи»"
run "2026-10-09 15:51"; run "2026-10-09 15:52"
[[ "$(count)" == 2 ]] || fail "эскалация не ушла или ушла дважды"
grep -q 'tmux attach -t channel-test' "$SENT" || fail "в эскалации нет подсказки, как закрыть окно"
pane ""; run "2026-10-09 15:53"
[[ "$(count)" == 3 ]] && tail -2 "$SENT" | head -1 | grep -qx 'Лимит отпустил, я снова на связи.' \
  || fail "после закрытия окна нет «снова на связи»"
! grep -q 'send-keys' "$LN" || fail "скрипт лимита не должен жать клавиши"
echo "✓ эскалация одна, клавиш нет"

# 10. Отправка упала -- состояние не пишется, на следующей минуте повтор
: > "$SENT"; rm -f "$WS/data/limit-notice.state"
pane "$LIVE"
LIMIT_NOTIFY_CMD=/bin/false run "2026-10-09 11:10"
[[ ! -s "$WS/data/limit-notice.state" ]] || fail "состояние записано, хотя отправка упала"
run "2026-10-09 11:11"
[[ "$(count)" == 1 ]] || fail "после неудачной отправки нет повтора"
echo "✓ неудачная отправка повторяется"

# Проводка: сторож модалок зовёт скрипт
grep -q 'limit-notice.py' "$ROOT/scripts/modal-watch.sh" || fail "modal-watch.sh не зовёт limit-notice.py"
echo "OK: limit-notice"
