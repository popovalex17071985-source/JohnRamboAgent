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

# Account put on Anthropic verification (Lena's «Жупик», 31.10.2026): not a dead
# login -- state verify, one honest message, no org URL anywhere.
printf 'import sys\nopen("%s", "a").write(sys.argv[1].replace("\\n", " ") + "\\n")\n' "$T/sent" \
  > "$WS/bin/tg-send.py"
sent() { [ -f "$T/sent" ] && wc -l < "$T/sent" || echo 0; }
: > "$T/sent"
VERIFY="API Error: Your account can't receive replies from Claude right now. You can find the next step in the Anthropic Verification Portal: https://portal.anthropic.com/verify?org=abc123secret"
run "$VERIFY" 1;                                                [ "$(st)" = verify ] || fail "проверка аккаунта -> verify"
[ "$(sent)" -eq 1 ]                                             || fail "проверка: ровно одно сообщение (было $(sent))"
grep -q "на проверку" "$T/sent"                                 || fail "сообщение не про проверку"
grep -q "повторный вход" "$T/sent"                              && fail "проверка выдана за протухший вход"
grep -q "аккаунт на проверке Anthropic" "$WS/logs/auth-alive-watch.log" || fail "проверка не залогирована"
grep -q "abc123secret" "$T/sent" "$WS/logs/auth-alive-watch.log" && fail "org из ссылки утёк"
run "$VERIFY" 1;                                                [ "$(st)" = verify ] || fail "повтор проверки -> verify"
[ "$(sent)" -eq 1 ]                                             || fail "повтор проверки не должен слать второе ($(sent))"
run "пинг" 0;                                                   [ "$(st)" = ok ] || fail "после проверки -> ok"
[ "$(sent)" -eq 2 ] && grep -q "снова работает" "$T/sent"       || fail "после проверки нет сообщения о восстановлении"

# Generic failure: short, sanitized reason in the log -- no token, no query string.
run "API Error: 401 Invalid bearer token sk-ant-oat01-SECRETVALUE123 see https://x.example/a?key=QUERYSECRET" 1
[ "$(st)" = fail ]                                              || fail "401 -> fail"
line="$(grep "пробный вызов не прошёл" "$WS/logs/auth-alive-watch.log" | tail -1)"
grep -q "401 Invalid bearer" <<<"$line"                         || fail "причина не залогирована: $line"
grep -qE "SECRETVALUE|QUERYSECRET" <<<"$line"                   && fail "секрет в логе: $line"
reason="${line#*пробный вызов не прошёл: }"
[ "${#reason}" -le 120 ]                                        || fail "причина длиннее 120 (${#reason})"
echo "✓ auth-alive-watch smoke ok"
