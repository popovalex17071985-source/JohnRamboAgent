#!/usr/bin/env bash
# Смоук: `dashi-ctl-<имя> rollback` — откат на версию до последнего обновления
# (или --to <sha|тег>) для случая «обновление встало, но оказалось плохим».
# Берём НАСТОЯЩИЙ текст dashi-ctl из установщика (heredoc), подставляем пути
# временного каталога; runuser и bun — заглушки (без root и без сети).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/install-agent.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "✗ $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# ── dashi-ctl из установщика ─────────────────────────────────────────────────
BODY="$(awk '/^cat > "\$CTL" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' "$S")"
[[ -n "$BODY" ]] || fail "не нашёл текст dashi-ctl в установщике"
grep -q 'rollback)' <<<"$BODY" || fail "в dashi-ctl нет команды rollback"
REPO="$T/cd/dashi-plugin-claude-code"
AGENT_NAME=smoke UNIT=dashi-smoke SERVICE_USER=agent REPO_DIR="$REPO" PLUGIN_DIR="$REPO/plugin"
BRANCH=main ENV_FILE="$T/channel.env" CLAUDE_DIR="$T/cd" USER_ID=42
: > "$ENV_FILE"
eval "cat > \"\$T/ctl\" <<EOF
$BODY
EOF"

# runuser -u <user> -- cmd... → просто cmd (мы и так не root)
mkdir -p "$T/bin" "$T/home/.bun/bin"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$T/bin/runuser"
BUNLOG="$T/bun.log"; echo 0 > "$T/bun.rc"
printf '#!/bin/sh\necho "$@" >> "%s"\nexit $(cat "%s")\n' "$BUNLOG" "$T/bun.rc" > "$T/home/.bun/bin/bun"
chmod +x "$T/bin/runuser" "$T/home/.bun/bin/bun"
ctl() { PATH="$T/bin:$PATH" HOME="$T/home" bash "$T/ctl" "$@" 2>"$T/err"; }
last() { tail -1 "$T/out"; }
g() { git -C "$REPO" "$@"; }

# ── origin: старая версия → новая, агент сидит на старой (клон неглубокий, как у установщика)
O="$T/origin"; mkdir -p "$O/plugin"
git -C "$O" init -q -b main
echo '{"name":"fx"}' > "$O/plugin/package.json"; echo 'v1' > "$O/plugin/src.ts"
git -C "$O" add -A && git -C "$O" commit -q -m "Старая версия"
OLD="$(git -C "$O" rev-parse HEAD)"
mkdir -p "$T/cd"; git clone -q --depth 1 "file://$O" "$REPO"
echo 'v2' > "$O/plugin/src.ts"; git -C "$O" commit -q -am "Новая версия, оказалась плохой"
NEW="$(git -C "$O" rev-parse HEAD)"

# 0. До первого обновления откатываться некуда
ctl rollback > "$T/out"; rc=$?
[[ $rc == 6 && "$(last)" == NOPREV ]] || fail "без прошлой версии ждали NOPREV/6, есть $rc: $(cat "$T/out")"

# 1. update запоминает версию, с которой ушёл
ctl update > "$T/out" || fail "update упал: $(cat "$T/out" "$T/err")"
[[ "$(last)" == "UPDATED 1 ${NEW:0:7}" ]] || fail "update: $(cat "$T/out")"
[[ "$(g rev-parse refs/dashi/pre-update)" == "$OLD" ]] || fail "update не запомнил прежнюю версию"
echo "✓ update запоминает прежнюю версию"
# тег на старой версии появился в origin уже после установки — локально его нет
git -C "$O" tag -a v1.0.0 -m "v1.0.0" "$OLD"
! g rev-parse -q --verify v1.0.0 >/dev/null || fail "тег уже есть локально — тест не про то"

# 2. Грязное дерево — отказ, как у update
echo 'руками' >> "$REPO/plugin/src.ts"
ctl rollback > "$T/out"; rc=$?
[[ $rc == 3 && "$(last)" == "DIRTY plugin/src.ts " ]] || fail "грязное дерево: ждали DIRTY/3, есть $rc: $(cat "$T/out")"
[[ "$(g rev-parse HEAD)" == "$NEW" ]] || fail "при DIRTY код сдвинулся"
g checkout -q -- plugin/src.ts
echo "✓ грязное дерево — отказ"

