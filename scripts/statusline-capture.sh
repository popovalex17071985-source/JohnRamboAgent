#!/usr/bin/env bash
# Claude Code statusLine command that also feeds the pinned Telegram HUD.
#
# Claude Code pipes a JSON document (context window, 5h/7d rate limits, model,
# cost) into the statusLine command. This keeps a copy for the HUD
# (src/status/statusline-snapshot.ts) and then renders a status line:
#   - DASHI_STATUSLINE_NEXT set -> pipe the JSON to that command (e.g. ccusage);
#   - otherwise print a short «model · ctx N%» line.
# settings.json:  "statusLine": {"type": "command", "refreshInterval": 30,
#                  "command": "<plugin>/scripts/statusline-capture.sh"}
set -euo pipefail
OUT="${JARVIS_STATUSLINE_FILE:-$HOME/.claude/dashi-statusline.json}"
payload="$(cat)"
# Claude Code compacts at CLAUDE_CODE_AUTO_COMPACT_WINDOW (settings.json env), not at
# the model's full window; stamp it in so the HUD bar fills up to the real limit.
if [[ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" =~ ^[0-9]+$ ]]; then
  payload="$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["dashi_autocompact_window"] = int(sys.argv[1])
print(json.dumps(d))' "$CLAUDE_CODE_AUTO_COMPACT_WINDOW")"
fi
mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp "$OUT.XXXXXX")"
printf '%s' "$payload" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$OUT"
if [[ -n "${DASHI_STATUSLINE_NEXT:-}" ]]; then
  printf '%s' "$payload" | bash -c "$DASHI_STATUSLINE_NEXT"
else
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = (d.get("model") or {}).get("display_name") or "?"
p = (d.get("context_window") or {}).get("used_percentage")
print(f"{m} · ctx {p}%" if p is not None else m)'
fi
