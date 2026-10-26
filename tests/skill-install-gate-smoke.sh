#!/usr/bin/env bash
# Smoke: agent-kit/hooks/skill-install-gate.sh -- installing into a skills/plugins
# dir without SKILLSPECTOR_OK=1 is denied; reading, listing and copying OUT pass.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-kit/hooks/skill-install-gate.sh"
bash -n "$H" || { echo "✗ синтаксис skill-install-gate.sh"; exit 1; }
fail=0; n=0
check() { # expect(deny|allow) command
  local out got
  out=$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$H") \
    || { echo "✗ хук упал на: $2"; fail=1; return; }
  got=allow; grep -q '"deny"' <<<"$out" && got=deny
  n=$((n + 1))
  if [[ $got != "$1" ]]; then echo "✗ want=$1 got=$got: $2"; fail=1; fi
}
check deny  'git clone https://github.com/x/skill ~/.claude/skills/skill'
check deny  'cp -r /tmp/x/skill /home/agent/.claude-lab/bot/.claude/skills/skill'
check deny  'mv /tmp/x ~/.agents/skills/x'
check deny  'rsync -a /tmp/p/ ~/.claude/plugins/p'
check deny  'tar -xz --strip-components=1 -C ~/.claude/skills/anatomy'
check deny  'unzip -q skill.zip -d ~/.codex/skills/s'
check deny  'claude plugin install foo@bar'
check deny  'claude plugins add foo'
check deny  'npx skills add owner/repo'
check deny  'cd /tmp && git clone https://github.com/x/y ~/.claude/skills/y && ls'
check allow 'SKILLSPECTOR_OK=1 git clone https://github.com/x/skill ~/.claude/skills/skill'
check allow 'cd /tmp && SKILLSPECTOR_OK=1 cp -r /tmp/x ~/.claude/skills/x'
check deny  'git clone https://github.com/x/s ~/.claude/skills/s # SKILLSPECTOR_OK=1 '
check deny  'echo SKILLSPECTOR_OK=1; git clone https://github.com/x/s ~/.claude/skills/s'
check deny  'cp -r /tmp/x ~/.claude/skills/x; echo "SKILLSPECTOR_OK=1 done"'
check deny  $'SKILLSPECTOR_OK=1 \ngit clone https://github.com/x/s ~/.claude/skills/s'
check deny  'SKILLSPECTOR_OK=1 ; git clone https://github.com/x/s ~/.claude/skills/s'
check allow 'cp -r .claude/skills/old-skill attic/backup/'
check allow 'ls ~/.claude/skills'
check allow 'grep -rn foo .claude/skills/'
check allow 'git clone https://github.com/x/y /tmp/y'
check allow 'skillspector scan /tmp/y --no-llm --format json --output /tmp/y.json'
check allow ''
out=$(printf 'not json' | bash "$H"); rc=$?
[[ $rc == 0 && -z "$out" ]] || { echo "✗ битый вход: код $rc, вывод «$out»"; fail=1; }
# The deny reason must name the scanner and the escape, or the agent is stuck.
r=$(jq -n '{tool_input:{command:"claude plugin install foo"}}' | bash "$H" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
grep -q 'skillspector scan' <<<"$r" && grep -q 'SKILLSPECTOR_OK=1' <<<"$r" \
  || { echo "✗ в отказе нет ни сканера, ни выхода: $r"; fail=1; }
if [[ $fail == 0 ]]; then echo "✓ skill-install-gate smoke ok ($n случаев)"; fi
exit $fail
