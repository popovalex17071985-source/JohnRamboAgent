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

# ── 4. swap (Smith 01.11.2026, Ubuntu 22.04, util-linux 2.37.2) ──────────────
# `mkswap -q` -> «invalid option -- 'q'», so no box got swap since 19.08; and a 2 GB box
# (above the old 1.8 GB line) had tsc OOM-killed next to Claude + OpenViking.
eval "$(awk '/^ok\(\)/{print} /^warn\(\)/{print} /^SWAP_[A-Z_]+=/{print}
             /^make_swap\(\) \{/,/^\}$/{print} /^ensure_swap\(\) \{$/,/^\}$/{print}' "$S")"
declare -F ensure_swap >/dev/null && declare -F make_swap >/dev/null \
  || fail "не нашёл ensure_swap/make_swap в установщике"
[[ "${SWAP_MIN_RAM_KB:-}" =~ ^[0-9]+$ ]] || fail "порог свопа -- не именованная константа SWAP_MIN_RAM_KB"
mkdir -p "$T/sw"
# util-linux 2.37.2 behaviour: no -q; prints to stdout on success
cat > "$T/sw/mkswap" <<EOF
#!/bin/sh
echo "mkswap \$*" >> "$T/sw.args"
for a in "\$@"; do case "\$a" in -q) echo "mkswap: invalid option -- 'q'" >&2; exit 1;; esac; done
[ -f "$T/sw.mkswap-fail" ] && { echo "mkswap: \$1: insecure permissions 0644" >&2; exit 1; }
echo "Setting up swapspace version 1, size = 2 GiB"
EOF
cat > "$T/sw/swapon" <<EOF
#!/bin/sh
echo "swapon \$*" >> "$T/sw.args"
[ "\$1" = --show ] && { [ -f "$T/sw.active" ] && echo "/swapfile file 2G 0B -2"; exit 0; }
touch "$T/sw.active"
EOF
printf '#!/bin/sh\n: > "$3"\n' > "$T/sw/fallocate"
chmod +x "$T/sw/mkswap" "$T/sw/swapon" "$T/sw/fallocate"
swap_run() {  # swap_run MEM_KB [keep] -> output; state in $T/sw.*; keep = swap already on
  [[ "${2:-}" == keep ]] || { rm -f "$T/sw.active"; : > "$T/fstab"; }
  rm -f "$T/sw.args"
  printf 'MemTotal:       %s kB\n' "$1" > "$T/meminfo"
  SWAP_FILE="$T/swapfile" FSTAB="$T/fstab" MEMINFO="$T/meminfo" PATH="$T/sw:$PATH" ensure_swap 2>&1
}
# Smith: 1968 MB in free -m
out="$(swap_run 2015232)"
[[ -f "$T/sw.active" ]] || fail "2 ГБ памяти: своп не поднят (порог $SWAP_MIN_RAM_KB кБ): $out $(cat "$T/sw.args" 2>/dev/null)"
grep -q -- "^$T/swapfile none swap sw 0 0$" "$T/fstab" || fail "своп не записан в fstab: $(cat "$T/fstab")"
grep -q 'своп 2 ГБ' <<<"$out" || fail "нет строки об успехе свопа: $out"
grep -q 'Setting up swapspace' <<<"$out" && fail "болтовня mkswap на экране: $out"
out="$(swap_run 2015232 keep)"; (( $(grep -c swapfile "$T/fstab") <= 1 )) || fail "fstab: своп дописан дважды"
grep -q '^mkswap' "$T/sw.args" && fail "своп уже есть -- а установщик делает новый"
# 4 GB box: no swap needed
out="$(swap_run 4026531)"
[[ -f "$T/sw.active" ]] && fail "4 ГБ памяти: своп поднят зря"
# the real error reaches the screen, not a guess about btrfs/zfs
touch "$T/sw.mkswap-fail"; out="$(swap_run 2015232)"; rm -f "$T/sw.mkswap-fail"
grep -q 'insecure permissions' <<<"$out" || fail "при сбое свопа не видно настоящей ошибки: $out"
grep -q 'btrfs/zfs/контейнер?' <<<"$out" && fail "при сбое свопа -- догадка про btrfs/zfs вместо ошибки: $out"
[[ -e "$T/swapfile" ]] && fail "после сбоя свопа файл остался"
echo "✓ своп: mkswap без -q, порог $SWAP_MIN_RAM_KB кБ, настоящая ошибка на экране"

# ── 5. OpenViking container runs as the agent, not root (Smith 01.11.2026) ────
# A root container on the bind mount left root:600 files in ~agent/.openviking, and the
# agent's nightly backup could not read them. Every `docker run` of it is evaluated with
# a docker stub: the --user it gets must be the agent's uid:gid.
mkdir -p "$T/dk"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/docker.args"\n' "$T" > "$T/dk/docker"; chmod +x "$T/dk/docker"
me="$(id -un)"; want="--user $(id -u):$(id -g)"
n_runs=0
for f in "$S" "$MEM"; do
  while IFS= read -r cmd; do
    n_runs=$((n_runs + 1)); : > "$T/docker.args"
    ( die() { :; }; SERVICE_USER="$me" OWNER="$me" OV_DIR="$T/ov" OPENVIKING_IMAGE=img OV_IMAGE=img
      PATH="$T/dk:$PATH"; eval "$cmd" ) >/dev/null 2>&1 || true
    grep -qF -- "$want " "$T/docker.args" \
      || fail "$(basename "$f"): контейнер памяти запускается не под агентом ($want): $(cat "$T/docker.args")"
  done < <(awk '/docker run .*--name openviking/{c=1} c{l=l $0; if ($0 ~ /\\$/) sub(/\\$/, "", l); else {print l; l=""; c=0}}' "$f")
done
(( n_runs >= 2 )) || fail "нашёл $n_runs запусков контейнера памяти, ждал 2 (установщик + setup-memory)"
echo "✓ контейнер памяти: $n_runs запуска, все под пользователем агента"

# umask 022 right after `set -euo pipefail`, before anything installs (Smith 19.10: an
# inherited 077 left Claude Code unreadable for the agent user).
awk '/^set -euo pipefail/{if(!s)s=NR} /^umask 022$/{if(!u)u=NR} /^(apt_get|install_node|NODE_MAJOR)/{if(!f)f=NR} END{exit !(s && u && u>s && u<f)}' \
  "$ROOT/scripts/install-agent.sh" || fail "нет umask 022 в начале установщика"

echo "✓ install-agent fresh-box smoke ok"
