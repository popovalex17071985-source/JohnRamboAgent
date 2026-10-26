#!/usr/bin/env bash
# Installing a third-party skill/plugin = running someone else's instructions with
# my permissions. The coordinator's first scan (25.10.2026) found 8 installed skills
# phoning home and one piping an installer straight into bash.
# Gate: a Bash command that drops files into a skills/plugins dir is refused unless
# it carries SKILLSPECTOR_OK=1 -- i.e. `skillspector scan <src> --no-llm` was run,
# the HIGH/CRITICAL snippets were read by hand and nothing real was found.
set -euo pipefail

# Broken input = no verdict (exit 0), never a failed hook on every Bash call.
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)

dest='[^ ;&|]*\.(claude|agents|codex)/(skills|plugins)\b[^ ;&|]*'

# Does one command segment drop files into a skills/plugins dir?
is_install() {
  # git [-C dir ...] clone <url> <skills-dir>
  grep -qE "\bgit\b.*\sclone\b.*\s${dest}" <<<"$1" && return 0
  # cp/mv/rsync/ln whose LAST argument is a skills dir (copying OUT of it is fine)
  grep -qE "\b(cp|mv|rsync|ln)\b.*\s${dest}\s*\)?\s*$" <<<"$1" && return 0
  # tar/unzip extracting into a skills dir
  grep -qE "\b(tar|unzip)\b.*(-C|-d)\s*${dest}" <<<"$1" && return 0
  # plugin / skill managers
  grep -qE "\bclaude\s+plugins?\s+(install|add)\b|\bnpx\s+[^ ]*skills?\s+(add|install)\b" <<<"$1"
}

# Judged per segment (split on ; && || | & and newlines): the escape counts only
# as the env prefix of THAT install -- `SKILLSPECTOR_OK=1 git clone ... skills/x`.
# In a comment, an echo, an argument, alone on its line or in front of another
# command (`SKILLSPECTOR_OK=1 echo x; git clone ...`) it is not the scan done.
hit=0
while IFS= read -r seg; do
  is_install "$seg" || continue
  grep -qE '^[[:space:]]*\(?[[:space:]]*SKILLSPECTOR_OK=1[[:space:]]+[^[:space:]]' <<<"$seg" && continue
  hit=1
done < <(sed -E 's/&&|\|\||[;|&]/\n/g' <<<"$cmd")

if [[ $hit == 1 ]]; then
  jq -n --arg r "Установка навыка/плагина без проверки. Сначала: skillspector scan <источник> --no-llm --format json --output <файл> (нет в PATH -- ~/.local/bin/skillspector). HIGH/CRITICAL сниппеты прочитай сам (большинство ложные), реальное -- хозяину. Чисто -- повтори команду: префикс SKILLSPECTOR_OK=1 перед КАЖДОЙ установкой в строке. Если строка составная, не выполнилась ни одна её часть." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
