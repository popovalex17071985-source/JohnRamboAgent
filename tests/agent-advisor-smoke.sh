#!/usr/bin/env bash
# Смоук советника: на подставном workspace он обязан заметить переросшую память
# и заросший тёплый слой, на чистом — промолчать. Молчание там, где надо орать,
# и наоборот — единственный способ сломать предохранитель незаметно.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-advisor.sh"
fail() { echo "✗ $1" >&2; exit 1; }

bash -n "$S" || fail "синтаксис"

make_ws() {  # make_ws <фактов> <строк в decisions>
  local w e
  w="$(mktemp -d)"; e="$(mktemp)"
  mkdir -p "$w/memory" "$w/core/warm" "$w/core/hot"
  printf 'x' > "$w/CLAUDE.md"
  for ((i = 0; i < $1; i++)); do printf 'f' > "$w/memory/f$i.md"; done
  [[ $2 -gt 0 ]] && seq 1 "$2" > "$w/core/warm/decisions.md"
  printf 'TELEGRAM_BOT_TOKEN=1:AA\nTELEGRAM_ALLOWED_USER_IDS=42\nTELEGRAM_WORKSPACE_ROOT=%s\n' "$w" > "$e"
  echo "$e"
}

loud="$(DASHI_ENV_FILE="$(make_ws 160 500)" bash "$S" --dry-run)"
grep -q "memory-semantic" <<<"$loud" || fail "не заметил, что память переросла индекс"
grep -q "warm-bloat"      <<<"$loud" || fail "не заметил разросшийся тёплый слой"

quiet="$(DASHI_ENV_FILE="$(make_ws 3 10)" bash "$S" --dry-run)"
grep -q "memory-semantic" <<<"$quiet" && fail "орёт на здоровом агенте"

clog="$(mktemp)"
echo "$(date +%F) freed_mb=3000 disk=48% образы кэш:bun" > "$clog"
cl="$(DASHI_CLEANUP_LOG="$clog" DASHI_ENV_FILE="$(make_ws 3 10)" bash "$S" --dry-run)"
grep -q "освобождено 3000 МБ" <<<"$cl" || fail "не сообщил итог уборки диска"
echo "$(date +%F) freed_mb=12 disk=48%" > "$clog"
cl="$(DASHI_CLEANUP_LOG="$clog" DASHI_ENV_FILE="$(make_ws 3 10)" bash "$S" --dry-run)"
grep -q "Уборка диска" <<<"$cl" && fail "шумит про уборку, освободившую копейки"

# Протух ключ к закрытому репозиторию -- хозяин узнаёт, обновления не встают молча.
# git-шим: fetch отвечает как GitHub без ключа, остальное -- настоящий git.
env_r="$(make_ws 3 10)"; ws_r="$(sed -n 's/^TELEGRAM_WORKSPACE_ROOT=//p' "$env_r")"
git init -q "$ws_r/dashi-plugin-claude-code"
shim="$(mktemp -d)"; real_git="$(command -v git)"
printf '#!/usr/bin/env bash\nfor a; do [[ $a == fetch ]] && { echo "fatal: could not read Username for https://github.com: terminal prompts disabled" >&2; exit 128; }; done\nexec %q "$@"\n' "$real_git" > "$shim/git"
chmod +x "$shim/git"
ra="$(PATH="$shim:$PATH" DASHI_ENV_FILE="$env_r" bash "$S" --dry-run)"
grep -q "repo-access-" <<<"$ra" || fail "не предупредил, что ключ к репозиторию перестал работать"
grep -q "plugin-update-" <<<"$ra" && fail "после неудачного fetch всё равно ищет обновления"

echo "✓ agent-advisor smoke ok"
