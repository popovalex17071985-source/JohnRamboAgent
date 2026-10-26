#!/usr/bin/env bash
# Installing a third-party skill/plugin = running someone else's instructions with
# my permissions. The coordinator's first scan (25.10.2026) found 8 installed skills
# phoning home and one piping an installer straight into bash.
# Gate: a Bash command that drops files into a skills/plugins dir is refused unless
# it carries SKILLSPECTOR_OK=1 -- i.e. `skillspector scan <src> --no-llm` was run,
# the HIGH/CRITICAL snippets were read by hand and nothing real was found.
set -euo pipefail

cmd=$(jq -r '.tool_input.command // ""')

grep -q 'SKILLSPECTOR_OK=1' <<<"$cmd" && exit 0

dest='[^ ;&|]*\.(claude|agents|codex)/(skills|plugins)\b[^ ;&|]*'
hit=0
# git clone <url> <skills-dir>
grep -qE "\bgit\s+clone\b.*\s${dest}" <<<"$cmd" && hit=1
# cp/mv/rsync/ln whose LAST argument is a skills dir (copying OUT of it is fine)
grep -qE "\b(cp|mv|rsync|ln)\b[^;&|]*\s${dest}\s*($|;|&&|\|\|)" <<<"$cmd" && hit=1
# tar/unzip extracting into a skills dir
grep -qE "\b(tar|unzip)\b[^;&|]*(-C|-d)\s*${dest}" <<<"$cmd" && hit=1
# plugin / skill managers
grep -qE "\bclaude\s+plugins?\s+(install|add)\b|\bnpx\s+[^ ]*skills?\s+(add|install)\b" <<<"$cmd" && hit=1

if [[ $hit == 1 ]]; then
  jq -n --arg r "Установка навыка/плагина без проверки. Сначала: skillspector scan <источник> --no-llm --format json --output <файл> (нет в PATH -- ~/.local/bin/skillspector). HIGH/CRITICAL сниппеты прочитай сам (большинство ложные), реальное -- хозяину. Чисто -- повтори команду с префиксом SKILLSPECTOR_OK=1. Если строка составная, не выполнилась ни одна её часть." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
