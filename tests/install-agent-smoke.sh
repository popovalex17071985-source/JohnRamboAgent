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
grep -q 'OOMPolicy=continue'      "$S" || fail "тяжёлый скрипт не должен ронять весь сервис (OOMPolicy=continue)"

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
grep -q 'grep -qE "❯ \*No, (exit|disable external imports)"' "$S" || fail "dashi-press-dialogs: нет обработки диалога с выделенным «No, exit»"

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
# 30.10.2026, агент Жора: после рестарта Claude 2.1.308 встал на «Security notes …
# Press Enter to continue» (онбординг сброшен) -- сторож этот экран не знал, бот молчал.
# Гоняем сам сторож с подменёнными tmux/sleep: экран диалога -> Enter, тот же текст
# над строкой статуса (старая переписка) -> выход без нажатий.
pd="$(mktemp -d)"
sed -n "/^cat > \/usr\/local\/bin\/dashi-press-dialogs <<'EOF'/,/^EOF\$/p" "$S" | sed '1d;$d' >"$pd/press"
cat >"$pd/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in capture-pane) printf '%s\n' "$SCREEN" ;; send-keys) echo "${@: -1}" >>"$KEYS" ;; esac
STUB
printf '#!/bin/sh\n:\n' >"$pd/sleep"
chmod +x "$pd/tmux" "$pd/sleep"
run_press() { : >"$pd/keys"; SCREEN="$1" KEYS="$pd/keys" PATH="$pd:$PATH" bash "$pd/press" smoke-$$; }
run_press $' Security notes:\n 1. Claude can make mistakes.\n Press Enter to continue…'
[[ "$(head -1 "$pd/keys")" == Enter ]] || fail "сторож не жмёт Enter на экране «Security notes / Press Enter to continue»"
run_press $'> Press Enter to continue -- это было в чате\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
[[ ! -s "$pd/keys" ]] || fail "сторож жмёт Enter в живой ввод: «Press Enter to continue» в переписке над строкой статуса"
run_press $'> поставь Dark mode и Enter to confirm\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
[[ ! -s "$pd/keys" ]] || fail "сторож жмёт Enter в живой ввод: фраза старого диалога в переписке над строкой статуса"
echo "✓ фразы диалогов в переписке сторож не трогает"
# 30.10.2026, Жора вживую: диалог внешних импортов стоит на «No, disable» -- Enter отрезал бы правила.
run_press $'  Allow external CLAUDE.md file imports?\n  ❯ No, disable external imports\n    Yes, allow external imports\n  Enter to confirm · Esc to cancel'
[[ "$(head -2 "$pd/keys" | tr '\n' ' ')" == "Down Enter " ]] || fail "на «No, disable external imports» сторож жмёт не Down+Enter: $(tr '\n' ' ' <"$pd/keys")"
echo "✓ внешние импорты правил сторож разрешает, а не отключает"
run_press $'  Do you trust the files in this folder?\n  ❯ No, exit\n    Yes, proceed\n  Enter to confirm · Esc to cancel'
[[ "$(head -2 "$pd/keys" | tr '\n' ' ')" == "Down Enter " ]] || fail "на «No, exit» сторож жмёт не Down+Enter -- Enter выбил бы Claude"
# Mutation audit 01.11.2026: the Bypass Permissions warning stands on «1. No, exit»
# (numbered -- the «❯ No, exit» branch does not see it). A plain Enter there exits
# Claude and the service loops in restarts (20.08.2026). Down+Enter only.
run_press $'  WARNING: Claude Code running in Bypass Permissions mode\n  ❯ 1. No, exit\n    2. Yes, I accept\n  Enter to confirm · Esc to cancel'
[[ "$(head -2 "$pd/keys" | tr '\n' ' ')" == "Down Enter " ]] || fail "на «Bypass Permissions» сторож жмёт не Down+Enter -- Enter выбрал бы «No, exit»: $(tr '\n' ' ' <"$pd/keys")"
echo "✓ Bypass Permissions: Down+Enter, не голый Enter"
# Mutation audit 01.11.2026: the pane lock was only grepped for. Panel busy (autocompact
# holds the lock between «/compact» and its Enter) -> the watcher must NOT press; a press
# past the lock confirmed the wrong line and killed Claude (Gor, 11.09.2026).
# capture-pane answers with a dialog once and then fails, so the watcher exits fast.
cat >"$pd/tmp-tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  capture-pane) [[ -e "$KEYS.seen" ]] && exit 1; : >"$KEYS.seen"; printf '%s\n' "$SCREEN" ;;
  send-keys) echo "${@: -1}" >>"$KEYS" ;;
