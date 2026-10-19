#!/usr/bin/env bash
# Смоук установщика на свежем сервере (Смит, 19.10.2026, Ubuntu 22.04):
#  1. сразу после загрузки замок dpkg держит unattended-upgrades -- apt-get обязан
#     ждать его, а не падать; ответ apt при сбое -- в журнал и на экран, не в /dev/null;
#  2. неинтерактивный прогон (--yes, `> install.log`) не печатает пароль бэкапа.
# Функции берём НАСТОЯЩИЕ из установщика; apt-get -- заглушка (без root и сети).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/install-agent.sh"
MEM="$ROOT/agent-kit/scripts/setup-memory.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "✗ $*" >&2; exit 1; }

# ── 1. статика: ни одного голого apt-get мимо обёртки ─────────────────────────
# Команда apt-get (install/update/...), не комментарий и не текст сообщения.
APT_CMD='(^|[;&|({[:space:]])apt-get[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(install|update|upgrade|dist-upgrade|remove|purge)\b'
bare="$(grep -nE "$APT_CMD" "$S" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$bare" ]] || fail "apt-get мимо apt_get/apt_quiet (не ждёт замок dpkg):
$bare"
awk '/^apt_get\(\) \{$/,/^\}$/' "$S" | grep -qF 'apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"' \
  || fail "apt_get не передаёт DPkg::Lock::Timeout"
grep -qE '^APT_LOCK_TIMEOUT=[1-9][0-9]*$' "$S" || fail "нет APT_LOCK_TIMEOUT"
# nodesource зовёт apt-get сам -- ожидание замка ему через APT_CONFIG
grep -qF 'printf '"'"'DPkg::Lock::Timeout "%s";\n'"'"' "$APT_LOCK_TIMEOUT" > "$apt_conf"' "$S" \
  && grep -qE 'setup_\$\{NODE_MAJOR\}\.x" \| APT_CONFIG="\$apt_conf" bash -' "$S" \
  || fail "скрипт nodesource ставит пакеты без ожидания замка dpkg"
n_wrapped="$(grep -cE '(^|[;&|({[:space:]])apt_(get|quiet)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(install|update)\b' "$S")"
(( n_wrapped >= 7 )) || fail "вызовов apt через обёртку $n_wrapped, ждал не меньше 7"
# Ответ apt больше не выбрасывается
if grep -nE 'apt_(get|quiet)[^#]*>/dev/null' "$S"; then fail "вывод apt снова уходит в /dev/null"; fi
grep -q 'docker не встал — поставь руками (apt install docker.io) и повтори' "$S" \
  || fail "пропало сообщение «docker не встал»"
# setup-memory.sh зовёт установщик -- там тоже ждём замок
while IFS= read -r line; do
  [[ "$line" == *"DPkg::Lock::Timeout="* ]] || fail "setup-memory.sh: apt-get без ожидания замка: $line"
done < <(grep -E "$APT_CMD" "$MEM" | grep -vE '^[[:space:]]*#')

# ── 2. apt_quiet: замок занят -> код apt наружу, ответ apt в журнале и на экране
eval "$(awk '/^ok\(\)/{print} /^warn\(\)/{print} /^APT_LOCK_TIMEOUT=/{print} /^APT_RETRY_PAUSE=/{print}
             /^apt_get\(\) \{$/,/^\}$/{print} /^apt_quiet\(\) \{$/,/^\}$/{print}
             /^show_backup_pass\(\) \{/,/^\}$/{print}' "$S")"
declare -F apt_get >/dev/null && declare -F apt_quiet >/dev/null && declare -F show_backup_pass >/dev/null \
  || fail "не нашёл apt_get/apt_quiet/show_backup_pass в установщике"
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<EOF
#!/bin/sh
echo "\$*" >> "$T/args"
[ -f "$T/apt.ok" ] && exit 0
echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 812 (unattended-upgr)" >&2
exit 100
EOF
chmod +x "$T/bin/apt-get"
APT_LOG="$T/apt.log"
# Короткие тайминги: сломанная обёртка, которая крутит install по кругу, валит тест за
# секунды, а не вешает CI на APT_LOCK_TIMEOUT.
APT_LOCK_TIMEOUT=2; APT_RETRY_PAUSE=1
PATH="$T/bin:$PATH"
for i in $(seq 1 20); do echo "OLD-RUN-LINE $i"; done > "$APT_LOG"   # прошлые вызовы в журнале
rc=0; out="$(apt_quiet install -y -qq docker.io 2>&1)" || rc=$?
grep -q 'OLD-RUN-LINE' <<<"$out" && fail "при сбое на экран попал хвост прошлых вызовов apt: $out"
(( rc == 100 )) || fail "apt_quiet проглотил код apt ($rc, ждал 100)"
(( $(wc -l < "$T/args") == 1 )) || fail "install повторяется сам -- ждать должен apt, не цикл"
grep -q -- "-o DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT install -y -qq docker.io" "$T/args" \
  || fail "apt-get позван без ожидания замка: $(cat "$T/args")"
