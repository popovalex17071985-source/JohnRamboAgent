#!/usr/bin/env bash
# Смоук комплекта дисциплины: раскатываем в песочницу и проверяем, что гейты
# ЖИВЫЕ, а не просто скопированы. Хук, который ни разу не сработал, — не механизм.
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)/agent-kit"
INSTALLER="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-agent.sh"
fail() { echo "✗ $1" >&2; exit 1; }

bash -n "$KIT/install-kit.sh" || fail "синтаксис install-kit.sh"
grep -q "install-kit.sh" "$INSTALLER" || fail "установщик не зовёт комплект"
# Утренние кроны (сводка, будильник, советник, самопроверка, отчёт о сервере)
# ставит сам комплект (f7e3907 + слияние с main 02.09), не установщик: так они
# доезжают и через /update. Установщик ставит только канарейку планировщика.
for s in "open-threads-digest.py --send" promise-sweeper.py update-notify.sh self-audit-morning.sh health-daily.sh; do
  grep -q "$s" "$KIT/install-kit.sh" || fail "комплект не ставит крон: $s"
done
grep -q -- "--tz '\$OWNER_TZ'" "$INSTALLER" || fail "установщик не передаёт --tz комплекту"
grep -q "DASHI_OWNER_TZ=" "$INSTALLER" || fail "пояс хозяина не пишется в channel.env"
grep -q "cron-heartbeat" "$INSTALLER" || fail "установщик не ставит канарейку планировщика"
# dashi-ctl update раскатывает комплект — с поясом хозяина и в тот же settings.json
grep -q 'DASHI_OWNER_TZ=//p. \$ENV_FILE' "$INSTALLER" || fail "dashi-ctl update не читает пояс хозяина"
grep -q "/home/\$SERVICE_USER/.claude/settings.json' --tz" "$INSTALLER" || fail "dashi-ctl update зовёт комплект не с тем settings.json/--tz"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/core"
# crontab — подменный: комплект пишет в крон, а тест не должен трогать живой
# крон того, кто его гоняет (раньше спасало только то, что строки уже стояли)
mkdir -p "$T/shim"; export CRONTAB_FILE="$T/crontab.txt"
cat > "$T/shim/crontab" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -l) cat "$CRONTAB_FILE" 2>/dev/null ;;
  -)  cat > "$CRONTAB_FILE" ;;
  *)  echo "shim: unsupported $*" >&2; exit 1 ;;
esac
SH
chmod +x "$T/shim/crontab"; export PATH="$T/shim:$PATH"
# Чужая строка в кроне (другой агент) — комплект обязан её не трогать
echo "30 7 * * * /usr/bin/python3 /srv/other/bin/promise-sweeper.py" > "$CRONTAB_FILE"
printf '# Агент\n\n@core/rules.md\n' > "$T/.claude/CLAUDE.md"
printf '# Правила и правки\n- правка хозяина\n' > "$T/.claude/core/rules.md"

bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke >/dev/null \
  || fail "install-kit упал"

# Личные правки хозяина комплект не трогает
grep -q "правка хозяина" "$T/.claude/core/rules.md" || fail "затёр core/rules.md хозяина"
[[ -s "$T/.claude/core/constitution.md" ]] || fail "нет конституции"
grep -q "core/constitution.md" "$T/.claude/CLAUDE.md" || fail "конституция не подключена в CLAUDE.md"

# Плейсхолдеры обязаны быть подставлены — иначе хук молча смотрит в никуда
! grep -rq "__CLAUDE_DIR__\|__CHAT_ID__\|__AGENT__" "$T" || fail "остались плейсхолдеры"