# 3. Откат: код на прежней версии, bun install прогнан, подсказка про restart
: > "$BUNLOG"
ctl rollback > "$T/out" || fail "rollback упал: $(cat "$T/out" "$T/err")"
[[ "$(last)" == "ROLLEDBACK ${NEW:0:7} ${OLD:0:7}" ]] || fail "rollback: $(cat "$T/out")"
[[ "$(g rev-parse HEAD)" == "$OLD" && "$(cat "$REPO/plugin/src.ts")" == v1 ]] || fail "код не вернулся"
grep -q "install" "$BUNLOG" || fail "после отката не прогнан bun install"
grep -q "dashi-ctl-smoke restart" "$T/err" || fail "нет подсказки следующей команды: $(cat "$T/err")"
[[ ! -e "$REPO.bak" || -d "$REPO.bak" ]] || fail "странный .bak"
echo "✓ rollback возвращает прежнюю версию"

# 4. Откат отката: прежняя «прежняя» — та, с которой ушли
ctl rollback > "$T/out" || fail "второй rollback упал"
[[ "$(g rev-parse HEAD)" == "$NEW" ]] || fail "второй rollback не вернул вперёд"
echo "✓ повторный rollback отменяет откат"

# 5. Уже там — ничего не трогаем
ctl rollback --to "${NEW:0:7}" > "$T/out" || fail "SAME упал"
[[ "$(last)" == "SAME ${NEW:0:7}" ]] || fail "ждали SAME: $(cat "$T/out")"

# 6. --to <тег>, которого нет локально — забирается из origin
ctl rollback --to v1.0.0 > "$T/out" || fail "--to тег из origin: $(cat "$T/out" "$T/err")"
[[ "$(g rev-parse HEAD)" == "$OLD" ]] || fail "--to тег: код не на теге"
echo "✓ --to тег (забран из origin)"

# 7. Без remote (обновления отключены хозяином) — по локальной истории
g reset -q --hard "$NEW"
g remote set-url origin /nonexistent/updates-disabled-by-owner
ctl rollback --to "${OLD:0:9}" > "$T/out" || fail "--to sha без remote: $(cat "$T/out" "$T/err")"
[[ "$(g rev-parse HEAD)" == "$OLD" ]] || fail "--to sha без remote не сработал"
ctl rollback --to v1.0.0 > "$T/out" || fail "--to локальный тег без remote"
[[ "$(last)" == "SAME ${OLD:0:7}" ]] || fail "локальный тег без remote: $(cat "$T/out")"
ctl rollback --to v9.9.9 > "$T/out"; rc=$?
[[ $rc == 6 && "$(last)" == "NOTFOUND v9.9.9" ]] || fail "нет такой версии: ждали NOTFOUND/6, есть $rc: $(cat "$T/out")"
echo "✓ без remote: sha и локальный тег работают, чужой — NOTFOUND"

# 8. Мусор в аргументах — отказ до git
for bad in "-x" "a;b" "../x" "" "HEAD..x"; do
  ctl rollback --to "$bad" > "$T/out"; rc=$?
  [[ $rc == 2 ]] || fail "аргумент «$bad» не отбит (rc=$rc)"
done
ctl rollback junk > "$T/out"; [[ $? == 2 ]] || fail "rollback junk не отбит"
echo "✓ кривые аргументы отбиваются"

# 9. Упал bun install — код как был, .bak не остаётся
g reset -q --hard "$NEW"; echo 1 > "$T/bun.rc"
ctl rollback --to "$OLD" > "$T/out"; rc=$?
[[ $rc == 4 && "$(last)" == ROLLBACK ]] || fail "падение bun: ждали ROLLBACK/4, есть $rc: $(cat "$T/out")"
[[ "$(g rev-parse HEAD)" == "$NEW" ]] || fail "после падения bun код не на месте"
[[ ! -e "$REPO.bak" ]] || fail "остался .bak"
echo "✓ падение bun install — код как был"

echo "✓ agent-rollback smoke ok"
