#!/usr/bin/env bash
# Смоук страховки ответов: пересылать можно только сессию самого агента.
# 27.09.2026 свежей оказалась сессия фоновой проверки входа (запуск из /tmp),
# и хозяину дважды пришло «Понг».
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/agent-kit/bin/fallback-reply-sweeper.sh"
fail() { echo "✗ $1" >&2; exit 1; }
bash -n "$S" || fail "синтаксис"

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
export HOME="$box/home"
WS="$HOME/.claude-lab/bot"
mkdir -p "$WS/secrets" "$WS/.claude/dashi-plugin-claude-code/plugin/scripts" "$box/bin"
touch "$WS/secrets/channel.env" "$WS/.claude/dashi-plugin-claude-code/plugin/scripts/fallback-reply-hook.ts"
# bun-заглушка: печатает, какую сессию ей отдали на пересылку
printf '#!/usr/bin/env bash\ncat\n' > "$box/bin/bun"; chmod +x "$box/bin/bun"
export PATH="$box/bin:$PATH"

P="$HOME/.claude/projects"
own="$P/$(printf '%s' "$WS/.claude/dashi-plugin-claude-code/plugin" | tr '/.' '--')"
mkdir -p "$own" "$P/-tmp"
echo '{}' > "$own/live.jsonl"
sleep 1
echo '{}' > "$P/-tmp/probe.jsonl"          # свежее, но чужое

out="$(bash "$S" "$WS" bot)"
grep -q "live.jsonl" <<<"$out"  || fail "не взял сессию агента"
grep -q "probe.jsonl" <<<"$out" && fail "переслал фоновую проверку из /tmp"

rm "$own/live.jsonl"
out="$(bash "$S" "$WS" bot)"
[[ -z "$out" ]] || fail "без сессии агента что-то переслал: $out"

echo "✓ fallback-sweeper smoke ok"