esac
STUB
mkdir -p "$pd/busy"; mv "$pd/tmp-tmux" "$pd/busy/tmux"; cp "$pd/sleep" "$pd/busy/sleep"; chmod +x "$pd/busy/tmux"
# The lock is held by THIS shell (fd 8): the watcher opens its own descriptor and waits.
exec 8>"/tmp/dashi-pane-smoke_$$.lock"; flock 8
: >"$pd/keys"; rm -f "$pd/keys.seen"
SCREEN=$' Security notes:\n 1. Claude can make mistakes.\n Press Enter to continue…' KEYS="$pd/keys" \
  PATH="$pd/busy:$PATH" bash "$pd/press" smoke-$$
exec 8>&-
[[ ! -s "$pd/keys" ]] || fail "панель занята (замок у автосжатия), а сторож всё равно жмёт: $(tr '\n' ' ' <"$pd/keys")"
echo "✓ занятая панель: сторож ждёт замок и не жмёт мимо него"
rm -rf "$pd" "/tmp/dashi-pane-smoke_$$.lock"

# 30.10.2026, Жора: ~/.claude.json переписан задачей от root -- без онбординга, доверия
# и моста. dashi-run возвращает их до старта; целый файл не трогает, битый -- тоже.
rd="$(mktemp -d)"
sed -n "/^cat > \/usr\/local\/bin\/dashi-run <<'EOF'/,/^EOF\$/p" "$S" \
  | sed -n "/^python3 -I - \"\$PLUGIN\" \"\$GIT_ROOT\" <<'PY'/,/^PY\$/p" | sed '1d;$d' >"$rd/fix.py"
[[ -s "$rd/fix.py" ]] || fail "не нашёл в dashi-run починку ~/.claude.json"
echo '{"numStartups": 7}' >"$rd/.claude.json"
HOME="$rd" python3 "$rd/fix.py" /srv/plugin /srv 2>/dev/null
python3 - "$rd/.claude.json" <<'PYT' || fail "dashi-run не вернул онбординг/доверие/мост в ~/.claude.json"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["hasCompletedOnboarding"] is True and d["numStartups"] == 7
for k in ("/srv/plugin", "/srv"):  # Claude ищет доверие под корнем git
    p = d["projects"][k]
    assert p["hasTrustDialogAccepted"] and p["hasClaudeMdExternalIncludesApproved"]
assert oct(__import__("os").stat(sys.argv[1]).st_mode & 0o777) == "0o600"
assert d["mcpServers"]["dashi-channel"]["args"] == ["./src/server.ts"]
PYT
compgen -G "$rd/.claude.json.bak-dashi-run-*" >/dev/null || fail "dashi-run правит ~/.claude.json без копии"
rm "$rd"/.claude.json.bak-dashi-run-*; before="$(md5sum <"$rd/.claude.json")"
HOME="$rd" python3 "$rd/fix.py" /srv/plugin /srv 2>/dev/null
[[ "$(md5sum <"$rd/.claude.json")" == "$before" ]] && ! compgen -G "$rd/.claude.json.bak-dashi-run-*" >/dev/null \
  || fail "dashi-run переписывает целый ~/.claude.json"
