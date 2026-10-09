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
CTL="/usr/local/bin/dashi-ctl-$AGENT"
REPO="__CLAUDE_DIR__/dashi-plugin-claude-code"
SEEN="$WORKSPACE/state/update-notified"

[ -x "$CTL" ] || exit 0

# Проверка не прошла -- хозяину об этом раз на серию сбоев, а не молча выйти:
# 05–09.10.2026 у трёх агентов закрыли репо, проверка падала на входе в GitHub,
# а скрипт тихо выходил, и хозяева неделю сидели на старой версии, не зная этого.
FAILED="$WORKSPACE/state/update-check-failed"
ERR="$(mktemp)"
if ! LIST="$(sudo -n "$CTL" check 2>"$ERR")"; then
  WHY="$(grep -v '^[[:space:]]*$' "$ERR" | tail -1 | cut -c1-200)"
  rm -f "$ERR"
  [ -e "$FAILED" ] && exit 0
  mkdir -p "$(dirname "$FAILED")"
  /usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "Не могу проверить обновления: сервер не достучался до хранилища кода.

Ошибка: ${WHY:-без текста}

Пока это не починят, обновления до агента не дойдут. Перешлите это сообщение тому, кто ставил агента." \
    && : > "$FAILED"
  exit 0
fi
rm -f "$ERR" "$FAILED"
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

/usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "Вышло обновление: $N шт.

$BODY

Поставить — напиши /update. Обновление делает копию и при сбое откатывается." \
  && printf '%s' "$HASH" > "$SEEN"
