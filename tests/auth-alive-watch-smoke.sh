#!/usr/bin/env bash
# Smoke: auth-alive-watch.sh -- spent quota stays quiet, real auth failure flips to fail.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
WS="$T/ws"; mkdir -p "$WS/logs" "$WS/data" "$WS/bin"
FAKE="$T/claude"
run() {  # $1 = fake output, $2 = fake exit code
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "$1" "$2" > "$FAKE"; chmod +x "$FAKE"
  CLAUDE_BIN="$FAKE" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test bash "$ROOT/agent-kit/bin/auth-alive-watch.sh" "$WS"
}
st() { cat "$WS/data/auth-alive.state" 2>/dev/null; }
fail() { echo "✗ $*"; exit 1; }

run "пинг" 0;                                                   [ "$(st)" = ok ] || fail "успех -> ok"
run "You've hit your session limit · resets 3:40pm" 1;          [ "$(st)" = ok ] || fail "лимит не должен ставить fail"
grep -q "лимит подписки" "$WS/logs/auth-alive-watch.log"        || fail "лимит не залогирован"
run "API Error: 401 Invalid bearer token" 1;                    [ "$(st)" = fail ] || fail "401 -> fail"
run "API Error: 429 rate_limit_error" 1;                        [ "$(st)" = fail ] || fail "лимит после fail должен сохранить fail"
run "пинг" 0;                                                   [ "$(st)" = ok ] || fail "восстановление -> ok"
echo "✓ auth-alive-watch smoke ok"