# Mutation audit 01.11.2026: each of the three losses is checked ALONE -- the file above
# lacks all three at once, so dropping any one condition from «missing» stayed green.
# And a bridge entry the owner already has (env with keys) is kept, not replaced.
python3 - "$rd/.claude.json" <<'PYT'
import json, sys
full = {"hasCompletedOnboarding": True,
        "projects": {k: {"hasTrustDialogAccepted": True, "hasClaudeMdExternalIncludesApproved": True,
                         "hasClaudeMdExternalIncludesWarningShown": True} for k in ("/srv/plugin", "/srv")},
        "mcpServers": {"dashi-channel": {"type": "stdio", "command": "bun", "args": ["./src/server.ts"],
                                         "env": {"OWNER_KEY": "keep-me"}}}}
json.dump(full, open(sys.argv[1], "w"))
PYT
fix_case() {  # fix_case <python that breaks one thing in d> <python assert on d>
  python3 - "$rd/.claude.json" "$1" <<'PYT'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2]); json.dump(d, open(p, "w"))
PYT
  HOME="$rd" python3 "$rd/fix.py" /srv/plugin /srv 2>/dev/null
  python3 - "$rd/.claude.json" "$2" <<'PYT'
import json, sys
d = json.load(open(sys.argv[1])); exec(sys.argv[2])
PYT
}
fix_case 'del d["mcpServers"]["dashi-channel"]' \
  'assert d["mcpServers"]["dashi-channel"]["args"] == ["./src/server.ts"]' \
  || fail "dashi-run не возвращает мост, когда пропал только он"
fix_case 'd["projects"]["/srv"]["hasClaudeMdExternalIncludesApproved"] = False' \
  'assert d["projects"]["/srv"]["hasClaudeMdExternalIncludesApproved"] is True' \
  || fail "dashi-run не возвращает одобрение внешних импортов, когда пропало только оно"
fix_case 'd["mcpServers"]["dashi-channel"]["env"] = {"OWNER_KEY": "keep-me"}; d.pop("hasCompletedOnboarding")' \
  'assert d["hasCompletedOnboarding"] is True and d["mcpServers"]["dashi-channel"]["env"] == {"OWNER_KEY": "keep-me"}' \
  || fail "dashi-run затёр свою же запись моста хозяина (env с ключами)"
echo '{"broken' >"$rd/.claude.json"
HOME="$rd" python3 "$rd/fix.py" /srv/plugin /srv 2>/dev/null && fail "dashi-run молчит о битом ~/.claude.json"
[[ "$(cat "$rd/.claude.json")" == '{"broken' ]] || fail "dashi-run затёр битый ~/.claude.json"
rm -rf "$rd"
echo "✓ dashi-run возвращает онбординг, доверие и мост; целый и битый файл не трогает"
echo "✓ экран «Security notes» сторож проходит Enter"
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
grep -q 'ssh -o ServerAliveInterval=30 -l root ' "$GUIDE" || fail "в инструкции ssh без ServerAliveInterval"
grep -q 'white-space: pre;' "$GUIDE" || fail "блоки команд в инструкции могут переноситься по строкам"
echo "✓ инструкция: группы через админа, ssh с keepalive, команды без переносов"
# Переезд памяти на ключ OpenAI выключает локальную модель, иначе она так и ест ~0.7 ГБ
grep -q 'systemctl disable --now -q dashi-embed' "$S" || fail "после ключа OpenAI локальная модель памяти не выключается"
grep -q 'dashi-embed.service.retired-' "$S" || fail "юнит dashi-embed не уносится (health-check будет кричать)"
echo "✓ память: ключ OpenAI выключает локальную модель"
# Повторный прогон переспрашивает ключ OpenAI, если память на локальной модели
grep -q 'Память агента сейчас без ключа OpenAI' "$S" || fail "повторный прогон не спрашивает ключ OpenAI для локальной памяти"
echo "✓ память: повторный прогон переспрашивает ключ OpenAI"
# Закрытый репозиторий (05.10.2026): ключ только на чтение -- в заголовок клона
# (его видят все, кто тянет обновления), копия в secrets/ (переживает бэкап)
grep -q 'REPO_TOKEN="${REPO_TOKEN:-${DASHI_REPO_TOKEN:-}}"' "$INST" || fail "установщик не берёт ключ репозитория из DASHI_REPO_TOKEN"
grep -q 'REPO_HDR_KEY="http.https://github.com/.extraheader"' "$INST" || fail "ключ репозитория не кладётся заголовком в клон"
grep -q 'secrets/repo-token' "$INST" || fail "ключ репозитория не сохраняется в secrets/ (восстановление спросит заново)"
# 31.10.2026, Жупик: клон ходит по SSH-ключу, а протухший токен из secrets/ ронял прогон
# и set-url на https отрезал бы обновления.
grep -q 'REPO_URL="$CLONE_ORIGIN"; REPO_VIA_SSH=1; REPO_TOKEN=""' "$INST" \
  || fail "повторный прогон не оставляет рабочий SSH-origin клона"
