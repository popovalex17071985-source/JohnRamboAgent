#!/usr/bin/env bash
# Еженедельная уборка диска на сервере агента: только то, что точно не живое.
#
# Зачем: установщик ограничивал рост журнала и бэкапов, но мусор от установок,
# обновлений и тестов копился, пока не чистили руками. 27.09.2026 у Смита было
# 26 из 40 ГБ: остановленный тестовый контейнер 5 ГБ, неиспользуемый образ
# памяти 1,7 ГБ, кэш пакетов 2,6 ГБ. Саня: «Делай».
#
# Что убирает:
#   - остановленные контейнеры старше недели и образы, которыми не занят ни один
#     контейнер (скачиваются заново, если понадобятся);
#   - кэши пакетов bun / pip / npm / apt;
#   - временные файлы в /tmp старше недели (сокеты tmux, systemd и Claude не трогает);
#   - логи *.log больше 100 МБ в доме агента — обрезает до последних 20 МБ, не удаляет;
#   - системный журнал — до 500 МБ.
# Не трогает: память, рабочую папку агента, резервные копии, живые контейнеры.
#
# Итог — одна строка в журнал уборки; её читает советник (agent-advisor.sh)
# и шлёт хозяину. Установщик кладёт root-копию в /usr/local/bin/dashi-cleanup-<агент>:
# root-крон не должен исполнять файл, который может переписать агент.
#
#   disk-cleanup.sh <service_user> [--dry-run]
# Для тестов: CLEANUP_HOME, CLEANUP_TMP, CLEANUP_LOG, CLEANUP_NO_SYSTEM=1
# (без docker / apt / npm / journalctl).
set -uo pipefail

SERVICE_USER="${1:?usage: disk-cleanup.sh <service_user> [--dry-run]}"
DRY=0; [[ "${2:-}" == --dry-run ]] && DRY=1
HOME_DIR="${CLEANUP_HOME:-/home/$SERVICE_USER}"
TMP_DIR="${CLEANUP_TMP:-/tmp}"
LOG="${CLEANUP_LOG:-/var/log/dashi-cleanup.log}"
NO_SYSTEM="${CLEANUP_NO_SYSTEM:-0}"
TMP_AGE_DAYS=7
BIG_LOG="+100M"
KEEP_LOG_BYTES="20M"

done_=()
run() { if (( DRY )); then echo "would: $*"; else "$@"; fi; }
used_kb() { df --output=used -k "$HOME_DIR" | tail -1 | tr -dc '0-9'; }

before=$(used_kb)

# Контейнеры: только остановленные больше недели назад, и никогда — память
# (openviking): её остановка на время ребута не повод её сносить, а без
# контейнера следующим шагом ушёл бы и её образ. Образы удаляем только те,
# которыми не занят ни один контейнер, в том числе остановленный.
if (( ! NO_SYSTEM )) && command -v docker >/dev/null 2>&1; then
  week_ago=$(( $(date +%s) - 7 * 86400 )); n_ct=0
  while read -r id name img; do
    [[ -z "$id" || "$name $img" == *openviking* ]] && continue
    fin="$(docker inspect -f '{{.State.FinishedAt}}' "$id" 2>/dev/null)"
    fin_s="$(date -d "$fin" +%s 2>/dev/null || echo "$(date +%s)")"
    (( fin_s < week_ago )) && run docker rm "$id" >/dev/null 2>&1 && n_ct=$((n_ct + 1))
  done < <(docker ps -a --filter status=exited --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null)
  (( n_ct )) && done_+=("контейнеры:$n_ct")
  run docker image prune -af >/dev/null 2>&1 && done_+=(образы)
fi

# Всё внутри дома агента — от имени агента: root, идущий по путям, которые агент
# может подменить ссылкой, перезаписал бы чужой файл (обрезка лога через cat >).
as_agent() { if (( NO_SYSTEM )); then "$@"; else runuser -u "$SERVICE_USER" -- "$@"; fi; }

for c in "$HOME_DIR/.bun/install/cache" "$HOME_DIR/.cache/pip"; do
  [[ -d "$c" && ! -L "$c" ]] && run as_agent rm -rf "$c" && done_+=("кэш:${c##*/.}")
done
if (( ! NO_SYSTEM )); then
  command -v npm >/dev/null 2>&1 \
    && run runuser -u "$SERVICE_USER" -- npm cache clean --force >/dev/null 2>&1 && done_+=(кэш:npm)
  run apt-get clean >/dev/null 2>&1 || true
fi

# /tmp: верхний уровень старше недели, кроме живых сокетов и песочниц Claude;
# внутри песочниц Claude — только папки старых сессий.
n_tmp=0
while IFS= read -r -d '' p; do
  run rm -rf "$p" && n_tmp=$((n_tmp + 1))
done < <(find "$TMP_DIR" -xdev -mindepth 1 -maxdepth 1 -mtime +"$TMP_AGE_DAYS" \
           ! -name 'tmux-*' ! -name 'systemd-private-*' ! -name 'claude-*' ! -name '.*' \
           -print0 2>/dev/null)
while IFS= read -r -d '' p; do
  run rm -rf "$p" && n_tmp=$((n_tmp + 1))
done < <(find "$TMP_DIR" -xdev -mindepth 2 -maxdepth 2 -path "$TMP_DIR/claude-*" \
           -type d -mtime +"$TMP_AGE_DAYS" -print0 2>/dev/null)
(( n_tmp )) && done_+=("tmp:$n_tmp")

# Большие логи обрезаем на месте (cat >, а не mv): владелец и открытые
# дескрипторы пишущего процесса остаются.
while IFS= read -r -d '' f; do
  if (( DRY )); then echo "would trim: $f"; else
    as_agent bash -c 'tail -c "$1" "$2" > "$2.cleanup-tmp" && cat "$2.cleanup-tmp" > "$2"; rm -f "$2.cleanup-tmp"' \
      _ "$KEEP_LOG_BYTES" "$f"
  fi
  done_+=("лог:${f##*/}")
done < <(find "$HOME_DIR" -xdev -type f -name '*.log' -size "$BIG_LOG" -print0 2>/dev/null)

(( NO_SYSTEM )) || run journalctl --vacuum-size=500M >/dev/null 2>&1 || true

freed_mb=$(( (before - $(used_kb)) / 1024 ))
(( freed_mb < 0 )) && freed_mb=0
pct=$(df --output=pcent "$HOME_DIR" | tail -1 | tr -dc '0-9')
line="$(date +%F) freed_mb=$freed_mb disk=${pct}% ${done_[*]:-}"
if (( ! DRY )); then
  echo "$line" >> "$LOG"
  chmod 644 "$LOG" 2>/dev/null || true
fi
echo "$line"