grep -q 'Could not get lock' <<<"$out" || fail "ответа apt нет на экране: $out"
grep -q 'Could not get lock' "$APT_LOG" || fail "ответа apt нет в журнале $APT_LOG"
touch "$T/apt.ok"
rc=0; out="$(apt_quiet install -y -qq git 2>&1)" || rc=$?
(( rc == 0 )) && [[ -z "$out" ]] || fail "удачный apt_quiet шумит или падает (rc=$rc): $out"
# update: замок списков apt не ждёт -- apt_get повторяет сам и выходит, когда отпустило
APT_RETRY_PAUSE=0; : > "$T/args"
cat > "$T/bin/apt-get" <<EOF
#!/bin/sh
echo "\$*" >> "$T/args"
[ "\$(wc -l < "$T/args")" -ge 3 ] && exit 0
echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 640 (apt-get)" >&2
exit 100
EOF
rc=0; apt_get update -qq >/dev/null 2>&1 || rc=$?
(( rc == 0 )) && (( $(wc -l < "$T/args") == 3 )) \
  || fail "update не дождался замка списков (rc=$rc, вызовов $(wc -l < "$T/args"), ждал 3)"
# Замок так и не отпустили -- после APT_LOCK_TIMEOUT код apt наружу, без вечного цикла
: > "$T/args"; rc=0; APT_LOCK_TIMEOUT=0 apt_get update -qq >/dev/null 2>&1 || rc=$?
(( rc == 100 )) || fail "update с вечным замком: код $rc, ждал 100"
cat > "$T/bin/apt-get" <<EOF
#!/bin/sh
echo "\$*" >> "$T/args"
[ -f "$T/apt.ok" ] && exit 0
echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 812 (unattended-upgr)" >&2
exit 100
EOF
# Тот же путь, что у установщика под set -e: die срабатывает, ответ apt на месте
rm -f "$T/apt.ok"
rc=0; out="$(bash -c "set -euo pipefail; PATH='$T/bin':\$PATH; $(declare -f ok warn apt_get apt_quiet)
  die() { echo \"DIE \$*\"; exit 1; }; APT_LOCK_TIMEOUT=2; APT_RETRY_PAUSE=1; APT_LOG='$T/apt2.log'
  apt_quiet install -y -qq docker.io && true || die 'docker не встал'" 2>&1)" || rc=$?
(( rc == 1 )) && grep -q 'DIE docker не встал' <<<"$out" && grep -q 'Could not get lock' <<<"$out" \
  || fail "под set -e сбой apt не дошёл до die с ответом apt (rc=$rc): $out"

# ── 3. пароль бэкапа: неинтерактивно -- не в журнал ───────────────────────────
PASS="Zq7SmokePassw0rdXy12abcd"; PF="/home/agent/.claude-lab/x/secrets/backup.pass"
ASSUME_YES=1; out="$(show_backup_pass "$PASS" "$PF" 2>&1)"
grep -q "$PASS" <<<"$out" && fail "--yes: пароль бэкапа напечатан в журнал"
grep -qF "$PF" <<<"$out" || fail "--yes: не сказано, где лежит пароль: $out"
grep -q 'Telegram' <<<"$out" || fail "--yes: не сказано, что пароль придёт в Telegram: $out"
ASSUME_YES=0; out="$(show_backup_pass "$PASS" "$PF" 2>&1 </dev/null)"
grep -q "$PASS" <<<"$out" && fail "вывод не в терминал (> install.log): пароль напечатан"
# Человек у терминала -- как раньше: пароль на экране и пауза «Сохранил?»
if command -v script >/dev/null 2>&1; then
  declare -f ok show_backup_pass > "$T/fn.sh"
  printf '\n' | timeout 20 script -qec "bash -c 'ASSUME_YES=0; . \"$T/fn.sh\"; show_backup_pass \"$PASS\" \"$PF\"'" \
    "$T/tty.log" >/dev/null 2>&1 || true
  grep -q "$PASS" "$T/tty.log" || fail "интерактивный прогон перестал показывать пароль: $(cat "$T/tty.log")"
  grep -q 'Сохранил пароль?' "$T/tty.log" || fail "интерактивный прогон не ждёт «Сохранил пароль?»"
  # --yes в терминале (cloud-init с консолью, tee в журнал) -- пароля нет и там
  printf '\n' | timeout 20 script -qec "bash -c 'ASSUME_YES=1; . \"$T/fn.sh\"; show_backup_pass \"$PASS\" \"$PF\"'" \
    "$T/tty-yes.log" >/dev/null 2>&1 || true
  grep -q "$PASS" "$T/tty-yes.log" && fail "--yes в терминале: пароль бэкапа напечатан"
  grep -qF "$PF" "$T/tty-yes.log" || fail "--yes в терминале: не сказано, где лежит пароль: $(cat "$T/tty-yes.log")"
else
  echo "· script(1) нет -- ветку с терминалом пропускаю"
fi

echo "✓ install-agent fresh-box smoke ok"
