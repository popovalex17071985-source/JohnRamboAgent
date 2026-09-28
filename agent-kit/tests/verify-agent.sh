#!/bin/bash
# Acceptance check for a freshly installed dashi agent. Runs ON the agent's host.
# Usage: verify-agent.sh <name> [user]
# Prints one line per check: ОК / ПЛОХО, and exits non-zero if anything failed.
set -uo pipefail

NAME="${1:?нужно имя агента}"
USER_NAME="${2:-agent}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
WS="$HOME_DIR/.claude-lab/$NAME"
CD="$WS/.claude"                 # сюда установщик кладёт хуки
SETTINGS="$HOME_DIR/.claude/settings.json"   # а регистрирует их здесь
FAILED=0

say() { # say <ок|плохо> <текст>
  if [ "$1" = ок ]; then echo "  ОК    | $2"; else echo "  ПЛОХО | $2"; FAILED=$((FAILED+1)); fi
}
check() { if eval "$1" >/dev/null 2>&1; then say ок "$2"; else say плохо "$2"; fi; }

echo "=== 1. Служба и процесс ==="
check "systemctl is-active --quiet dashi-$NAME" "служба dashi-$NAME запущена"
check "systemctl is-enabled --quiet dashi-$NAME" "служба включена в автозапуск"
check "sudo -u $USER_NAME tmux has-session -t channel-$NAME" "сессия tmux channel-$NAME жива"

echo "=== 2. Дерево и комплект ==="
check "[ -d '$WS' ]" "рабочая папка на месте"
check "[ -d '$CD/hooks' ]" "папка хуков на месте"
check "[ -s '$SETTINGS' ]" "settings.json не пуст"
check "python3 -c \"import json;json.load(open('$SETTINGS'))\"" "settings.json -- валидный JSON"
HOOKS=$(ls "$CD/hooks" 2>/dev/null | grep -cE '\.(sh|py)$')
[ "${HOOKS:-0}" -ge 25 ] && say ок "хуков разложено: $HOOKS" || say плохо "хуков всего $HOOKS (ждали 25+)"
WIRED=$(python3 -c "
import json;h=json.load(open('$SETTINGS')).get('hooks',{})
print(sum(len(e.get('hooks',[])) for a in h.values() for e in a))" 2>/dev/null)
[ "${WIRED:-0}" -ge 25 ] && say ок "хуков прописано в настройках: $WIRED" || say плохо "прописано всего $WIRED"

echo "=== 3. Ключевые сторожа именно этого агента ==="
for h in promise-alarm.py stop-blocker-gate.py flush-to-openviking.sh ov-recall.py \
         ov-digest-capture.py session-state.py block-dangerous.sh tz-guard.sh \
         block-masked-secret.sh precompact-save.sh; do
  check "[ -f '$CD/hooks/$h' ]" "хук $h на месте"
done

echo "=== 4. Ни одной ссылки на чужую папку ==="
FOREIGN=$(grep -rl "claude-lab/jarvis\|claude-lab/gorbot" "$CD/hooks" "$WS/bin" 2>/dev/null | grep -v "$NAME" | head -5)
[ -z "$FOREIGN" ] && say ок "чужих путей в хуках и скриптах нет" || say плохо "чужие пути: $FOREIGN"
WRONG_WS=$(grep -rn "__WORKSPACE__\|__AGENT__" "$CD/hooks" 2>/dev/null | grep -v Binary | head -3)
[ -z "$WRONG_WS" ] && say ок "плейсхолдеры подставлены везде" || say плохо "остался плейсхолдер: $WRONG_WS"

echo "=== 5. Долгая память ==="
if curl -sf -m 5 http://127.0.0.1:1933/health >/dev/null 2>&1; then
  say ок "сервер памяти отвечает"
  MINE=$(curl -sf -m 10 -X POST http://127.0.0.1:1933/api/v1/search/find \
    -H 'Content-Type: application/json' -H "X-OpenViking-User: $NAME" \
    -d "{\"query\":\"тест\",\"target_uri\":\"viking://user/$NAME/memories\",\"limit\":2}" 2>/dev/null | head -c 40)
  [ -n "$MINE" ] && say ок "свой раздел памяти доступен" || say плохо "свой раздел памяти не отвечает"
  grep -q "user/$NAME/memories" "$CD/hooks/ov-recall.py" 2>/dev/null \
    && say ок "подсказка памяти читает СВОЙ раздел" || say плохо "ov-recall смотрит не в свой раздел"
  grep -q 'X-OpenViking-User' "$CD/hooks/ov_memory.py" 2>/dev/null \
    && say ок "запись памяти уходит в свой раздел" || say плохо "память пишется в общий котёл"
else
  say плохо "сервер памяти не отвечает"
fi

echo "=== 6. Расписание в поясе хозяина ==="
OWNER_TZ=$(cat "$CD/core/owner-tz" 2>/dev/null || echo "?")
say ок "пояс хозяина: $OWNER_TZ"
LINES=$(crontab -u "$USER_NAME" -l 2>/dev/null | grep -c "^[0-9*]")
[ "${LINES:-0}" -ge 5 ] && say ок "задач в расписании: $LINES" || say плохо "в расписании всего $LINES задач"
DIG_H=$(crontab -u "$USER_NAME" -l 2>/dev/null | grep -m1 "open-threads-digest" | awk '{print $2}')
if [ -n "$DIG_H" ]; then
  # Час в кроне -- серверный. Переводим его в пояс хозяина через отметку времени.
  STAMP=$(date -d "today ${DIG_H}:00" +%s 2>/dev/null)
  OWNER_H=$(TZ="$OWNER_TZ" date -d "@$STAMP" +%H 2>/dev/null)
  [ "$OWNER_H" = "09" ] && say ок "утренняя сводка в 09:00 по хозяину (на сервере $DIG_H:00)" \
                        || say плохо "сводка в $DIG_H:00 сервера = $OWNER_H:00 у хозяина, а надо 09"
else
  say плохо "утренней сводки в расписании нет"
fi
check "crontab -u $USER_NAME -l | grep -q dead-letter-digest" "читатель карантина в расписании"
check "crontab -u $USER_NAME -l | grep -q api-fail-watch" "сторож отказов API в расписании"
check "crontab -u $USER_NAME -l | grep -q stack-updates-check" "недельная сводка версий в расписании"

echo "=== 7. Канал ==="
check "[ -s /etc/dashi-plugin/$NAME/channel.env ]" "конфигурация канала на месте"
# Журнал смотрим с момента старта службы, а не за последние десять минут:
# агент, поднятый полчаса назад и спокойно работающий, не должен считаться сбоем.
SINCE=$(systemctl show "dashi-$NAME" -p ActiveEnterTimestamp --value 2>/dev/null)
[ -n "$SINCE" ] || SINCE="-30 min"
check "journalctl -u dashi-$NAME --since '$SINCE' --no-pager | grep -qiE 'listening|started|polling|ready'" \
      "служба отчиталась о старте в журнале"
ERRS=$(journalctl -u "dashi-$NAME" --since "$SINCE" --no-pager 2>/dev/null | grep -ciE "error|exception|traceback")
[ "${ERRS:-0}" -eq 0 ] && say ок "ошибок в журнале нет" || say плохо "ошибок в журнале: $ERRS"

echo
[ "$FAILED" -eq 0 ] && echo "ИТОГ: всё зелёное" || echo "ИТОГ: провалов $FAILED"
exit "$FAILED"
