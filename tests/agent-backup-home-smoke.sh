#!/usr/bin/env bash
# Smoke for the whole-home backup (format 2): agent-backup.sh archives the
# agent's ENTIRE home minus deploy/backup-exclude.txt, plus deploy/backup-extra-paths
# outside home, plus snapshots (apt, venvs, units, crontab). Also covers the pure
# helpers in backup-lib.sh, the off-site watchdog and the password hand-over.
# Runs in a sandbox: own HOME, fake crontab/systemctl, no rclone, no network.
set -euo pipefail

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
S="$PLUGIN/scripts/agent-backup.sh"
W="$PLUGIN/scripts/backup-offsite-watch.sh"
P="$PLUGIN/scripts/backup-pass-send.sh"
R="$PLUGIN/scripts/restore-agent.sh"
L="$PLUGIN/scripts/backup-lib.sh"
fail() { echo "✗ $1" >&2; exit 1; }
ok() { echo "✓ $1"; }
for f in "$S" "$W" "$P" "$R" "$L"; do bash -n "$f" || fail "синтаксис $(basename "$f")"; done

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
H="$box/home/agentx"; WS="$H/.claude-lab/smoke"; EXT="$box/opt/app"; AGENT="smoke$$"
SHIM="$box/shim"; mkdir -p "$SHIM"

# ── 1. pure helpers ─────────────────────────────────────────────────────────
# shellcheck source=../scripts/backup-lib.sh
source "$L"
[[ "$(bk_to_member /home/a/x/)" == "home/a/x" ]] || fail "bk_to_member"
[[ "$(bk_exclude_pattern '~/.cache   # кэш' /home/a)" == "home/a/.cache" ]] || fail "~/ -> home"
[[ "$(bk_exclude_pattern '/opt/x/*' /home/a)" == "opt/x/*" ]] || fail "abs -> member"
[[ "$(bk_exclude_pattern 'node_modules' /home/a)" == "node_modules" ]] || fail "bare name"
[[ -z "$(bk_exclude_pattern '   # только комментарий' /home/a)" ]] || fail "comment line"
se="$(mktemp)"
( OLD_HOME="/home/o'brien"; WORKSPACE="/home/o'brien/.claude-lab/a b"; KIND='claude'
  bk_write_state_env "$se" OLD_HOME WORKSPACE KIND ) || fail "bk_write_state_env упал"
( source "$se"
  [[ "$OLD_HOME" == "/home/o'brien" && "$WORKSPACE" == "/home/o'brien/.claude-lab/a b" && "$KIND" == claude ]] ) \
  || fail "state env с кавычкой в пути не читается обратно: $(cat "$se")"
rm -f "$se"
ok "state env: кавычка и пробел в пути переживают source"
for bad in '~' '~/' '/' '*' '/home/a' '~/*'; do
  if bk_exclude_pattern "$bad" /home/a >/dev/null; then fail "опасная строка принята: $bad"; fi
done
ok "шаблоны исключений: ~/, абсолютные, имена, опасные строки отвергаются"

dirs="$(printf '%s\n' \
  '*/5 * * * * /home/a/bin/x.sh >> /home/a/ws/logs/x.log 2>&1' \
  '0 3 * * * cd /home/a && ./y >/home/a/proj/logs/y.log 2>/dev/null' \
  '# 0 1 * * * z >> /home/a/commented/z.log' \
  '1 1 * * * q 2>>/var/log/agent/q.err' | bk_log_dirs_from_cron)"
[[ "$dirs" == $'/home/a/proj/logs\n/home/a/ws/logs\n/var/log/agent' ]] || fail "лог-папки из крона: $dirs"
ok "лог-папки из крона"

req="$(printf '%s\n' 'requests==2.31.0' '-e git+https://x/y.git#egg=y' 'loc @ file:///tmp/loc' 'six==1.16.0' \
  | bk_freeze_filter 2>/dev/null)"
