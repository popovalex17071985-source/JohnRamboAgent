#!/usr/bin/env bash
# Смоук: скрипты запуска (dashi-run, dashi-press-dialogs) обновляются вместе с кодом.
# До 01.11.2026 их писал только установщик (heredoc), а `dashi-ctl update`, /update из
# чата и rollback двигали лишь git-клон: фиксы #127 (экран «Security notes», доверие
# к папке) у обновлённых агентов не доехали -- на сервере лежали копии от 06.10.
# Берём НАСТОЯЩИЕ общий генератор и текст dashi-ctl из установщика, пути -- во
# временный каталог; runuser/chown/systemctl/bun -- заглушки (без root и без сети).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/install-agent.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "✗ $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
NAMES=(dashi-run dashi-press-dialogs)

# ── 0. статика: одна правда для установщика и dashi-ctl ──────────────────────
for n in "${NAMES[@]}"; do
  [[ -f "$ROOT/scripts/launch/$n" ]] || fail "нет scripts/launch/$n -- текст скрипта запуска не в файле"
  bash -n "$ROOT/scripts/launch/$n" || fail "scripts/launch/$n: синтаксис"
  grep -qE "^cat > /usr/local/bin/$n <<" "$S" && fail "установщик пишет $n своим heredoc мимо общего генератора"
done
eval "$(sed -n '/^launch_refresh() {/,/^}/p' "$S")"
declare -F launch_refresh >/dev/null || fail "нет общего генератора launch_refresh в установщике"
BODY="$(awk '/^cat > "\$CTL" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' "$S")"
[[ -n "$BODY" ]] || fail "не нашёл текст dashi-ctl в установщике"
grep -qF '$(declare -f launch_refresh)' <<<"$BODY" || fail "dashi-ctl не берёт генератор установщика (разъедутся)"
grep -qE '^launch_refresh "\$REPO_DIR/scripts/launch" ' "$S" || fail "установщик не ставит скрипты запуска общим генератором"
echo "✓ установщик и dashi-ctl ставят скрипты запуска одним генератором из scripts/launch"

# ── стенд ────────────────────────────────────────────────────────────────────
BIN="$T/usr-local-bin" STATE="$T/var-lib-launch"
REPO="$T/cd/dashi-plugin-claude-code"
mkdir -p "$BIN" "$T/etc/smoke" "$T/stub" "$T/home/.bun/bin"
AGENT_NAME=smoke UNIT=dashi-smoke SERVICE_USER=agent REPO_DIR="$REPO" PLUGIN_DIR="$REPO/plugin"
BRANCH=main ENV_FILE="$T/etc/smoke/channel.env" CLAUDE_DIR="$T/cd" USER_ID=42
LAUNCH_BIN="$BIN" LAUNCH_STATE="$STATE" AGENTS_ETC="$T/etc"
: > "$ENV_FILE"
eval "cat > \"\$T/ctl\" <<EOF
$BODY
EOF"
bash -n "$T/ctl" || fail "сгенерированный dashi-ctl: синтаксис"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$T/stub/runuser"          # runuser -u X -- cmd → cmd
printf '#!/bin/sh\n:\n' > "$T/stub/chown"                              # не root: chown root -- мимо
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$T/systemctl.log" > "$T/stub/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$T/home/.bun/bin/bun"
chmod +x "$T/stub/"* "$T/home/.bun/bin/bun"
ctl() { PATH="$T/stub:$PATH" HOME="$T/home" bash "$T/ctl" "$@" 2>"$T/err"; }
last() { tail -1 "$T/out"; }
g() { git -C "$REPO" "$@"; }
same() { cmp -s "$1" "$2"; }
put_old() { for n in "${NAMES[@]}"; do printf '#!/usr/bin/env bash\necho old-%s\n' "$n" > "$BIN/$n"; chmod 755 "$BIN/$n"; done; }
is_old() { for n in "${NAMES[@]}"; do grep -qx "echo old-$n" "$BIN/$n" || return 1; done; }
is_src() { for n in "${NAMES[@]}"; do same "$BIN/$n" "$1/$n" || return 1; done; }
no_tmp() { [[ -z "$(find "$BIN" -name '.*' -type f)" ]] || fail "в каталоге скриптов остались временные файлы: $(ls -a "$BIN")"; }

