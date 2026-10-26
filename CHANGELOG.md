# Changelog

All notable changes to the dashi-channel plugin are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning:
[Semantic Versioning](https://semver.org). The single source of truth for the
current version is `.claude-plugin/plugin.json`; `plugin/package.json` is kept
in lockstep (enforced by `plugin/tests/version-sync.test.ts`), and the MCP
server identity reads `package.json` at runtime. Release process:
`docs/RELEASING.md`.

Versions before 1.0.0 were not tracked — the project shipped ~60 merged PRs
between 2026-05-14 and 2026-06-14 without a version discipline. 1.0.0
retroactively marks the state of `main` on 2026-06-14.

## [Unreleased]

### Added
- **Bridge on-disk log (#100).** Every line of the bridge's logger (including crash
  handlers) is also appended as JSON to `<state_dir>/logs/bridge.jsonl`,
  redacted like stderr, rotated at 5 MB with two old copies kept
  (`bridge.jsonl.1`, `.2`). The MCP host keeps the bridge's stderr only for
  the first moments after start, so lines such as «idle compact attempt /
  sent ok / failed» used to be lost. A write failure is swallowed.
- **Idle auto-compact.** When the owner session's transcript has been untouched
  for `idle_minutes` (default 55) — i.e. the 1-hour prompt cache is about to
  expire — and the context is at least `min_context_tokens` (default 150 000),
  the plugin runs Claude Code's own `/compact` in the pane while the cache is
  still warm (a cheap cache read). The next inbound message then lands on a
  small context instead of re-writing ~300k tokens of cold cache. Checked every
  60 s; never interrupts a busy pane (busy/dialog/unknown → skipped and
  re-checked); at most one attempt per idle period plus a 30-minute cooldown;
  skipped once idle passes 60 min (cache already cold) or right after a compact
  (a newer compact boundary reads as an empty context). Logged only, no
  Telegram messages. Inert without a resolvable tmux pane.
  Config: optional block
  `idle_compact: { enabled: true, idle_minutes: 55, min_context_tokens: 150000 }`
  (`idle_minutes` 5–59, `min_context_tokens` 10 000–10 000 000); a missing block
  means ON with the defaults. Disable with `"idle_compact": { "enabled": false }`.
- **Group `listen_all` (#93).** Optional per-group policy key: the agent takes
  every group message (text, media, albums) without an @-mention or a reply to
  the bot. Who may write is still decided by `allowlist.users` /
  `open_to_members`. Off by default.
- **`/update` with a plain-language choice (#92, #94, #96).** The planner
  explains the update in plain Russian, item by item, with buttons
  «Обновить, своё не трогать» / «Обновить всё, даже своё» / «Не сейчас»; no
  own changes — it installs straight away and says what is new. Owner notes
  come from a `Хозяину:` line in the commit or `update-notes.json`; «Тест: …»
  commits are hidden. A backup is taken before any reset; the owner's local
  commits and uncommitted changes are replayed on top of the update (checked in
  a temporary worktree, file modes included), a conflict leaves the repo
  untouched and writes `state/update-blocked.json`. New read-only `scan`
  subcommand: one JSON summary of local commits, uncommitted files, kit tweaks
  and extra files.
- **Weekly tidy-up of old file copies (#95).** `agent-kit/bin/backup-tidy.py`
  keeps the 5 newest and all copies younger than 14 days per file, packs the
  rest into a verified (sha256) archive under `archive/old-copies/`, deletes
  originals only after the check, and leaves a copy that changed after packing.
- **Kit TDD commit gate (#99).** `agent-kit/hooks/tdd-commit-gate.py` blocks a
  `git commit` with code but no test (or an earlier test on the branch), unless
  the message carries «Без теста: <reason>».
- **Effort in the status card (#104).** The model line reads
  `claude-opus-5-5 · effort: high`; the level comes from the transcript turn or
  the process `--effort` flag, omitted when unknown.
- **Kit pre-send source gate.** `agent-kit/hooks/reply-proxy-gate.py` (PreToolUse
  on the channel reply) denies a reply carrying a negative/absence claim or a
  money figure when nothing related was opened in that turn — the same verdict as
  the Stop-time `stop-proxy-gate.py`, applied before the message leaves. A reply
  marked «гипотеза» / «не проверял» / `[unverified]` passes. The negative-claim
  patterns are widened (the eight false «нет» of week 19-25.10.2026), and
  `turnlib.turn_entries` reads only the last 8 MB of the transcript.

### Changed
- **`scan` reports blobs of uncommitted files (#97)** and no longer counts old
  file copies and temp folders as the owner's own changes (#94).
- **Planner gets the branch explicitly (#98).** `/update` passes `--branch`
  instead of letting the planner guess it from `FETCH_HEAD`.

### Fixed
- **Fallback no longer leaks internal text (#105).** The «Stop hook feedback»
  line and turn-companion lines stay part of the original Telegram turn (its
  `reply` and `chat_id` are kept); a turn started by a background
  `<task-notification>` is not forwarded to the last chat.
- **`job-fail-watch` on Python 3.10 (#102).** The script no longer fails to
  parse there (backslash inside an f-string), and the same failure with new
  numbers is one signature again (the shape regex matched a backslash).
- **`job-fail-watch` skips logs that quote conversation (#103):** `ov-memory.log`,
  `tmux-pane.log`, `tmux-pane.prev.log`.
- **`job-fail-watch` catches the kit's own failure lines:** `[stamp] FAIL: …`
  from `agent-backup.sh` (an off-site backup failed two days unnoticed),
  `ОШИБКА: …` from `backup-tidy.py`, `[ov-session-sync] ERROR: …`. Anchored, so
  words like `FAILURES` or prose «no FAIL here» do not trigger.

### Security
- **webhook-listener: `aiohttp>=3.14.4` (#101).** The old `>=3.9` floor allowed
  versions with known vulnerabilities.

## [1.3.0] — 2026-07-22

### Added
- **Guest Mode media parity.** A guest `@`-mention now delivers inbound media
  at DM parity: the mention's own photo (eager-downloaded to the inbox), voice
  (transcribed), and document/audio/video/video_note/sticker/animation (as
  `file_id` `<media>` descriptors), plus the replied-to message's media surfaced
  as **metadata-only** `<media>` tags inside the `<untrusted_metadata>` reply
  block. Previously the guest path was text-only and dropped a media-only
  mention with no caption.
- **`download_attachment` works in guest/foreign chats.** When called with a
  `guest_query_id`, it authorizes via a **non-consuming** registry check
  (`GuestQueryRegistry.hasActiveEntry` — matches a still-live entry created by
  an allowlisted caller, with a chat-id origin guard) instead of the chat
  allowlist. It never widens the legacy allowlist path (no `guest_query_id` =
  unchanged `assertAllowedChat`), and the check does not consume the one-shot
  reply.
- **Animation (GIF)** as a first-class media kind on both the DM and guest
  paths (previously a GIF surfaced only as its back-compat `document` twin).

### Changed
- Reply-target media is **never eager-downloaded or transcribed** — the replied-to
  author is not the allowlisted caller, so reply media stays metadata-only for
  every kind. The mention's own media (from the allowlisted caller) is still
  eager.
- Per-kind media descriptor builders extracted into `src/telegram/media-descriptors.ts`
  (single source of truth, reused by the DM own-message, guest own-message, and
  all reply paths). Pure refactor — no behavior change on existing paths.

### Fixed
- GIF de-dup: a GIF carries both `animation` and a compatibility `document`; the
  media aggregators now emit it once (as `animation`), not twice.
- A reply to a caption-less photo/voice/document no longer swallows the entire
  reply-context block — the `<untrusted_metadata>` reply is emitted with its
  media even when the reply itself has no text.

## [1.2.1] — 2026-07-21

### Changed
- **`plugin/.mcp.json` ships only the `dashi-channel` server.** The four
  `dashi-gbrain-*` HTTP servers pointed at the author's private shared-memory
  host (`mcp.orgrimmar.xyz`), which issues no public tokens — fresh installs
  saw a permanent auth warning and agents wasted time probing an unreachable
  service. Shared-memory MCP entries now live in
  `examples/mcp.gbrain.example.json` as an opt-in template: self-host your own
  brain (https://github.com/qwwiwi/public-gbrain-agentos), point the template
  at YOUR host and merge it in. `.env.example` comment updated to match.

## [1.2.0] — 2026-07-10

### Added
- **Expandable task list in the pinned status card** (PR #100): the single
  pinned card can expand to show the full current task list.
- **tmux-pane task reality mirror** (PR #104): a new `task-reality-mirror.ts`
  reconciler reconciles the pinned task list with the state detected in the
  tmux pane, so the pin reflects the session's actual tasks rather than only
  hook-derived events. Ships alongside narrower task feeders.
- **Tone-of-voice contract document** (PR #105): a new
  [plugin/docs/TOV.md](plugin/docs/TOV.md) documents the output tone-of-voice
  contract.

### Changed
- **Telegram output formatting** (PR #105): newline preservation in the rich
  message path and a heading-affinity chunker that keeps a heading with the
  block it introduces.
- **Context HUD window is model-aware** (PRs #106, #107): the context-%
  denominator is now resolved from the session model instead of a fixed
  default — Fable-class models report their true 1M-token window, and the
  session model is read from the transcript so no manual override is needed.
  An explicit operator override is still available and always wins over the
  per-model table; precedence is config `context_window_tokens` > env
  `JARVIS_CONTEXT_WINDOW` > per-model table.
- **`webhook/server.ts` split into route modules** (PR #108): the webhook
  server is refactored into focused route modules — a move-only refactor with
  no behavior change.
- **`.gitignore` hardened** (PR #108): the ignore rules are tightened so
  build/junk artifacts are no longer tracked.

### Fixed
- **`classifyPane` recognizes the Claude Code v2.1.201 busy spinner** (PR #101)
  — the pane classifier no longer misreads a working session as idle on the
  newer harness build.
- **Session task snapshot reset on session start** (PR #100): the pinned task
  snapshot is reset when a new session starts, so a fresh session no longer
  inherits the previous one's tasks.
- **Task pin session-lifecycle fixes** (PR #104): Stop is treated as
  end-of-turn, not end-of-session, so tasks are no longer finalized or cleared
  on Stop; task snapshots are namespaced by session id (reset on a session
  change, preserved across compaction); a phantom `PreToolUse` task feeder that
  raced the permission gate is removed; and the snapshot TTL only evicts
  orphaned sessions, never the active one.
- **Zoom join-URL redaction exemption** (PR #102): the `pwd=` parameter is
  intentionally preserved in recognized `zoom.us` join URLs so shared meeting
  links stay usable; the exemption is scoped by a query-param allowlist (`pwd`,
  `uname`, `omn`), with a raw-NUL strip on input to mitigate placeholder
  spoofing.
- **Precise git-exec-surface gate detector** (PR #103): the permission gate
  no longer raises false confirmation cards for benign git usage while keeping
  its RCE protection intact.

### Removed
- **Dead code and tracked-junk purge** (PR #108): the unused
  `persona-manager.ts` is removed (the per-chat persona overlay is applied by
  the `chats/hooks/session-start.sh` SessionStart hook), and tracked build/junk
  artifacts are purged from the index.

## [1.1.0] — 2026-07-04

### Added
- **Rich messages** (PR #86): DM replies auto-upgrade to Telegram Bot API 10.1
  `sendRichMessage` — raw markdown rendered server-side (tables, headings,
  task-lists, math, `<details>`, footnotes), 32 KB in a single message.
  Transparent HTML fallback, session capability latch, killswitch
  `TELEGRAM_RICH_MESSAGES=0`, per-chat opt-out.
- **Guest Mode** (PR #96): one-shot @-mention answers in chats the bot is not
  a member of, via `answerGuestQuery`; fail-closed allowlist gate on the
  caller's user id.
- **Context HUD + state-aware controls** (PR #94): pinned context-% HUD,
  reliable `/compact`, `/new`, `/status` driven through the TUI, owner-scoped
  command menu, AskUserQuestion relayed as Telegram inline buttons.
- **Single pinned status card** (PR #95): one pinned message combining
  context %, mode, and task list, re-anchored above the tmux mirror on every
  inbound message; service bubbles auto-deleted.

### Fixed
- HUD dialog no longer renders a stray second button row (PR #97).

## [1.0.0] — 2026-06-14

Retroactive baseline — first stable state, in production for the whole agent
fleet (silvana, kaelthas, garrosh, arthas). Highlights accumulated since
2026-05-14:

- Telegram DM bridge: inbound injection into a tmux-hosted Claude Code
  session, `reply`/`edit_message`/`react`/`download_attachment` MCP tools.
- Multichat: public group/supergroup sessions with an outbox delivery path.
- Permission gate + relay: sensitive tool calls confirmed via Telegram.
- Confirm-panel keys (PRs #79–#84): one-tap button keypad for native TUI
  dialogs, OOB slash commands, backspace/passthrough handling.
- Terminal mirror, voice-message transcription, photo/document intake.
- Secret redaction on every outbound path; bot-token scrubbing.
- `doctor` self-diagnostics (fleet checks, bridge checks, socket checks).
- Session auto-restart watchdog.
