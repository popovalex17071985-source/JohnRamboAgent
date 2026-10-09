#!/usr/bin/env bash
# Смоук доп. путей бэкапа (deploy/backup-extra-paths): то, что живёт ВНЕ
# workspace, едет в тот же архив под extra/<путь>, а имена workspace и
# .openviking не меняются. Без конфига архив — ровно как раньше.
# Всё во временной песочнице: свой HOME, workspace, пароль, без rclone.
set -euo pipefail

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
S="$PLUGIN/scripts/agent-backup.sh"
R="$PLUGIN/scripts/restore-agent.sh"
fail() { echo "✗ $1" >&2; exit 1; }
ok() { echo "✓ $1"; }
bash -n "$S" || fail "синтаксис agent-backup.sh"
bash -n "$R" || fail "синтаксис restore-agent.sh"

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
H="$box/home"; WS="$box/ws"; EXT="$box/ext"; AGENT="smoke$$"
mkdir -p "$H/.openviking/data" "$WS/.claude/memory" "$WS/secrets" "$WS/state/__pycache__" \
         "$EXT/bin/__pycache__" "$EXT/bin/node_modules/m" "$EXT/units" "$EXT/dir with space"
echo ov > "$H/.openviking/data/mem.db"
echo "# память" > "$WS/.claude/memory/MEMORY.md"
echo smokepass > "$WS/secrets/backup.pass"
echo st > "$WS/state/s.json"
echo pyc > "$WS/state/__pycache__/w.pyc"          # workspace: исключения extras НЕ должны его резать
echo 'print(1)' > "$EXT/bin/run.py"
echo x > "$EXT/bin/__pycache__/run.cpython-310.pyc"
echo x > "$EXT/bin/old.pyc"
echo x > "$EXT/bin/node_modules/m/i.js"
echo unit > "$EXT/units/a.service"
echo timer > "$EXT/units/b.timer"
echo conf > "$EXT/units/c.conf"
echo sp > "$EXT/dir with space/f.txt"

# Прогон бэкапа в своей папке: имя архива по минуте, два прогона подряд не должны
# перетирать друг друга.
run() {  # run <скрипт> <папка бэкапов>
  HOME="$H" DASHI_AGENT="$AGENT" DASHI_WORKSPACE="$WS" DASHI_BACKUP_DIR="$2" \
    RCLONE_BIN=/nonexistent/rclone bash "$1" >/dev/null 2>&1
  local a; a="$(ls -1 "$2"/"$AGENT"-*.tar.gz.gpg 2>/dev/null | head -1)"
  [[ -n "$a" ]] || fail "архив не создан ($1), лог: $(tail -3 "$WS/logs/backup.log")"
  gpg --batch --quiet --passphrase-file "$WS/secrets/backup.pass" -d "$a" | tar tzf - | sort
}

# 1. Без конфига — листинг как у старой версии скрипта (main), без extra/.
new_list="$(run "$S" "$box/b-new")"
grep -q '^extra/' <<<"$new_list" && fail "без конфига в архиве появился extra/"
if old_src="$(git -C "$PLUGIN" show main:scripts/agent-backup.sh 2>/dev/null)"; then
  printf '%s\n' "$old_src" > "$box/old-backup.sh"
  old_list="$(run "$box/old-backup.sh" "$box/b-old")"
  [[ "$old_list" == "$new_list" ]] || { diff <(echo "$old_list") <(echo "$new_list") >&2; fail "без конфига листинг отличается от main"; }
  ok "без конфига листинг = main ($(wc -l <<<"$new_list") записей)"
else
  echo "! нет ветки main — сравнение со старой версией пропущено"
fi

# 2. С конфигом.
cat > "$WS/deploy/backup-extra-paths" <<EOF
# бизнес-скрипты
$EXT/bin

$EXT/units/*.service   # юниты
$EXT/units/*.timer
$EXT/dir with space
$EXT/missing
$EXT/units/*.nomatch
relative/path
EOF
list="$(run "$S" "$box/b-extra")"
P="extra/${EXT#/}"
has()  { grep -qxF "$1" <<<"$list" || fail "в архиве нет: $1"; }
hasnt(){ grep -qF "$1" <<<"$list" && fail "в архиве лишнее: $1"; return 0; }
has "$P/bin/run.py"
has "$P/units/a.service"
has "$P/units/b.timer"
has "$P/dir with space/f.txt"
hasnt "$P/units/c.conf"
hasnt "$P/bin/__pycache__"
hasnt "$P/bin/old.pyc"
hasnt "$P/bin/node_modules"
# ни одного extra-пути без префикса extra/
awk -v p="${EXT#/}/" 'index($0, p) == 1 { bad = 1 } END { exit bad }' <<<"$list" \
  || fail "extra-путь попал в архив без префикса extra/"
ok "extras в архиве под $P/, мусор (__pycache__/*.pyc/node_modules) отрезан"

has ".claude/memory/MEMORY.md"
has "secrets/backup.pass"
has "state/s.json"
has "state/__pycache__/w.pyc"
has ".openviking/data/mem.db"
grep -qE '^extra/(\.claude|secrets|state|deploy|\.openviking)' <<<"$list" && fail "transform задел имена workspace"
ok "имена workspace и .openviking не тронуты, исключения extras в workspace не протекли"

# Без конфиговых строк листинг workspace-части совпадает с прогоном без конфига
# (кроме самого конфига в deploy/).
diff <(grep -v '^extra/' <<<"$list" | grep -vx 'deploy/backup-extra-paths') <(echo "$new_list") >/dev/null \
  || fail "с конфигом поменялась workspace-часть архива"

L="$WS/logs/backup.log"
grep -q "extra: пропуск, нет такого пути/пустой глоб: $EXT/missing" "$L" || fail "нет строки про отсутствующий путь"
grep -q "extra: пропуск, нет такого пути/пустой глоб: $EXT/units/\*.nomatch" "$L" || fail "нет строки про пустой глоб"
grep -q "extra: пропуск, путь не абсолютный: relative/path" "$L" || fail "нет строки про относительный путь"
grep -q "self-check пройден" "$L" || fail "self-check не прошёл"
ok "пропуски залогированы, self-check пройден"

# Содержимое доезжает байт в байт.
mkdir "$box/x"
gpg --batch --quiet --passphrase-file "$WS/secrets/backup.pass" -d "$(ls "$box/b-extra"/*.gpg)" | tar xzf - -C "$box/x"
cmp -s "$EXT/units/a.service" "$box/x/$P/units/a.service" || fail "содержимое юнита не совпало"
ok "распаковка: файл совпадает"

# 3. restore: блок про extra/ печатает, где лежит, и пример — и ничего не копирует.
out="$(WORKSPACE="$box/x" bash -c '
  say(){ echo "==> $*"; }; warn(){ echo "! $*"; }
  eval "$(sed -n "/^# 5b\./,/^# 6\./p" "$1")"' _ "$R")"
grep -q "$box/x/extra/" <<<"$out" || fail "restore не сказал, где лежит extra/"
grep -q "sudo cp -a --backup=numbered \"$box/x/extra$EXT/bin/.\" \"$EXT/bin/\"" <<<"$out" \
  || { echo "$out" >&2; fail "restore не дал пример возврата"; }
ok "restore: подсказка по extra/ есть, авто-перезаписи нет"

echo "✓ backup-extra-paths smoke ok"