grep -q 'REPO_TOKEN_EXPLICIT="$REPO_TOKEN"' "$INST" || fail "явный --repo-token затирается SSH-путём"
grep -q "BatchMode=yes" "$INST" || fail "проверка SSH может зависнуть на вопросе ssh"
# 31.10.2026, Жупик: голый GIT_SSH_COMMAND перекрыл core.sshCommand -- git пошёл без ключа.
eval "$(grep -m1 '^GIT_SSH_BATCH=' "$INST")"
sd="$(mktemp -d)"; git init -q "$sd/r"
printf '#!/bin/sh\necho "$@" >"%s/args"; exit 1\n' "$sd" >"$sd/ssh"; chmod +x "$sd/ssh"
git -C "$sd/r" config core.sshCommand "$sd/ssh -i DEPLOYKEY"
git -C "$sd/r" remote add origin git@github.com:x/y.git
bash -c "cd '$sd/r' && $GIT_SSH_BATCH GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --heads origin" >/dev/null 2>&1 || true
grep -q -- '-i DEPLOYKEY -o BatchMode=yes' "$sd/args" 2>/dev/null \
  || fail "SSH-проверка теряет ключ развёртывания клона: $(cat "$sd/args" 2>/dev/null)"
rm -rf "$sd"
grep -q -- '--repo)      REPO_URL="$2"; REPO_URL_GIVEN=1' "$INST" || fail "явный --repo не отключает SSH-origin клона"
eval "$(sed -n '/^repo_auth_header()/p' "$INST")"
[[ "$(repo_auth_header abc)" == "Authorization: Basic $(printf 'x-access-token:abc' | base64 -w0)" ]] \
  || fail "заголовок ключа репозитория собран неверно"
grep -q 'curl -fsSL -H "$H" $R/$P/scripts/install-agent.sh' "$GUIDE" || fail "инструкция скачивает установщик без ключа"
grep -q 'sudo DASHI_REPO_TOKEN=$K bash install-agent.sh' "$GUIDE" || fail "инструкция не передаёт ключ установщику"
echo "✓ закрытый репозиторий: ключ в клоне и в secrets/, инструкция качает с ключом"
# Mutation audit 01.11.2026: the installer runs under umask 022 since 19.10, so the
# clone's .git/config (it carries the repo key as a header) is world-readable unless
# save_repo_token closes it. Run the real function in a sandbox: key file and config 600.
rt="$(mktemp -d)"; git init -q "$rt/clone"; chmod 644 "$rt/clone/.git/config"
eval "$(sed -n '/^REPO_HDR_KEY=/p; /^repo_auth_header()/p; /^save_repo_token() {/,/^}/p' "$INST")"
( umask 022; chown() { :; }
  REPO_DIR="$rt/clone" REPO_TOKEN_FILE="$rt/repo-token" REPO_TOKEN=github_pat_smoke SERVICE_USER=nobody
  save_repo_token )
