#!/usr/bin/env bash
# Smoke: install-kit.sh --keep -- listed targets are left exactly as they are,
# everything else is rendered as before. /update uses it to keep the owner's own
# tweaks and the items he chose not to install.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
CD="$T/ws/.claude"; WS="$T/ws"
mkdir -p "$CD/hooks" "$WS/bin"
fail() { echo "✗ $*"; exit 1; }

# Owner's tweaks in two installed files; only the first one is asked to be kept.
printf 'owner tweak\n' > "$CD/hooks/tz-guard.sh"
printf 'owner tweak\n' > "$WS/bin/tg-send.py"

KIT_NO_CRON=1 KIT_NO_MEMORY=1 KIT_NO_SKILLSPECTOR=1 bash "$ROOT/agent-kit/install-kit.sh" \
  --claude-dir "$CD" --chat-id 42 --agent smoke --settings "$T/settings.json" --tz UTC \
  --keep "$CD/hooks/tz-guard.sh,$CD/agents/reviewer.md" > "$T/out.log" 2>&1 \
  || { cat "$T/out.log"; fail "install-kit --keep упал"; }

[ "$(cat "$CD/hooks/tz-guard.sh")" = "owner tweak" ] || fail "--keep: хук перезаписан"
[ ! -e "$CD/agents/reviewer.md" ] || fail "--keep: отсутствующий файл всё равно разложен"
grep -q "owner tweak" "$WS/bin/tg-send.py" && fail "не из --keep: правка должна перезаписаться"
grep -q '"smoke"\|/smoke/' "$WS/bin/tg-send.py" || fail "плейсхолдер __AGENT__ не подставлен"
[ -f "$CD/hooks/block-dangerous.sh" ] || fail "остальные хуки не разложены"
[ -f "$CD/agents/parser.md" ] || fail "остальные помощники не разложены"
ls "$WS/.kit-backup"/*/bin/tg-send.py >/dev/null 2>&1 || fail "бэкап перезаписанной правки не сделан"
echo "✓ install-kit --keep smoke ok"
