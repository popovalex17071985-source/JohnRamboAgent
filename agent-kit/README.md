# agent-kit — the discipline layer

`install-agent.sh` produces an agent that runs, talks to its owner and remembers.
This kit gives it the WAY OF WORKING that Jarvis grew over months of operator
corrections — so a fresh agent starts where the old one ended up, not at zero.

Laid down by `install-kit.sh` (called automatically from `install-agent.sh`, step 7b):

| What | Where it lands | Class of mistake it closes |
|---|---|---|
| Constitution | `core/constitution.md` (@include'd) | answering off a proxy; refusing before trying; going silent after finishing; treating an imperative as a question |
| `block-dangerous.sh` | PreToolUse Bash | recursive deletes and destructive SQL run without a confirm |
| `block-red-zone.sh` | PreToolUse Write/Edit | writing secrets to disk (`.env`, `*.key`, `*.pem`, `.ssh/`, any `secrets/`); silent edits to the constitution. One deliberate exception: plain files directly inside the agent's OWN `<workspace>/secrets/` are allowed — storing a key the owner hands over is the agent's job (the installer's CLAUDE.md template says so); nested paths, `..`, and secret-shaped names inside it stay blocked |
| `block-selfmatching-pgrep.sh` | PreToolUse Bash | a `pgrep -f` waiter that matches its own command line and hangs forever |
| `truncate-bash-output.sh` | PostToolUse Bash | a huge log dumped into context, burning cache every turn after |
| `lesson-needs-mechanism.sh` | PostToolUse Edit/Write | a lesson filed as a diary line and repeated the next week |
| `cyrillic-guard.sh` | PostToolUse Edit/Write | non-English prose in files that reload every session — 2-3x the tokens |
| `capture-open-threads.py` | Stop | "I'll come back with…" that never reaches the ledger |
| `stop-closeout-gate.py` | Stop | work finished in the terminal and never reported to the owner |
| `stop-blocker-gate.py` | Stop | handing the task back ("no access", "waiting on you") without an enumeration |
| `bin/bg.sh` | wrapper | a long run whose failure is never reported — silence read as success |
| `bin/promise-sweeper.py` | cron, morning | a dated promise sitting in the ledger with nothing to wake the agent |
| `bin/open-threads-digest.py` | cron, morning | the owner not seeing what is open — one message per section, numbered, chunked under the Telegram limit |
| `bin/tg-send.py` | helper | cron and hooks having no way to reach the owner without the plugin runtime |
| `bin/api-fail-watch.py` | cron, every 30 min | an external API answering 401/403 or empty 3+ times in a row with nobody told — one alert per source per day |
| `bin/stack-updates-check.py` | cron, Monday morning | not knowing Claude Code, bun, the bridge or memory fell behind — report-only, never updates |
| `bin/whatruns.py` | on demand | calling a subsystem alive or dead from a proxy instead of its cron lines, units (system and `--user`) and log freshness |
| `core/SOURCES.md` | registry | not knowing a primary source exists, so a cache becomes the verdict |
| `core/open-threads.md` | ledger | the single board: promises, projects, next steps |
| `agents/{proxy-skeptic,reviewer,parser}.md` | subagents | shipping a number or a diagnosis with no independent check |
| `docs/agent-self-audit.md` | task | the audit the agent runs on itself to find what is still missing |

**What it never touches:** `core/rules.md` — the owner's own log of corrections.
The kit writes the constitution beside it, not over it. An existing `SOURCES.md`
or `open-threads.md` is left alone too.

**Standalone use:**

```
./install-kit.sh --claude-dir ~/.claude-lab/<agent>/.claude \
                 --chat-id <telegram id> --agent <name> \
                 [--settings ~/.claude/settings.json] [--tz Asia/Yekaterinburg]
```

Idempotent: re-running refreshes the files and never double-registers a hook.

**Re-run behaviour:**

- **`.kit-backup/`** — a kit file that already exists on the agent AND differs
  from the fresh render (a hook, a `bin/` script, a subagent, the constitution,
  the self-audit task) is copied to `<workspace>/.kit-backup/<YYYYMMDD-HHMM>/<same
  relative path>` before it is overwritten, and the run prints «сохранил N старых
  файлов в …». Local tweaks on a living agent are no longer lost silently; diff
  against the backup and re-apply what matters. Registries the agent writes into
  (`core/SOURCES.md`, `core/open-threads.md`) and `core/rules.md` are never
  overwritten at all.
- **`--tz`** — the owner's timezone. The morning digest and the promise sweeper
  are cron lines computed for 09:00 in that zone (server clock may differ);
  without the flag the server's `timedatectl` zone is used (UTC if unknown).
  Re-running with a different `--tz` rewrites the kit's own two cron lines to the
  new hour instead of reporting «already in cron». Only lines pointing at this
  workspace are touched — a second agent under the same user keeps its own.
- Hooks are matched by command path, so a re-run never registers one twice.

Linux is the tested target (`install-agent.sh` calls the kit from step 7b). On
macOS the kit itself has no hard Linux dependency beyond `timedatectl` (pass
`--tz`) and `/usr/bin/python3`, but it has not been exercised there — see
`docs/03-installation-macos.md`.