n=$(python3 -c "
import json;d=json.load(open('$T/.claude/settings.json'))
print(sum(len(e['hooks']) for a in d['hooks'].values() for e in a))")
# Число не прибито гвоздями: комплект растёт, а сверка «ровно 9» протухла и
# держала тест красным (11.09). Смысл проверки в другом -- каждый
# зарегистрированный хук должен указывать на существующий файл, иначе он
# молча не сработает. Пустой список тоже недопустим.
(( n >= 9 )) || fail "зарегистрировано хуков: $n -- комплект недоставился"
python3 -c "
import json,os,sys
d=json.load(open('$T/.claude/settings.json'))
bad=[h['command'] for a in d['hooks'].values() for e in a for h in e['hooks']
     if not os.path.exists(h['command'].split()[-1].strip('\"'))]
sys.exit('хуки указывают в никуда: ' + ', '.join(bad) if bad else 0)
" || fail "зарегистрирован хук без файла"

H="$T/.claude/hooks"
# 1. опасная команда
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /var/data"}}' \
  | "$H/block-dangerous.sh" >/dev/null 2>&1 && fail "опасная команда прошла"
# 2. запись секрета
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x/api.key"}}' \
  | "$H/block-red-zone.sh" >/dev/null 2>&1 && fail "запись секрета прошла"
# 2b. СВОЙ secrets/ — хранить ключи хозяина там агент обязан (болванка CLAUDE.md)
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$T/secrets/openai.token\"}}" \
  | "$H/block-red-zone.sh" >/dev/null 2>&1 || fail "запись в свой secrets/ заблокирована"
# ...но .env/.key внутри, чужой secrets/, вложенные пути и .ssh — по-прежнему нельзя
for bad in "$T/secrets/.env" "$T/secrets/api.key" "/opt/other/secrets/x.token" \
           "$T/secrets/../.ssh/id_rsa" "$T/secrets/sub/x.token" "$T/.ssh/config"; do
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$bad\"}}" \
    | "$H/block-red-zone.sh" >/dev/null 2>&1 && fail "прошла запись секрета: $bad"
done
# 3. ждун, матчащий сам себя
echo '{"tool_name":"Bash","tool_input":{"command":"until pgrep -f job; do sleep 60; done"}}' \
  | "$H/block-selfmatching-pgrep.sh" | grep -q "\"permissionDecision\": \"deny\"" \
  || fail "самоматчащийся pgrep не отклонён"
# 4. кириллица в конституции
python3 -c "
import json;print(json.dumps({'tool_input':{'file_path':'$T/.claude/core/constitution.md','new_string':'Это длинное русское правило про источники. '*12}}))" \
  | "$H/cyrillic-guard.sh" >/dev/null 2>&1 && fail "кириллица в конституции прошла"
# 5. урок без механизма
echo "{\"tool_input\":{\"file_path\":\"$T/.claude/core/LEARNINGS.md\"}}" \
  | "$H/lesson-needs-mechanism.sh" >/dev/null 2>&1 && fail "урок без механизма прошёл"
# 6. отказ без перебора путей
J="$T/t.jsonl"; python3 - "$J" <<'PY'
import json, sys
rows = [{"type": "user", "message": {"content": "посмотри почему не работает"}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use",
         "name": "mcp__dashi-channel__reply",
         "input": {"text": "Не могу — нет доступа, жду от тебя логин."}}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
PY
echo "{\"transcript_path\":\"$J\",\"session_id\":\"s\"}" \
  | python3 "$H/stop-blocker-gate.py" | grep -q '"decision": "block"' \
  || fail "отказ без перебора не заблокирован"

# Самопроверки перенесённых скриптов
python3 "$T/bin/promise-sweeper.py" --selfcheck >/dev/null || fail "будильник по срокам"
python3 "$T/bin/open-threads-digest.py" --selfcheck >/dev/null || fail "утренняя сводка"
# Сторож индекса памяти: без --apply обязан только смотреть и не падать
python3 "$T/bin/memory-index-trim.py" >/dev/null || fail "сторож индекса памяти"
# Ported watchers: selftests run on the RENDERED copy (placeholders substituted)
for s in whatruns.py stack-updates-check.py api-fail-watch.py; do
  python3 "$T/bin/$s" --selftest >/dev/null || fail "selftest: $s"
done

# Кроны: свои строки поставлены, чужая цела
for s in promise-sweeper.py "open-threads-digest.py --send" update-notify.sh self-audit-morning.sh health-daily.sh "memory-index-trim.py --apply" "stack-updates-check.py --send" api-fail-watch.py; do
  [[ "$(grep -c "$T/bin/$s" "$CRONTAB_FILE")" == 1 ]] || fail "не в кроне: $s"
done
grep -q "/srv/other/bin/promise-sweeper.py" "$CRONTAB_FILE" || fail "затёр чужую строку крона"

# KIT_NO_CRON=1 — крон не трогается вовсе (чужая песочница)
cp "$CRONTAB_FILE" "$T/crontab.before"
KIT_NO_CRON=1 bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke --tz Europe/Moscow >/dev/null
cmp -s "$CRONTAB_FILE" "$T/crontab.before" || fail "KIT_NO_CRON=1 всё равно переписал крон"

# Повторный прогон ничего не задваивает, а локально правленный файл — сначала в бэкап
# Считаем ДО второго прогона: прибитое число хуков протухает с каждым новым
# гейтом, и тест начинает краснеть на исправном комплекте (12.09.2026: ждал 9
# при 28 живых и полгода числился «багом дедупликации»). Инвариант -- НЕ РОС.
count_hooks() { python3 -c "
import json;d=json.load(open('$T/.claude/settings.json'))
print(sum(len(e['hooks']) for a in d['hooks'].values() for e in a))"; }
n1=$(count_hooks)
(( n1 >= 9 )) || fail "хуки не зарегистрированы вовсе: $n1"
echo "# local tweak" >> "$H/block-dangerous.sh"
out="$(bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke)"
grep -q "сохранил 1 старых файлов" <<<"$out" || fail "перезапись без бэкапа: $out"
grep -rq "local tweak" "$T/.kit-backup/"*/.claude/hooks/block-dangerous.sh || fail "бэкап не содержит старую версию"
grep -q "local tweak" "$H/block-dangerous.sh" && fail "хук не обновлён комплектом"
n2=$(count_hooks)
[[ "$n2" == "$n1" ]] || fail "повторный прогон изменил число хуков: было $n1, стало $n2"
[[ "$(grep -c 'core/constitution.md' "$T/.claude/CLAUDE.md")" == 1 ]] || fail "задвоил @include"
# Не прибитое число строк (оно растёт с каждым новым скриптом комплекта), а
# сам инвариант: ни одна строка не встречается дважды.
dups="$(grep -F "$T/bin/" "$CRONTAB_FILE" | sort | uniq -d)"
[[ -z "$dups" ]] || fail "повторный прогон задвоил крон: $dups"
[[ "$(grep -c "$T/bin/" "$CRONTAB_FILE")" -ge 5 ]] || fail "строки комплекта пропали из крона"

# Смена --tz переписывает СВОИ строки (час меняется), а не пропускает их
bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke --tz Asia/Yekaterinburg >/dev/null
h1="$(grep "$T/bin/open-threads-digest.py" "$CRONTAB_FILE" | awk '{print $2}')"
bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke --tz Europe/Moscow >/dev/null
h2="$(grep "$T/bin/open-threads-digest.py" "$CRONTAB_FILE" | awk '{print $2}')"
[[ "$h1" =~ ^[0-9]+$ && "$h2" =~ ^[0-9]+$ && "$h1" != "$h2" ]] || fail "смена --tz не переписала час крона ($h1 -> $h2)"
dups="$(grep -F "$T/bin/" "$CRONTAB_FILE" | sort | uniq -d)"
[[ -z "$dups" ]] || fail "смена --tz задвоила крон: $dups"
# The heartbeat line lives under data/, not bin/ -- the check above misses it.
[[ "$(grep -c "$T/data/cron-heartbeat" "$CRONTAB_FILE")" == 1 ]] || fail "перестройка крона задвоила канарейку"
grep -q "/srv/other/bin/promise-sweeper.py" "$CRONTAB_FILE" || fail "смена --tz затёрла чужую строку"

# Будильник, переживающий рестарт: разложен, исполняемый, время считает по Перми
R="$T/bin/remind-at.sh"
[[ -x "$R" ]] || fail "remind-at.sh не разложен или не исполняемый"
grep -q "__WORKSPACE__" "$R" && fail "в remind-at.sh остался неподставленный путь"
grep -q "Asia/Yekaterinburg" "$R" || fail "remind-at.sh считает время не по Перми"
bash -n "$R" || fail "remind-at.sh не компилируется"
# Сторож обещаний не должен слать в панель, угаданную по шаблону
grep -q "def _session" "$T/bin/promise-sweeper.py" \
  || fail "promise-sweeper всё ещё берёт имя панели из шаблона"

echo "✓ agent-kit smoke ok ($n2 хуков, 6 гейтов сработали, утренние кроны без дублей, идемпотентно)"
