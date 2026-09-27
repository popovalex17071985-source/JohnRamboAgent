#!/usr/bin/env bash
# Смоук уборки диска: мусор уходит, живое остаётся. Ошибка в любую сторону —
# либо диск снова зарастает, либо уборка сносит то, чем агент пользуется.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/scripts/disk-cleanup.sh"
fail() { echo "✗ $1" >&2; exit 1; }
bash -n "$S" || fail "синтаксис"

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
H="$box/home"; T="$box/tmp"; L="$box/cleanup.log"
mkdir -p "$H/.bun/install/cache/pkg" "$H/.cache/pip/x" "$H/work" "$T"
echo keep > "$H/work/memory.md"
truncate -s 101M "$H/work/big.log"
echo tail-marker >> "$H/work/big.log"
echo small > "$H/work/small.log"
old() { touch -d '10 days ago' "$@"; }
mkdir -p "$T/old-junk" "$T/fresh" "$T/tmux-1000" "$T/claude-1000/old-session" "$T/claude-1000/live"
old "$T/old-junk" "$T/tmux-1000" "$T/claude-1000/old-session" "$T/claude-1000"

export CLEANUP_HOME="$H" CLEANUP_TMP="$T" CLEANUP_LOG="$L" CLEANUP_NO_SYSTEM=1

# dry-run ничего не трогает
bash "$S" agent --dry-run >/dev/null
[[ -d "$H/.bun/install/cache" && -d "$T/old-junk" ]] || fail "dry-run удалил файлы"
[[ ! -f "$L" ]] || fail "dry-run записал журнал"

out="$(bash "$S" agent)"
[[ ! -e "$H/.bun/install/cache" ]] || fail "не убрал кэш bun"
[[ ! -e "$H/.cache/pip" ]]         || fail "не убрал кэш pip"
[[ ! -e "$T/old-junk" ]]           || fail "не убрал старый мусор в tmp"
[[ ! -e "$T/claude-1000/old-session" ]] || fail "не убрал старую сессию Claude"
[[ -d "$T/fresh" ]]                || fail "снёс свежий tmp"
[[ -d "$T/tmux-1000" ]]            || fail "снёс сокет tmux"
[[ -d "$T/claude-1000/live" ]]     || fail "снёс живую сессию Claude"
[[ "$(cat "$H/work/memory.md")" == keep ]] || fail "тронул рабочие файлы"
[[ "$(cat "$H/work/small.log")" == small ]] || fail "тронул маленький лог"
sz=$(stat -c %s "$H/work/big.log")
(( sz <= 21 * 1024 * 1024 )) || fail "не обрезал большой лог ($sz)"
tail -1 "$H/work/big.log" | grep -q tail-marker || fail "обрезал не с того конца"
grep -q "freed_mb=" "$L"           || fail "нет строки в журнале уборки"
grep -q "лог:big.log" <<<"$out"    || fail "итог не называет обрезанный лог"

echo "✓ disk-cleanup smoke ok"
