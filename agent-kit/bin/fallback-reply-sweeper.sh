#!/usr/bin/env bash
# fallback-reply-sweeper.sh -- catch answers the Stop hook dropped.
#
# The Stop hook reads the turn from the transcript. On a long-lived session the
# final text is sometimes not flushed yet when the hook runs (gorbot 19.09.2026:
# a 30 MB transcript, three answers composed and never delivered; the SAME hook
# re-run by hand a minute later delivered them). Re-running it later is safe:
# the hook's own dedup state means an already-delivered turn is skipped, and a
# turn that ended with an explicit reply call is skipped too.
#
# Usage: fallback-reply-sweeper.sh <workspace> <agent>
set -euo pipefail

WORKSPACE="${1:?нужен каталог агента}"
AGENT="${2:?нужно имя агента}"
# Installed agents keep channel secrets in /etc; the coordinator keeps its own
# under the workspace. Accept both so one sweeper serves every layout.
ENV_FILE="/etc/dashi-plugin/$AGENT/channel.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$WORKSPACE/secrets/channel.env"
HOOK="$WORKSPACE/.claude/dashi-plugin-claude-code/plugin/scripts/fallback-reply-hook.ts"
[ -f "$HOOK" ] || HOOK="$HOME/.claude/dashi-plugin-claude-code/plugin/scripts/fallback-reply-hook.ts"
PROJECTS="$HOME/.claude/projects"

[ -f "$ENV_FILE" ] && [ -f "$HOOK" ] || exit 0
command -v bun >/dev/null 2>&1 || exit 0

# The live session is the most recently written transcript, and only while it is
# fresh: an abandoned session must not be re-delivered hours later.
# Only the agent's own sessions (started inside its workspace). Background
# `claude -p` probes run from /tmp and write transcripts too: 27.09.2026 the
# 6-hourly login probe (auth-alive-watch.sh, «ответь одним словом: пинг») was the
# freshest transcript, and the sweeper forwarded its «Понг» to the owner, twice.
# Claude names a project dir after the cwd with every '/' and '.' turned into '-'.
OWN_PREFIX="$(printf '%s' "$WORKSPACE" | tr '/.' '--')"
TRANSCRIPT="$(find "$PROJECTS" -path "$PROJECTS/$OWN_PREFIX*" -name '*.jsonl' -mmin -5 \
  -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "$TRANSCRIPT" ] || exit 0

SESSION_ID="$(basename "$TRANSCRIPT" .jsonl)"
printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}\n' \
  "$SESSION_ID" "$TRANSCRIPT" \
  | TELEGRAM_CHANNEL_ENV_FILE="$ENV_FILE" bun "$HOOK" 2>&1 | tail -3