# origin v1: старая версия БЕЗ scripts/launch (как все агенты до фикса); на сервере -- старые копии
O="$T/origin"; mkdir -p "$O/plugin"
git -C "$O" init -q -b main
echo '{"name":"fx"}' > "$O/plugin/package.json"
git -C "$O" add -A && git -C "$O" commit -q -m "Старая версия"
OLD="$(git -C "$O" rev-parse HEAD)"
mkdir -p "$T/cd"; git clone -q --depth 1 "file://$O" "$REPO"
put_old
# v2: скрипты запуска -- настоящие из этого репозитория
mkdir -p "$O/scripts/launch"; cp "$ROOT/scripts/launch/"* "$O/scripts/launch/"
git -C "$O" add -A && git -C "$O" commit -q -m "Скрипты запуска в репозитории"
NEW="$(git -C "$O" rev-parse HEAD)"

# ── 1. UPDATED: скрипты = те, что пишет свежая установка этой версии ─────────
ctl update > "$T/out" || fail "update упал: $(cat "$T/out" "$T/err")"
[[ "$(last)" == "UPDATED 1 ${NEW:0:7}" ]] || fail "update: $(cat "$T/out")"
is_src "$REPO/scripts/launch" || fail "после update скрипты запуска остались старыми"
for n in "${NAMES[@]}"; do
  [[ "$(stat -c %a "$BIN/$n")" == 755 ]] || fail "$n: права $(stat -c %a "$BIN/$n"), ждали 755"
  grep -qx "echo old-$n" "$STATE/legacy/$n" || fail "$n: прежняя копия не отложена для отката"
  b="$(ls "$STATE/backup/$n".* 2>/dev/null | head -1)"
  [[ -n "$b" ]] && grep -qx "echo old-$n" "$b" || fail "$n: нет копии с меткой времени"
done
no_tmp
# эталон: тот же генератор на пустом сервере (свежая установка) пишет те же байты
FRESH="$T/fresh-bin"; mkdir -p "$FRESH"
PATH="$T/stub:$PATH" launch_refresh "$REPO/scripts/launch" agent "$FRESH" "$T/fresh-state" 2>/dev/null \
  || fail "генератор на пустом сервере упал"
is_src "$FRESH" || fail "свежая установка пишет не то, что update"
for n in "${NAMES[@]}"; do same "$BIN/$n" "$FRESH/$n" || fail "$n: update и свежая установка разошлись"; done
echo "✓ update: скрипты запуска обновлены, побайтно как у свежей установки, 755, копии сохранены"

# ── 2. UPTODATE, но скрипты другие -- тоже обновляем; одинаковые -- не трогаем ─
put_old
ctl update > "$T/out" || fail "update (UPTODATE) упал: $(cat "$T/out" "$T/err")"
[[ "$(last)" == UPTODATE ]] || fail "ждали UPTODATE: $(cat "$T/out")"
is_src "$REPO/scripts/launch" || fail "UPTODATE: старые скрипты запуска не заменены"
# разошёлся только один: второй (одинаковый) временный файл не остаётся лежать
printf '#!/usr/bin/env bash\necho old\n' > "$BIN/dashi-press-dialogs"
ctl update > "$T/out" || fail "update (один скрипт старый) упал"
is_src "$REPO/scripts/launch" || fail "UPTODATE: старый сторож диалогов не заменён"
no_tmp
nb="$(ls "$STATE/backup" | wc -l)"
ctl update > "$T/out" || fail "повторный update упал"
[[ "$(last)" == UPTODATE && "$(ls "$STATE/backup" | wc -l)" == "$nb" ]] || fail "одинаковые скрипты переписаны зря"
echo "✓ UPTODATE: разошедшиеся скрипты обновляются, одинаковые не трогаются"

