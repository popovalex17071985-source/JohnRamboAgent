#!/usr/bin/env bash
# Смоук установщика. Полный прогон требует чистого сервера и root, поэтому здесь
# проверяем то, что проверяемо без них: синтаксис, отказ не-root, справку и
# инварианты, потеря которых стоила нам дня при ручной установке.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-agent.sh"
fail() { echo "✗ $1" >&2; exit 1; }

bash -n "$S" || fail "синтаксис"

bash "$S" --help | grep -q "install-agent.sh" || fail "--help молчит"

# Под обычным юзером обязан отказаться, а не наломать дров
if [[ $EUID -ne 0 ]]; then
  out="$(bash "$S" --name test --yes 2>&1 || true)"
  grep -q "под root" <<<"$out" || fail "нет гейта на root"
fi

# Агент НЕ под root: иначе Claude не запускается без подтверждений
grep -q 'adduser --disabled-password' "$S" || fail "не заводит отдельного пользователя"
grep -q 'User=\$SERVICE_USER'          "$S" || fail "юнит крутится не под service-юзером"

# Плагин строго внутри .claude — иначе «no MCP server configured with that name»
grep -q 'PLUGIN_DIR="\$CLAUDE_DIR/dashi-plugin-claude-code/plugin"' "$S" \
  || fail "плагин кладётся мимо workspace"

# Агент не должен получать инструкцию класть ключи туда, откуда гейт не даст их
# прочитать (agent-cant-read-secrets-env-and-secrets-dir, агент Лены 08.09.2026).
grep -q 'config/<service>-creds.json' "$S" || fail "не сказано, куда класть ключи"
grep -q 'secrets from the owner I put into secrets/' "$S" \
  && fail "учит класть секреты в secrets/ -- гейт это запрещает"

# Секреты закрыты от посторонних (660 root:agent — агент правит конфиг сам)
grep -q 'chmod 660 "\$ENV_FILE"' "$S" || fail "конфиг с секретами не закрыт"
# Restart=always безопасен с тех пор, как диалоги жмёт dashi-press-dialogs
grep -q 'Restart=always'          "$S" || fail "сервис должен подниматься сам (Restart=always)"

# Годовой токен вместо 30-дневного логина: setup-token + запись в channel.env
grep -q 'claude setup-token'          "$S" || fail "нет входа через setup-token (годовой токен)"
grep -q 'CLAUDE_CODE_OAUTH_TOKEN='    "$S" || fail "токен не пишется в channel.env"
grep -q -- '--claude-token'           "$S" || fail "нет флага --claude-token для готового токена"

# Модель агента: флаг --model → DASHI_MODEL в channel.env → --model у claude в tmux
grep -q -- '--model)'                 "$S" || fail "нет флага --model"
grep -q 'DASHI_MODEL=\$MODEL'         "$S" || fail "модель не пишется в channel.env"
grep -q 'claude \${DASHI_MODEL:+--model \$DASHI_MODEL}' "$S" || fail "dashi-run не передаёт модель claude"

# Ремонтник-страховка: отдельный бот, отдельный юнит, не под root
grep -q -- '--repair-token'           "$S" || fail "нет флага --repair-token (бот-страховка)"
grep -q 'claude-code-telegram'        "$S" || fail "ремонтник не ставит claude-code-telegram"
grep -q '^CLAUDE_CLI_PATH=\$R_CLI'      "$S" || fail "ремонтник без CLAUDE_CLI_PATH -- SDK возьмёт встроенный старый claude"
! grep -q '^CLAUDE_CLI_PATH=$'        "$S" || fail "пустой CLAUDE_CLI_PATH в .env ремонтника"

echo "✓ install-agent smoke ok"

# 02.09.2026: `read -p ... 2>/dev/null` глотал сам ВОПРОС (bash печатает prompt в stderr) —
# живой прогон на Смите молча висел на «Имя агента». Приглашение обязано доходить до экрана.
grep -qE 'read -r -p "\$__prompt" __val </dev/tty 2>/dev/null' "$S" \
  && fail "ask(): stderr read'а уведён в /dev/null — приглашение не видно" || true

# 02.09.2026: диалог «Do you trust this folder?» с курсором на «No, exit» — слепой Enter выходил из Claude.
grep -q 'grep -qE "❯ \*No, exit"' "$S" || fail "dashi-press-dialogs: нет обработки диалога с выделенным «No, exit»"

# 02.09.2026: Claude Code 2.1.258 не читал plugin/.mcp.json на живом прогоне — мост регистрируется в user-scope.
grep -q 'claude mcp add -s user dashi-channel -- bun ./src/server.ts' "$S" || fail "нет регистрации моста через claude mcp add -s user"