[[ "$req" == $'requests==2.31.0\nsix==1.16.0' ]] || fail "freeze filter: $req"
ok "pip freeze: editable и локальные пакеты отсеяны"

printf 'TELEGRAM_BOT_TOKEN=1:AA\nTELEGRAM_ALLOWED_USER_IDS=111,222\n' >"$box/c.env"
printf 'TELEGRAM_TOKEN=2:BB\nTELEGRAM_CHAT_ID=333\nDASHI_BACKUP_ALERT_CHATS=444, 555\n' >"$box/x.env"
[[ "$(bk_tg_token "$box/c.env")/$(bk_tg_owner "$box/c.env")" == "1:AA/111" ]] || fail "claude env"
[[ "$(bk_tg_token "$box/x.env")/$(bk_tg_owner "$box/x.env")" == "2:BB/333" ]] || fail "codex env"
[[ "$(bk_tg_extra_chats "$box/x.env" | paste -sd,)" == "444,555" ]] || fail "extra chats"
ok "токен и чат хозяина из channel.env (Claude) и .env (Codex)"

# ── 2. a fake agent home with real work in it ───────────────────────────────
mkdir -p "$WS/.claude/memory" "$WS/secrets" "$WS/logs" "$WS/state/telegram/inbox" "$WS/deploy" \
         "$WS/.claude/dashi-plugin-claude-code/.git" "$WS/backups" \
         "$H/projects/shop/node_modules/m" "$H/projects/shop/logs" "$H/projects/shop/tmp" \
         "$H/.local/bin" "$H/.cache/pip" "$H/.claude/projects/p/memory" \
         "$EXT/__pycache__" "$box/etc-systemd" "$box/opt/units" "$box/opt/dir with space"
echo "# память" >"$WS/.claude/memory/MEMORY.md"
echo smokepass >"$WS/secrets/backup.pass"
echo "line" >"$WS/logs/cron-job.log"
echo photo >"$WS/state/telegram/inbox/p.jpg"
echo plugin >"$WS/.claude/dashi-plugin-claude-code/README.md"
echo old >"$WS/backups/$AGENT-20000101-0000.tar.gz.gpg"
echo 'print("shop")' >"$H/projects/shop/app.py"
echo '{"name":"shop"}' >"$H/projects/shop/package.json"
echo x >"$H/projects/shop/node_modules/m/i.js"
echo applog >"$H/projects/shop/logs/app.log"
echo tmp >"$H/projects/shop/tmp/t"
printf '#!/bin/sh\necho tool\n' >"$H/.local/bin/mytool"; chmod +x "$H/.local/bin/mytool"
echo cache >"$H/.cache/pip/blob"
echo '{"t":1}' >"$H/.claude/projects/p/s1.jsonl"
echo "# auto memory" >"$H/.claude/projects/p/memory/MEMORY.md"
echo 'print(1)' >"$EXT/run.py"
echo x >"$EXT/__pycache__/run.cpython-310.pyc"
echo unit >"$box/opt/units/a.service"; echo conf >"$box/opt/units/c.conf"
echo sp >"$box/opt/dir with space/f.txt"
printf '[Service]\nUser=nobody-else\nExecStart=%s/projects/shop/app.py\n' "$H" >"$box/etc-systemd/shop.service"
printf '[Service]\nExecStart=/usr/bin/other\n' >"$box/etc-systemd/foreign.service"
# a timer whose service carries the agent's name but no home path (cron-canary-<agent>)
printf '[Service]\nExecStart=/usr/local/bin/canary\n' >"$box/etc-systemd/cron-canary-$AGENT.service"
printf '[Timer]\nOnCalendar=minutely\n' >"$box/etc-systemd/cron-canary-$AGENT.timer"
VENV_OK=0
if python3 -m venv "$H/projects/shop/.venv" >/dev/null 2>&1 && [[ -x "$H/projects/shop/.venv/bin/pip" ]]; then
  VENV_OK=1
