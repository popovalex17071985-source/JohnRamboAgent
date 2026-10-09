#!/usr/bin/env bash
# Советник по обновлениям: раз в сутки смотрит, вышло ли новое, и САМ пишет
# хозяину, что появилось. Без него агент молчит, пока хозяин не спросит, —
# а он не спросит, потому что не знает, что спрашивать.
#
# Ставится в крон установщиком рядом с утренней сводкой. Дедуп по хешу свежей
# версии: об одном и том же обновлении сообщается один раз.
set -uo pipefail

AGENT="__AGENT__"
WORKSPACE="__WORKSPACE__"
CLAUDE_DIR="__CLAUDE_DIR__"
CHAT_ID="__CHAT_ID__"
CTL="/usr/local/bin/dashi-ctl-$AGENT"
REPO="$CLAUDE_DIR/dashi-plugin-claude-code"
SEEN="$WORKSPACE/state/update-notified"
# Test seams: a stub check command and a stub sender. Unset in production, so
# the check is `sudo -n dashi-ctl check` and the sender is bin/tg-send.py.
CHECK="${DASHI_UPDATE_CHECK:-}"
TG_SEND="${DASHI_TG_SEND:-$WORKSPACE/bin/tg-send.py}"

if [ -z "$CHECK" ]; then [ -x "$CTL" ] || exit 0; fi
run_check() { if [ -n "$CHECK" ]; then "$CHECK"; else sudo -n "$CTL" check; fi; }

# Проверка не прошла -- хозяину об этом раз на серию сбоев, а не молча выйти:
# 05–09.10.2026 у трёх агентов закрыли репо, проверка падала на входе в GitHub,
# а скрипт тихо выходил, и хозяева неделю сидели на старой версии, не зная этого.
FAILED="$WORKSPACE/state/update-check-failed"
ERR="$(mktemp)"
if ! LIST="$(run_check 2>"$ERR")"; then
  WHY="$(grep -v '^[[:space:]]*$' "$ERR" | tail -1 | cut -c1-200)"
  rm -f "$ERR"
  [ -e "$FAILED" ] && exit 0
  mkdir -p "$(dirname "$FAILED")"
  /usr/bin/python3 "$TG_SEND" "Не могу проверить обновления: сервер не достучался до хранилища кода.

Ошибка: ${WHY:-без текста}

Пока это не починят, обновления до агента не дойдут. Перешлите это сообщение тому, кто ставил агента." \
    && : > "$FAILED"
  exit 0
fi
rm -f "$ERR" "$FAILED"

# Простыми словами и по пунктам: план считает планировщик из ТОЙ версии, что
# пришла сверху (FETCH_HEAD), -- заметки «Хозяину:», пропущенные хозяином пункты,
# свои правки. Пишет только когда план изменился. Нет планировщика в свежей
# версии -- старый список заголовков ниже.
PLANNER="scripts/update-plan.py"
plan() {
  git -C "$REPO" show "FETCH_HEAD:$PLANNER" | /usr/bin/python3 - --repo "$REPO" \
    --claude-dir "$CLAUDE_DIR" --workspace "$WORKSPACE" --agent "$AGENT" --chat-id "$CHAT_ID" "$@"
}
if git -C "$REPO" cat-file -e "FETCH_HEAD:$PLANNER" 2>/dev/null && TEXT="$(plan notify)"; then
  [ -n "$TEXT" ] || exit 0
  /usr/bin/python3 "$TG_SEND" "$TEXT" --html && plan notify --sent
  exit 0
fi
[ -n "$LIST" ] || exit 0

# Хеш списка: тот же список — молчим, иначе будем долбить каждый день.
HASH="$(printf '%s' "$LIST" | cksum | cut -d' ' -f1)"
mkdir -p "$(dirname "$SEEN")"
[ "$(cat "$SEEN" 2>/dev/null || true)" = "$HASH" ] && exit 0

# Хозяину -- только то, что меняет ЕГО агента. Слияния PR дублируют свои коммиты,
# а правки Codex-агента (файлы с «codex» в пути) Claude-агенту не нужны: 26.09.2026
# Саня увидел пачку «Codex-агент: …» в чате у агента на Claude.
relevant() {
  git -C "$REPO" rev-parse -q --verify "$1^2" >/dev/null 2>&1 && return 1
  git -C "$REPO" diff-tree --no-commit-id --name-only -r "$1" 2>/dev/null \
    | grep -qiv codex
}
SHOW=""
while read -r sha rest; do
  [ -n "$sha" ] || continue
  relevant "$sha" && SHOW="$SHOW$sha $rest
"
done <<< "$LIST"
if [ -z "$SHOW" ]; then printf '%s' "$HASH" > "$SEEN"; exit 0; fi
LIST="$SHOW"

N="$(printf '%s\n' "$LIST" | grep -c .)"
BODY="$(printf '%s\n' "$LIST" | head -15 | sed 's/^[0-9a-f]* /• /')"

/usr/bin/python3 "$TG_SEND" "Вышло обновление: $N шт.

$BODY

Поставить — напиши /update. Обновление делает копию и при сбое откатывается." \
  && printf '%s' "$HASH" > "$SEEN"