# 02.09.2026: пояс хозяина спрашивается на первой установке (сервер почти всегда
# UTC/MSK) и принимается ГОРОДОМ, а не только IANA-кодом.
grep -q 'ЧАСОВОЙ ПОЯС ХОЗЯИНА' "$S" || fail "установщик не спрашивает часовой пояс"
tzfn="$(mktemp)"; sed -n '/^tz_from_city() {/,/^}/p' "$S" > "$tzfn"; source "$tzfn"; rm -f "$tzfn"
[[ "$(tz_from_city Пермь)"   == Asia/Yekaterinburg ]] || fail "город Пермь не переводится в пояс"
[[ "$(tz_from_city москва)"  == Europe/Moscow      ]] || fail "город москва не переводится в пояс"
[[ "$(tz_from_city Asia/Omsk)" == Asia/Omsk        ]] || fail "готовый код пояса не должен переписываться"
[[ "$(tz_from_city Нарния)"  == Нарния             ]] || fail "незнакомое значение должно возвращаться как есть"
echo "✓ пояс хозяина: вопрос + перевод города в код"
grep -q 'timedatectl set-timezone "$OWNER_TZ"' "$S" || fail "часы сервера не переводятся на пояс хозяина"
grep -q 'if \[\[ ! -f "$ENV_FILE" && -z "$OTHER_AGENTS" && "$SERVER_TZ" != "$OWNER_TZ" \]\]' "$S" \
  || fail "перевод часов должен быть только на первой установке и при одном агенте на хосте"
echo "✓ часы сервера = пояс хозяина (только первая установка)"

# 11.09.2026: в tmux-панель печатали ДВА автомата -- сторож диалогов (слепой
# Enter) и автосжатие (пауза перед своим Enter). Столкновение подтверждало
# «No, exit» и убивало Claude: у агента Гора 15 рестартов за день. Держим
# инвариант: каждое нажатие в панель идёт через замок, и экран пишется в файл.
press_block="$(sed -n '/^cat > \/usr\/local\/bin\/dashi-press-dialogs/,/^chmod 755 \/usr\/local\/bin\/dashi-press-dialogs/p' "$S")"
grep -q 'flock -w' <<<"$press_block" || fail "сторож диалогов жмёт клавиши без замка на панель"
# Ровно ОДНО tmux send-keys -- внутри press(). Больше: нажатие мимо замка.
# Ноль: press() зовёт сам себя (так я и сломал агента Гора 11.09 -- вместо
# нажатий бесконечная рекурсия, старт завис на диалоге dev-каналов).
sk="$(grep -c 'tmux send-keys' <<<"$press_block")"
[[ "$sk" == 1 ]] || fail "в стороже $sk вызовов tmux send-keys, а должен быть ровно один -- внутри press()"
grep -q 'press "\$@" ) || true' <<<"$press_block" && fail "press() зовёт сам себя: рекурсия вместо нажатия"
echo "✓ один писатель на панель: нажатия сторожа под замком"
grep -q 'tmux pipe-pane -o' "$S" || fail "экран сессии не пишется в файл -- падение снова будет немым"
echo "✓ экран сессии пишется в лог"

# 12.09.2026: сторож ввода перезапускал ЖИВОГО агента раз в 25 минут. Две
# причины, обе проверяем тут.
MW="$(dirname "$S")/modal-watch.sh"
# 1. Claude Code подставляет в пустую строку ввода свою подсказку тусклым
#    шрифтом (ESC[2m). Без этой проверки сторож считает её сообщением хозяина.
grep -q '033\[2m' "$MW" || fail "сторож не смотрит на тусклый шрифт подсказки"
grep -q -- '-z "\$ghost"' "$MW" || fail "признак подсказки не влияет на решение сторожа"
echo "✓ подсказка Claude Code не считается залипшим вводом"
# 2. Замок берётся РОВНО один раз на весь скрипт. Второй flock на тот же файл
#    из того же скрипта -- это ожидание собственного замка до таймаута, после
#    которого нажатие молча не уходит (а в журнал пишется, что ушло).
fl="$(grep -c 'flock -w' "$MW")"
[[ "$fl" == 1 ]] || fail "в стороже $fl захватов замка, а должен быть один -- вложенный ждёт сам себя"
echo "✓ замок панели берётся один раз"

# После перезапуска хозяин видит «на связи» -- иначе непонятно, встал агент или нет
grep -q 'перезапуск завершён' "$S" || fail "dashi-run не шлёт пинг «на связи» после старта"

# Подсказки владельцу про rclone: у «rclone authorize» нет флагов --client-id /
# --client-secret (ID и секрет -- позиционно), а brew на чистом маке нет.
# 02.10.2026 живая установка упала на обоих.
INST="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-agent.sh"
GUIDE="$(cd "$(dirname "$0")/.." && pwd)/docs/install-guide/install-guide.html"
! grep -q -e 'rclone authorize.*--client-id' "$INST" "$GUIDE" || fail "подсказка зовёт rclone authorize с несуществующим флагом --client-id"
! grep -q 'brew install rclone' "$INST" "$GUIDE" || fail "подсказка шлёт ставить rclone через brew, которого на маке нет"
echo "✓ подсказки про rclone authorize рабочие"

# Группы: в privacy mode Telegram не отдал боту даже @упоминание (живая
# установка 02.10.2026) -- и установщик, и инструкция обязаны требовать админа.
grep -q 'НАДО сделать администратором группы' "$INST" || fail "установщик не говорит, что бота в группе надо сделать админом"
grep -q 'Сделать бота администратором — обязательно' "$GUIDE" || fail "инструкция не требует сделать бота админом группы"
# Связь не рвётся на долгих вопросах, а команды из PDF не переносятся по строкам
grep -q 'ssh -o ServerAliveInterval=30 root@' "$GUIDE" || fail "в инструкции ssh без ServerAliveInterval"
grep -q 'white-space: pre;' "$GUIDE" || fail "блоки команд в инструкции могут переноситься по строкам"
echo "✓ инструкция: группы через админа, ssh с keepalive, команды без переносов"