fi
cat >"$WS/deploy/backup-extra-paths" <<EOF
$EXT
$box/opt/units/*.service   # юниты
$box/opt/dir with space
$box/opt/missing
relative/path
EOF
# Fake crontab/systemctl: the sandbox must not read the real user's schedule.
printf '#!/bin/sh\n[ "$1" = -l ] && echo "*/5 * * * * %s/.local/bin/mytool >> %s/logs/cron-job.log 2>&1"\n' "$H" "$WS" >"$SHIM/crontab"
printf '#!/bin/sh\nexit 1\n' >"$SHIM/systemctl"
chmod +x "$SHIM"/*

run_backup() {  # run_backup [args...]
  HOME="$H" PATH="$SHIM:$PATH" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" \
    DASHI_SYSTEMD_DIR="$box/etc-systemd" RCLONE_BIN=/nonexistent/rclone bash "$S" "$@"
}
newest() { ls -1t "$WS/backups/$AGENT"-*.tar.gz.gpg 2>/dev/null | grep -v -e 20000101 -e 21000101 | head -1; }

# --init-excludes writes defaults once, never overwrites the owner's edits.
run_backup --init-excludes >/dev/null
[[ -s "$WS/deploy/backup-exclude.txt" ]] || fail "нет deploy/backup-exclude.txt после --init-excludes"
echo "~/projects/shop/tmp   # своя строка хозяина" >>"$WS/deploy/backup-exclude.txt"
run_backup --init-excludes >/dev/null
grep -q 'своя строка хозяина' "$WS/deploy/backup-exclude.txt" || fail "--init-excludes перетёр правку хозяина"
ok "список исключений создаётся один раз и не перетирается"

pe="$(run_backup --print-excludes)"
grep -qx "${H#/}/.cache" <<<"$pe" || fail "в исключениях нет ~/.cache: $pe"
grep -qx "${WS#/}/backups" <<<"$pe" || fail "каталог архивов не исключён автоматически"
grep -qx "${WS#/}/.claude/dashi-plugin-claude-code" <<<"$pe" || fail "git-копия плагина не исключена"
if [[ $VENV_OK -eq 1 ]]; then
  grep -qx "${H#/}/projects/shop/.venv" <<<"$pe" || fail "venv не исключён автоматически"
fi
ok "исключения: из файла + автоматические (архивы, плагин, venv)"

run_backup >/dev/null
A="$(newest)"; [[ -n "$A" ]] || fail "архив не создан: $(tail -5 "$WS/logs/backup.log")"
list="$(gpg --batch --quiet --passphrase-file "$WS/secrets/backup.pass" -d "$A" | tar tzf - | sed 's#/$##' | sort)"
has()  { grep -qxF "$1" <<<"$list" || fail "в архиве нет: $1"; }
hasnt(){ if grep -qF "$1" <<<"$list"; then fail "в архиве лишнее: $1"; fi; }
HM="${H#/}"; WM="${WS#/}"
has "DASHI-BACKUP.json"
has "$WM/.claude/memory/MEMORY.md"
has "$WM/secrets/backup.pass"
has "$HM/projects/shop/app.py"
has "$HM/projects/shop/package.json"
has "$HM/.local/bin/mytool"
has "$HM/.claude/projects/p/memory/MEMORY.md"
has "$WM/logs"                       # the dir stays (cron appends into it) ...
hasnt "$WM/logs/cron-job.log"         # ... its content does not
has "$HM/projects/shop/logs"
hasnt "$HM/projects/shop/logs/app.log"
hasnt "$HM/projects/shop/tmp/t"
hasnt "$HM/projects/shop/node_modules"
hasnt "$HM/.cache"
hasnt "$HM/.claude/projects/p/s1.jsonl"
hasnt "$WM/state/telegram/inbox/p.jpg"
hasnt "$WM/.claude/dashi-plugin-claude-code"
hasnt "$WM/backups/"
hasnt "$HM/projects/shop/.venv"
has "${EXT#/}/run.py"
hasnt "${EXT#/}/__pycache__"
has "${box#/}/opt/units/a.service"
hasnt "${box#/}/opt/units/c.conf"
has "${box#/}/opt/dir with space/f.txt"
grep -q "extra: пропуск, нет такого пути/пустой глоб: $box/opt/missing" "$WS/logs/backup.log" || fail "нет строки про отсутствующий extra-путь"
grep -q "extra: пропуск, путь не абсолютный: relative/path" "$WS/logs/backup.log" || fail "нет строки про относительный extra-путь"
ok "архив: вся домашка + extra, мусор и логи отрезаны, пустые лог-папки остались"

x="$box/x"; mkdir -p "$x"
gpg --batch --quiet --passphrase-file "$WS/secrets/backup.pass" -d "$A" | tar xzf - -C "$x"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["format"]==2, m; assert m["home"]==sys.argv[2], m; assert m["workspace"]==sys.argv[3], m; assert sys.argv[4] in m["extras"] and len(m["extras"])==3, m' \
  "$x/DASHI-BACKUP.json" "$H" "$WS" "$EXT" || fail "манифест неверный: $(cat "$x/DASHI-BACKUP.json")"
cmp -s "$box/opt/dir with space/f.txt" "$x/${box#/}/opt/dir with space/f.txt" || fail "extra-файл распаковался не байт в байт"
ok "extra: глоб, пробел в пути, пропуски залогированы, содержимое байт в байт"
D="$x/$WM/deploy"
grep -q "mytool" "$D/crontab.txt" || fail "crontab не снят"
[[ -f "$D/apt-manual.txt" ]] || fail "нет apt-manual.txt"
[[ -s "$D/timezone.txt" ]] || fail "часовой пояс сервера не снят (deploy/timezone.txt)"
[[ -f "$D/systemd-system/shop.service" ]] || fail "юнит, который запускает код из домашки, не снят"
[[ -f "$D/systemd-system/foreign.service" ]] && fail "чужой юнит попал в снимок"
[[ -f "$D/systemd-system/cron-canary-$AGENT.timer" ]] || fail "таймер своего сервиса не снят"
grep -qx "$H/projects/shop" "$D/node-projects.txt" || fail "проект с node_modules не записан"
if [[ $VENV_OK -eq 1 ]]; then
  snap="$(ls "$D"/pyenvs/*.txt 2>/dev/null | head -1)"
  [[ -n "$snap" ]] || fail "нет снимка venv"
  [[ "$(bk_venv_field "$snap" venv)" == "$H/projects/shop/.venv" ]] || fail "venv-путь в снимке: $(head -1 "$snap")"
  [[ "$(bk_venv_field "$snap" python)" =~ ^3\.[0-9]+$ ]] || fail "версия python в снимке: $(head -1 "$snap")"
  ok "снимки: crontab, apt, юниты агента, проекты node, venv ($(head -1 "$snap" | cut -c1-60)...)"
else
  echo "! python3 -m venv недоступен -- проверка venv пропущена"
fi
grep -q "self-check пройден" "$WS/logs/backup.log" || fail "self-check не прошёл"
grep -q "WARN: нет rclone-remote" "$WS/logs/backup.log" || fail "нет предупреждения про off-site"

# second run: the first archive must not end up inside the second one
# (archive names are per minute, so park the first one under another name)
mv "$A" "$WS/backups/$AGENT-21000101-0000.tar.gz.gpg"
run_backup >/dev/null
A2="$(newest)"; [[ -n "$A2" ]] || fail "второй архив не создан"
gpg --batch --quiet --passphrase-file "$WS/secrets/backup.pass" -d "$A2" | tar tzf - | grep -q 'tar.gz.gpg$' \
  && fail "архив попал внутрь архива"
ok "повторный прогон: старые архивы внутрь не попадают"

n_before="$(ls "$WS/backups/" | wc -l)"
HOME="$H" PATH="$SHIM:$PATH" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_BACKUP_FREE_BYTES=1000 \
  DASHI_SYSTEMD_DIR="$box/etc-systemd" RCLONE_BIN=/nonexistent/rclone bash "$S" >/dev/null
[[ "$(ls "$WS/backups/" | wc -l)" == "$n_before" ]] || fail "мало места, а архив (частичный) всё равно записан"
tail -3 "$WS/logs/backup.log" | grep -q "FAIL: мало места" || fail "мало места: нет понятной FAIL-строки: $(tail -2 "$WS/logs/backup.log")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] is False and "места" in d["error"], d' \
  "$WS/state/backup/last-attempt.json" || fail "мало места: попытка не записана для сторожа"
rm -f "$WS/state/backup/last-attempt.json"
ok "мало места на диске: падает до архива, понятная FAIL-строка, попытка записана для сторожа"

rep="$(run_backup --size-report)"
grep -q "итого" <<<"$rep" || fail "--size-report без итога: $rep"
ok "--size-report: $(grep итого <<<"$rep")"

# ── 3. off-site watchdog ────────────────────────────────────────────────────
printf 'TELEGRAM_BOT_TOKEN=1:AA\nTELEGRAM_ALLOWED_USER_IDS=111\nDASHI_BACKUP_ALERT_CHATS=999\n' >"$box/channel.env"
TG="$box/tg"
watch() {
  HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_CHANNEL_ENV="$box/channel.env" \
    RCLONE_BIN=/nonexistent/rclone DASHI_TG_DRYRUN_DIR="$TG" bash "$W" "$@"
}
watch >/dev/null
st="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$WS/state/backup/offsite-status.json")"
[[ "$st" == not_configured ]] || fail "без облака статус $st"
grep -l sendMessage "$TG"/*.call >/dev/null 2>&1 || fail "без облака хозяину не ушло"
grep -lx 'chat_id=999' "$TG"/*.call >/dev/null 2>&1 || fail "доп. получателю (оператору) не ушло"
grep -q "FAIL: off-site" "$WS/logs/backup-watch.log" || fail "нет FAIL-строки для сторожа провалов"
ok "сторож: облака нет -> хозяину и оператору, FAIL в лог"

rm -rf "$TG"
now=$(date +%s)
printf '{"ts": %s, "method": "gws", "file": "x.gpg"}\n' "$((now - 3600))" >"$WS/state/backup/last-offsite.json"
watch >/dev/null
[[ -z "$(ls "$TG"/*.call 2>/dev/null | xargs -r grep -l sendMessage)" ]] || fail "свежая копия, а сторож написал"
ok "сторож: свежая копия (час назад) -> молчит"

rm -rf "$TG"
printf '{"ts": %s, "method": "gws", "file": "x.gpg"}\n' "$((now - 50*3600))" >"$WS/state/backup/last-offsite.json"
watch >/dev/null
grep -rq "50" "$TG" || fail "старая копия (50 ч): нет сообщения с возрастом"
ok "сторож: копия старше 48 ч -> сообщение"

# fake rclone: listing is the primary source, the state file is only a fallback
cat >"$SHIM/rclone" <<EOF
#!/bin/sh
case "\$1" in
  listremotes) echo "gdrive:" ;;
  lsjson) echo '[{"Name":"$AGENT-20990101-0340.tar.gz.gpg","ModTime":"$(date -u -d '@'$((now - 7200)) +%Y-%m-%dT%H:%M:%SZ)","IsDir":false}]' ;;
esac
EOF
chmod +x "$SHIM/rclone"
rm -rf "$TG"
HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_CHANNEL_ENV="$box/channel.env" \
  RCLONE_BIN="$SHIM/rclone" DASHI_TG_DRYRUN_DIR="$TG" bash "$W" >/dev/null
st="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["status"],d["source"])' "$WS/state/backup/offsite-status.json")"
[[ "$st" == "ok rclone" ]] || fail "rclone-листинг свежий, а статус: $st"
ok "сторож: читает облако rclone, а не только свой файл"

# remote that resolves to a folder on this same box is NOT off-site
mkdir -p "$box/srv/offsite"
shim_rclone() {  # shim_rclone <config dump json>
  cat >"$SHIM/rclone" <<EOF
#!/bin/sh
case "\$1" in
  listremotes) echo "gdrive:" ;;
  lsjson) echo '[{"Name":"$AGENT-20990101-0340.tar.gz.gpg","ModTime":"$(date -u -d '@'$((now - 7200)) +%Y-%m-%dT%H:%M:%SZ)","IsDir":false}]' ;;
  config) echo '$1' ;;
esac
EOF
  chmod +x "$SHIM/rclone"
}
watch_r() {
  HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_CHANNEL_ENV="$box/channel.env" \
    RCLONE_BIN="$SHIM/rclone" DASHI_TG_DRYRUN_DIR="$TG" bash "$W" "$@"
}
status_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$WS/state/backup/offsite-status.json"; }
shim_rclone '{"gdrive":{"type":"alias","remote":"'"$box"'/srv/offsite"}}'
rm -rf "$TG"; watch_r >/dev/null
[[ "$(status_of)" == not_offsite ]] || fail "alias на локальную папку, а статус: $(status_of)"
grep -rq "этом же сервере" "$TG" || fail "alias на локальную папку: хозяину не ушло"
ok "сторож: alias -> папка на этом же диске = НЕ off-site, хозяину сообщение"
shim_rclone '{"gdrive":{"type":"local"}}'
rm -rf "$TG"; watch_r >/dev/null
[[ "$(status_of)" == not_offsite ]] || fail "remote типа local, а статус: $(status_of)"
ok "сторож: remote типа local = НЕ off-site"
shim_rclone '{"gdrive":{"type":"alias","remote":"'"$box"'/srv/offsite"}}'
rm -rf "$TG"; fails_before="$(grep -c 'FAIL: off-site' "$WS/logs/backup-watch.log")"
out="$(DASHI_BACKUP_OFFSITE_STUB="e2e Smith" watch_r --dry-run)"
[[ "$(status_of)" == stub && "$out" == stub:* ]] || fail "заглушка объявлена, а статус: $(status_of) / $out"
echo "e2e Smith" >"$WS/deploy/offsite-stub"; watch_r >/dev/null; rm -f "$WS/deploy/offsite-stub"
[[ "$(status_of)" == stub ]] || fail "заглушка файлом deploy/offsite-stub не распознана: $(status_of)"
[[ -z "$(ls "$TG"/*.call 2>/dev/null | xargs -r grep -l sendMessage)" ]] || fail "заглушка, а сторож написал"
[[ "$(grep -c 'FAIL: off-site' "$WS/logs/backup-watch.log")" == "$fails_before" ]] || fail "заглушка дала FAIL-строку"
grep -q 'STUB off-site' "$WS/logs/backup-watch.log" || fail "нет строки STUB в логе"
ok "сторож: объявленная заглушка = «stub», не OK и не тревога, никому не пишет"

# the cloud does not answer (expired login): its own status, not OK from the journal
cat >"$SHIM/rclone" <<'EOF'
#!/bin/sh
case "$1" in
  listremotes) echo "gdrive:" ;;
  lsjson) echo "Failed to create file system: couldn't fetch token: invalid_grant" >&2; exit 1 ;;
  config) echo '{"gdrive":{"type":"drive"}}' ;;
esac
EOF
chmod +x "$SHIM/rclone"
printf '{"ts": %s, "method": "rclone", "file": "x.gpg"}\n' "$((now - 3600))" >"$WS/state/backup/last-offsite.json"
rm -rf "$TG"; watch_r >/dev/null
[[ "$(status_of)" == unreachable ]] || fail "облако не ответило, а статус: $(status_of)"
grep -rq "invalid_grant" "$TG" || fail "unreachable: в сообщении нет текста ошибки"
ok "сторож: облако не отвечает (протух вход) -> «unreachable» с ошибкой, журнал не выдаёт OK"
# the journal speaks only for the gws path: an rclone record without rclone is no proof
rm -rf "$TG"
HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_CHANNEL_ENV="$box/channel.env" \
  RCLONE_BIN=/nonexistent/rclone DASHI_TG_DRYRUN_DIR="$TG" bash "$W" >/dev/null
[[ "$(status_of)" == not_configured ]] || fail "журнал rclone без rclone дал статус: $(status_of)"
rm -f "$WS/state/backup/last-offsite.json"
ok "сторож: журнал засчитывается только для gws"

# a real cloud with a fresh copy, but the LAST upload failed -> failing
shim_rclone '{"gdrive":{"type":"drive","scope":"drive"}}'
printf '{"ts": %s, "ok": false, "error": "mkdir /x: permission denied"}\n' "$((now - 600))" >"$WS/state/backup/last-attempt.json"
rm -rf "$TG"; watch_r >/dev/null
[[ "$(status_of)" == failing ]] || fail "последняя отправка упала, а статус: $(status_of)"
grep -rq "permission denied" "$TG" || fail "failing: в сообщении нет текста ошибки"
printf '{"ts": %s, "ok": true, "error": ""}\n' "$((now - 600))" >"$WS/state/backup/last-attempt.json"
rm -rf "$TG"; watch_r >/dev/null
[[ "$(status_of)" == ok ]] || fail "отправка удалась, облако настоящее, а статус: $(status_of)"
rm -f "$WS/state/backup/last-attempt.json"
ok "сторож: копия свежая, но последняя отправка упала -> «failing» с текстом ошибки"

# ── 4. password hand-over ───────────────────────────────────────────────────
# The watchdog above already retried the hand-over (password never delivered):
[[ -s "$WS/state/backup/password-delivered.json" ]] || fail "сторож не попробовал отдать пароль хозяину"
rm -rf "$TG" "$WS/state/backup/password-delivered.json"
pass_send() {
  HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_CHANNEL_ENV="$box/channel.env" \
    DASHI_TG_DRYRUN_DIR="$TG" bash "$P" "$@"
}
pass_send >/dev/null || fail "отправка пароля упала"
grep -rq sendDocument "$TG" || fail "пароль не ушёл файлом"
grep -rqx 'chat_id=111' "$TG" || fail "пароль ушёл не хозяину"
grep -rq 'chat_id=999' "$TG" && fail "пароль ушёл доп. получателю -- только хозяину!"
[[ -s "$WS/state/backup/password-delivered.json" ]] || fail "не записано, что пароль доставлен"
grep -rq smokepass "$TG" && fail "пароль попал в текст вызова (должен быть только в файле)"
rm -rf "$TG"; pass_send >/dev/null
[[ -z "$(ls "$TG" 2>/dev/null)" ]] || fail "повторная отправка без --force"
pass_send --force >/dev/null; grep -rq sendDocument "$TG" || fail "--force не отправил заново"
ok "пароль: файлом хозяину, отметка о доставке, повтор только с --force"

# ── 5. the installer wires all of it ────────────────────────────────────────
I="$PLUGIN/scripts/install-agent.sh"
grep -q 'backup-offsite-watch.sh' "$I" || fail "установщик не ставит сторожа облачной копии в крон"
grep -q 'agent-backup.sh" --init-excludes' "$I" || fail "установщик не создаёт список исключений"
grep -q 'backup-pass-send.sh' "$I" || fail "установщик не отправляет пароль хозяину"
ok "установщик: крон сторожа, список исключений, пароль хозяину"

echo "✓ agent-backup home smoke ok"