# ── 3. rollback на версию без scripts/launch -- возвращает и прежние скрипты ──
ctl rollback > "$T/out" || fail "rollback упал: $(cat "$T/out" "$T/err")"
[[ "$(last)" == "ROLLEDBACK ${NEW:0:7} ${OLD:0:7}" ]] || fail "rollback: $(cat "$T/out")"
is_old || fail "rollback вернул код, но не прежние скрипты запуска"
ctl rollback > "$T/out" || fail "повторный rollback упал"
[[ "$(g rev-parse HEAD)" == "$NEW" ]] && is_src "$REPO/scripts/launch" || fail "повторный rollback: скрипты не вперёд"
echo "✓ rollback возвращает и код, и скрипты запуска"

# ── 4. ROLLBACK: битый скрипт в новой версии -- ни код, ни скрипты не сдвинулись ─
cp "$BIN/dashi-run" "$T/run.before"; cp "$BIN/dashi-press-dialogs" "$T/press.before"
echo 'if then fi (' >> "$O/scripts/launch/dashi-press-dialogs"
echo '# v3' >> "$O/scripts/launch/dashi-run"
git -C "$O" commit -q -am "Битый сторож диалогов"
ctl update > "$T/out"; rc=$?
[[ $rc == 4 && "$(last)" == ROLLBACK ]] || fail "битый скрипт: ждали ROLLBACK/4, есть $rc: $(cat "$T/out" "$T/err")"
[[ "$(g rev-parse HEAD)" == "$NEW" ]] || fail "ROLLBACK: код не вернулся"
same "$BIN/dashi-run" "$T/run.before" && same "$BIN/dashi-press-dialogs" "$T/press.before" \
  || fail "ROLLBACK: скрипты запуска не те, что были до обновления"
no_tmp
git -C "$O" reset -q --hard "$NEW"
echo "✓ ROLLBACK: битый скрипт не ставится, код и скрипты как были"

# ── 5. restart (им кончается /update из чата) подтягивает скрипты из клона ────
put_old; : > "$T/systemctl.log"
ctl restart > "$T/out" || fail "restart упал: $(cat "$T/err")"
grep -q "restart dashi-smoke" "$T/systemctl.log" || fail "restart не перезапустил сервис"
is_src "$REPO/scripts/launch" || fail "restart после /update из чата не обновил скрипты запуска"
# мусор вместо скрипта: не ставится, сервис всё равно перезапускается
put_old; : > "$T/systemctl.log"; cp "$REPO/scripts/launch/dashi-run" "$T/run.src"
echo 'secret=1' > "$REPO/scripts/launch/dashi-run"
ctl restart > "$T/out" || fail "restart с битым скриптом упал"
is_old || fail "restart поставил файл без #!/usr/bin/env bash"
grep -q "restart dashi-smoke" "$T/systemctl.log" || fail "битый скрипт помешал перезапуску"
cp "$T/run.src" "$REPO/scripts/launch/dashi-run"; no_tmp
echo "✓ restart: скрипты из клона, мусор не ставится, перезапуск не блокируется"

# ── 6. на сервере несколько агентов: общий скрипт из своего клона не ставим ───
# (его исполняют и чужие сервисы, под своими пользователями)
mkdir -p "$T/etc/other"; put_old
ctl update > "$T/out" || fail "update при двух агентах упал"
is_old || fail "агент переписал общий скрипт запуска соседа из своего клона"
grep -q "установщик" "$T/err" || fail "нет подсказки, как обновить скрипты при нескольких агентах: $(cat "$T/err")"
rmdir "$T/etc/other"
echo "✓ несколько агентов на сервере: общие скрипты меняет только установщик"

echo "✓ launch-scripts-refresh smoke ok"