[[ "$(stat -c %a "$rt/clone/.git/config")" == 600 ]] || fail "ключ репозитория лежит в .git/config, открытом всем ($(stat -c %a "$rt/clone/.git/config"))"
[[ "$(stat -c %a "$rt/repo-token")" == 600 ]] || fail "копия ключа в secrets/ открыта всем"
git config --file "$rt/clone/.git/config" --get "$REPO_HDR_KEY" | grep -q '^Authorization: Basic ' || fail "ключ не лёг заголовком в клон"
rm -rf "$rt"
echo "✓ ключ репозитория закрыт (600) в клоне и в secrets/"
# Only OUR repo over SSH is left on its origin; a clone pointing anywhere else is moved
# to the official https origin as before (the SSH branch skips set-url).
ssh_re="$(sed -n 's/.*"\$CLONE_ORIGIN" =~ \(.*\) \]\]; then$/\1/p' "$INST")"
[[ -n "$ssh_re" ]] || fail "не нашёл в установщике условие SSH-origin"
for o in git@github.com:popovalex17071985-source/JohnRamboAgent.git \
         ssh://git@github.com/popovalex17071985-source/JohnRamboAgent; do
  [[ "$o" =~ $ssh_re ]] || fail "наш SSH-origin не узнан: $o"
done
for o in git@github.com:someone/JohnRamboAgent.git git@github.com:popovalex17071985-source/other.git \
         git@evil.example:popovalex17071985-source/JohnRamboAgent.git \
         https://github.com/popovalex17071985-source/JohnRamboAgent.git; do
  [[ "$o" =~ $ssh_re ]] && fail "чужой origin оставлен как есть (SSH-путь): $o"
done
echo "✓ SSH-origin оставляется только нашему репозиторию"

