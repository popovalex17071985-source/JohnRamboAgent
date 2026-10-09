#!/usr/bin/env bash
# Smoke: update-notify.sh failure path -- one message per failure streak, a
# successful check clears the marker, the next failure is reported again.
# The check and the sender are stubbed through env seams (DASHI_UPDATE_CHECK,
# DASHI_TG_SEND); without them the script uses sudo dashi-ctl and bin/tg-send.py.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
WS="$T/ws"; CD="$WS/.claude"; mkdir -p "$WS/state" "$CD"
fail() { echo "✗ $*"; exit 1; }

sed -e "s|__CLAUDE_DIR__|$CD|g" -e "s|__WORKSPACE__|$WS|g" \
    -e "s|__CHAT_ID__|42|g" -e "s|__AGENT__|smoke|g" \
    "$ROOT/agent-kit/bin/update-notify.sh" > "$T/update-notify.sh"

SENT="$T/sent.log"
cat > "$T/tg-send.py" <<PY
import sys
with open("$SENT", "a") as f:
    f.write(sys.argv[1].replace("\n", " ") + "\n")
PY
CHECK="$T/check.sh"
check_fails() { printf '#!/bin/sh\necho "fatal: Could not read from remote repository." >&2\nexit 128\n' > "$CHECK"; chmod +x "$CHECK"; }
check_ok()    { printf '#!/bin/sh\nexit 0\n' > "$CHECK"; chmod +x "$CHECK"; }
run() { DASHI_UPDATE_CHECK="$CHECK" DASHI_TG_SEND="$T/tg-send.py" bash "$T/update-notify.sh"; }
sent() { [ -f "$SENT" ] && grep -c . "$SENT" || echo 0; }

check_fails; run
[ "$(sent)" = 1 ] || fail "первый сбой: ждали 1 сообщение, есть $(sent)"
grep -q "Could not read from remote" "$SENT" || fail "в сообщении нет текста ошибки"
[ -e "$WS/state/update-check-failed" ] || fail "метка сбоя не поставлена"
run
[ "$(sent)" = 1 ] || fail "повторный сбой той же серии не должен слать ещё раз"
check_ok; run
[ ! -e "$WS/state/update-check-failed" ] || fail "успешная проверка не сняла метку"
[ "$(sent)" = 1 ] || fail "успешная пустая проверка ничего не шлёт"
check_fails; run
[ "$(sent)" = 2 ] || fail "новая серия сбоев: ждали 2 сообщения, есть $(sent)"
echo "✓ update-notify failure-path smoke ok"