# ── fresh install with a repo deploy key: --repo-key (Smith 01.11.2026) ──────
# The SSH path of 31.10 only kept an SSH origin on a RERUN; a fresh box had no way to
# clone the private repo over SSH, so Smith's wrapper made ~agent/.ssh by hand.
bash "$INST" --help | grep -q -- '--repo-key' || fail "--help молчит про --repo-key"
kd="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -C smoke -f "$kd/key" >/dev/null
out="$(bash "$INST" --name t --yes --repo-key "$kd/nope" 2>&1 || true)"
grep -q 'ключ к репозиторию не найден' <<<"$out" || fail "--repo-key на несуществующий файл не остановил установку: $out"
out="$(bash "$INST" --name t --yes --repo-key "$kd/key" --repo https://github.com/x/y.git 2>&1 || true)"
grep -q 'только с SSH-адресом' <<<"$out" || fail "--repo-key с https-адресом принят: $out"
out="$(bash "$INST" --name t --yes --repo-key "$kd/key" --repo "git@github.com:x/y'; touch /tmp/x" 2>&1 || true)"
grep -q 'только с SSH-адресом' <<<"$out" || fail "--repo-key: кавычка в адресе принята (ломает команды агента): $out"
out="$(bash "$INST" --name t --yes --repo-key "$kd/key" --repo-token github_pat_x 2>&1 || true)"
grep -q 'что-то одно' <<<"$out" || fail "--repo-key вместе с --repo-token принят: $out"
grep -q -- '--repo-key)' "$INST" || fail "нет разбора флага --repo-key"
# GitHub host keys pinned in the installer = GitHub's published fingerprints
# (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
eval "$(sed -n "/^GITHUB_HOST_KEYS='/,/'\$/p" "$INST" | head -4)"   # 4 lines max: never eval the installer
[[ -n "${GITHUB_HOST_KEYS:-}" ]] || fail "нет закреплённых ключей GitHub (GITHUB_HOST_KEYS)"
fps="$(ssh-keygen -lf <(printf '%s\n' "$GITHUB_HOST_KEYS") | awk '{print $2}' | sort | paste -sd' ')"
[[ "$fps" == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s" ]] \
  || fail "ключи GitHub в установщике не совпадают с опубликованными: $fps"
grep -c '^github.com ' <<<"$GITHUB_HOST_KEYS" | grep -qx 3 || fail "ждал ровно 3 ключа GitHub"
# repo_key_install: key into HOME/.ssh (700/600/644), host keys pinned, idempotent
H2="$kd/home"; mkdir -p "$H2"; me="$(id -un)"; HOME_DIR="$H2"
eval "$(awk '/^REPO_KEY_FILE=/{print} /^REPO_SSH_CMD=/{print} /^as_user\(\) \{/,/^\}$/{print}
             /^repo_key_install\(\) \{/,/^\}$/{print} /^repo_clone_cmd\(\) \{/,/^\}$/{print}' "$INST")"
declare -F repo_key_install >/dev/null && declare -F repo_clone_cmd >/dev/null && declare -F as_user >/dev/null \
  || fail "нет repo_key_install/repo_clone_cmd/as_user в установщике"
# Root never writes into the agent's home itself: a symlink the agent planted
# (~/.ssh/known_hosts -> /etc/sudoers.d/x) would hand it a system file.
body="$(awk '/^repo_key_install\(\) \{/,/^\}$/' "$INST" | grep -v '^ *#')"
grep -nE '(^|[;&|[:space:]])(chown|chmod|install|cp|tee)[[:space:]]' <<<"$body" | grep -v 'as_user "\$user"' \
  && fail "repo_key_install пишет в домашку агента от root, мимо as_user"
grep -nE '>>? *"\$(d|kh|home)' <<<"$body" | grep -v "sh -c" && fail "repo_key_install пишет в домашку агента от root (>)"
# a key dropped with 0644 (cloud-init write_files default) is fine: checked on the 600 copy
cp "$kd/key" "$kd/key644"; chmod 644 "$kd/key644"
repo_key_install "$kd/key644" "$kd/h644" "$me" || fail "ключ с правами 644 отвергнут (ssh-keygen смотрел исходник)"
repo_key_install "$kd/key" "$H2" "$me" || fail "repo_key_install упал на нормальном ключе"
[[ "$(stat -c %a "$H2/.ssh")" == 700 ]] || fail "~/.ssh не 700"
[[ "$(stat -c %a "$H2/.ssh/$REPO_KEY_FILE")" == 600 ]] || fail "ключ не 600"
[[ "$(stat -c %a "$H2/.ssh/$REPO_KEY_FILE.pub")" == 644 ]] || fail "публичная половина не 644"
cmp -s "$kd/key" "$H2/.ssh/$REPO_KEY_FILE" || fail "ключ скопирован не тот"
[[ "$(cut -d' ' -f1-2 "$H2/.ssh/$REPO_KEY_FILE.pub")" == "$(cut -d' ' -f1-2 "$kd/key.pub")" ]] \
  || fail "публичная половина не та"
[[ "$(stat -c %a "$H2/.ssh/known_hosts")" == 600 ]] || fail "known_hosts не 600"
echo 'example.org ssh-ed25519 AAAAOWN' >> "$H2/.ssh/known_hosts"
repo_key_install "$kd/key" "$H2" "$me" || fail "повторный repo_key_install упал"
(( $(grep -c '^github.com ' "$H2/.ssh/known_hosts") == 3 )) || fail "ключи GitHub задвоились в known_hosts"
grep -q '^example.org ' "$H2/.ssh/known_hosts" || fail "repo_key_install стёр чужие строки known_hosts"
ssh-keygen -q -t ed25519 -N 'secret' -f "$kd/locked" >/dev/null
repo_key_install "$kd/locked" "$kd/h3" "$me" 2>/dev/null && fail "ключ под паролем принят (агент не сможет им ходить)"
echo 'not a key' > "$kd/junk"
repo_key_install "$kd/junk" "$kd/h4" "$me" 2>/dev/null && fail "не-ключ принят как ключ"
# The fresh clone goes over SSH with that key, and the key stays in the clone's config
# (core.sshCommand) -- updates, the advisor and a rerun all use it. ssh is a stub that
# serves a local bare repo the way GitHub would.
git init -q --bare "$kd/srv.git"; git init -q "$kd/w"
git -C "$kd/w" -c user.email=s@s -c user.name=s commit -q --allow-empty -m one
git -C "$kd/w" push -q "$kd/srv.git" HEAD:refs/heads/main
mkdir -p "$kd/bin"
cat > "$kd/bin/ssh" <<EOF
#!/bin/sh
echo "\$*" >> "$kd/ssh.args"
for last; do :; done
exec sh -c "\$(printf '%s' "\$last" | sed "s|'[^']*'|'$kd/srv.git'|")"
EOF
chmod +x "$kd/bin/ssh"
REPO_KEY="$kd/key"; REPO_TOKEN=""; BRANCH=main; REPO_URL=git@github.com:popovalex17071985-source/JohnRamboAgent.git
CLAUDE_DIR="$kd/ws"
HOME="$H2" PATH="$kd/bin:$PATH" bash -c "$(repo_clone_cmd)" >/dev/null 2>&1 \
  || fail "клон по SSH-ключу не прошёл: $(cat "$kd/ssh.args" 2>/dev/null)"
C="$kd/ws/dashi-plugin-claude-code"
[[ "$(git -C "$C" config core.sshCommand)" == "$REPO_SSH_CMD" ]] || fail "ключ не записан в клон (core.sshCommand)"
grep -qF -- "-i $H2/.ssh/$REPO_KEY_FILE" "$kd/ssh.args" || fail "клон шёл не с ключом развёртывания: $(cat "$kd/ssh.args")"
grep -qF -- 'StrictHostKeyChecking=yes' "$kd/ssh.args" || fail "клон не требует закреплённый ключ GitHub"
grep -qF -- 'BatchMode=yes' "$kd/ssh.args" || fail "клон по SSH может зависнуть на вопросе ssh"
: > "$kd/ssh.args"
# HOME=/root here on purpose: dashi-ctl runs git via sudo + runuser, HOME stays root's
( cd "$C" && HOME=/nonexistent-root PATH="$kd/bin:$PATH" eval "$GIT_SSH_BATCH GIT_TERMINAL_PROMPT=0 git fetch -q --depth 1 origin main" ) \
  || fail "обновление клона по ключу не прошло"
grep -qF -- "UserKnownHostsFile=$H2/.ssh/known_hosts" "$kd/ssh.args" \
  || fail "обновление с чужим HOME ищет known_hosts не у агента: $(cat "$kd/ssh.args")"
grep -qF -- "-i $H2/.ssh/$REPO_KEY_FILE" "$kd/ssh.args" || fail "обновление шло без ключа развёртывания"
REPO_KEY=""; [[ "$(repo_clone_cmd)" == *sshCommand* ]] && fail "без --repo-key клон тоже получает sshCommand"
grep -qF 'as_agent "$(repo_clone_cmd)"' "$INST" || fail "установщик клонирует мимо repo_clone_cmd"
grep -q 'repo_key_install "$REPO_KEY" "$HOME_DIR" "$SERVICE_USER"' "$INST" || fail "установщик не ставит ключ развёртывания"
rm -rf "$kd"
echo "✓ --repo-key: ключ в ~/.ssh (600), ключи GitHub закреплены, свежий клон и обновления по SSH"
