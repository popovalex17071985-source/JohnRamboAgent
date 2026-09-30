// ProgressReporter — persistent Telegram thread showing per-tool activity
// in real time. Owns ONE message per chat, edited via editMessageText as
// new Claude hook events arrive.
//
// Why separate from StatusManager:
//   * StatusManager owns a transient bubble that auto-cancels on every
//     real reply (see status-manager.ts: «start() while active silently
//     cancels»). Result: the warchief sees nothing.
//   * ProgressReporter owns a different message that persists through
//     replies — a running log of «what Thrall is doing now». Both
//     coexist; the webhook fires them in parallel and independently.
//
// The per-chat queue/throttle/TTL/stop machinery lives in
// PerChatMessageQueue (shared with TaskMirror). This module supplies only
// the activity-specific parts: the `calls` window, event application, the
// activity-block render, and the public read API (isBusy/getActiveToolName)
// the InboundWatcher depends on.

import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'
import { isSubagentToolEvent, type ActivityStatusEvent } from '../hooks/claude-events.js'
import {
  buildActivityDetail,
  buildHumanizedActivityLine,
  renderActivityBlock,
  type ActivityCall,
  type ActivitySnapshot,
} from './activity-renderer.js'
import {
  PerChatMessageQueue,
  type BaseChatEntry,
  type QueueConfigSlice,
} from './per-chat-message-queue.js'

// Telegram surface shared with task-mirror. Canonical definition lives in
// `./telegram-api.ts` so both modules depend on it instead of on each
// other. Re-exported here for back-compat with existing imports
// (`from './progress-reporter.js'` is still legal but new code should
// import from `./telegram-api.js` directly).
export type { TelegramApiForProgress } from './telegram-api.js'
import type { TelegramApiForProgress } from './telegram-api.js'

export interface ProgressReporterDeps {
  telegramApi: TelegramApiForProgress
  config: AppConfig
  log: Logger
  now?: () => number
  setTimer?: (cb: () => void, ms: number) => NodeJS.Timeout
  clearTimer?: (handle: NodeJS.Timeout) => void
}

// Per-chat lifecycle: lazy-created on first event, evicted on
// session_stop or TTL expiry. Extends the shared queue entry with the
// rolling activity buffer.
interface ChatProgressEntry extends BaseChatEntry {
  // Sliding window of recent ActivityCalls; renderer caps the display.
  calls: ActivityCall[]
}

// Tools that should never appear in the rolling activity card. Deferred-tool
// lookups (ToolSearch) are pure bookkeeping; the dashi-channel MCP reply tools
// are the channel itself (mirroring them would recurse), and gbrain-recall is
// background context fetching the operator does not need to see.
//
// NB: Read/Grep/Glob are intentionally NOT skipped — the operator's preferred
// verbose card (gateway era) listed reads and globs alongside Bash/Edit. They
// were un-filtered 2026-06-14 to restore that density. Bash/Edit/Write/
// WebFetch/WebSearch/Agent and gbrain mutations always flow through.
const NOISY_TOOL_NAMES: ReadonlySet<string> = new Set([
  'ToolSearch',
])
const NOISY_TOOL_PREFIXES: ReadonlyArray<string> = [
  'mcp__dashi-channel__',
  'mcp__dashi-gbrain-recall__',
]

export function shouldSkipTool(toolName: string): boolean {
  if (NOISY_TOOL_NAMES.has(toolName)) return true
  return NOISY_TOOL_PREFIXES.some((p) => toolName.startsWith(p))
}

export class ProgressReporter extends PerChatMessageQueue<ChatProgressEntry> {
  private readonly config: AppConfig
  protected readonly logPrefix = 'progress reporter'

  constructor(deps: ProgressReporterDeps) {
    super({
      telegramApi: deps.telegramApi,
      log: deps.log,
      now: deps.now ?? (() => Date.now()),
      setTimer: deps.setTimer ?? ((cb, ms) => setTimeout(cb, ms)),
      clearTimer: deps.clearTimer ?? ((h) => clearTimeout(h)),
    })
    this.config = deps.config
  }

  /**
   * Main entry point. Called by the webhook handler for every
   * `claude_hook` payload. Never throws — top-level try/catch swallows
   * any failure so the webhook 200 path is never blocked.
   */
  async recordEvent(chatId: string, event: ActivityStatusEvent): Promise<void> {
    if (!this.config.progress.enabled) return
    try {
      if (event.kind === 'session_stop') {
        await this.handleStop(chatId)
        return
      }

      // A sub-agent / forked side-query tool call may annotate the card the
      // main turn has open, but never opens one: no Stop would close it.
      if (isSubagentToolEvent(event) && !this.hasLiveEntry(chatId)) return

      const entry = this.getOrCreate(chatId)
      if (entry.stopped) return
      entry.lastActivityMs = this.now()
      this.applyEvent(entry, event)
      this.scheduleFlush(entry)
    } catch (err) {
      this.log.warn('progress reporter recordEvent failed (ignored)', {
        chat_id: chatId,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  /**
   * Read-only: returns true if a Claude session is actively running tools
   * for this chat — used by InboundWatcher to decide whether to auto-reply
   * «Тралл занят». Definition:
   *   entry exists AND !entry.stopped AND (now - lastActivityMs) < threshold
   *
   * `thresholdMs` is REQUIRED — the watcher owns the threshold via its
   * own config slice and passes it in. This module deliberately does NOT
   * reach into `config.watcher` to keep the dependency direction one-way
   * (status module is upstream of watcher; watcher reads from us, not the
   * other way around).
   *
   * Boundary semantics: strict `<` so a tick at exactly the threshold is
   * already considered idle — matches the natural «more than N ms idle =
   * not busy» reading.
   */
  isBusy(chatId: string, thresholdMs: number): boolean {
    const entry = this.chats.get(chatId)
    if (!entry || entry.stopped) return false
    return this.now() - entry.lastActivityMs < thresholdMs
  }

  /**
   * Returns the most recently OBSERVED tool name from the calls window for
   * this chat, or `undefined` if no entry exists / no tools have been
   * recorded. Used by InboundWatcher to compose the auto-reply body —
   * «активный инструмент: Bash».
   *
   * Important semantic note for future maintainers:
   *   The name STAYS POPULATED after `tool_end`. We do NOT clear it on
   *   tool completion. This is intentional — the watcher's busy-threshold
   *   accounts for the gap between `tool_end` and the next `tool_start`.
   *   Returning `undefined` here during that brief idle window would cause
   *   false-negative auto-replies (the watcher would see «not busy» and
   *   suppress the «Тралл занят» message even though Claude is about to
   *   call the next tool any millisecond now).
   *
   *   `tool_end` is render-only inside this module (see applyEvent) — it
   *   moves the elapsed counter forward without mutating `entry.calls`.
   *   The latest call therefore continues to anchor the «active tool»
   *   answer until either (a) a fresh `tool_start` overwrites it or
   *   (b) the chat is evicted by session_stop / TTL.
   */
  getActiveToolName(chatId: string): string | undefined {
    const entry = this.chats.get(chatId)
    if (!entry || entry.calls.length === 0) return undefined
    return entry.calls[entry.calls.length - 1]?.toolName
  }

  // ─────────────────────────────────────────────────────────────────────
  // Subclass hooks
  // ─────────────────────────────────────────────────────────────────────

  protected getConfigSlice(): QueueConfigSlice {
    return this.config.progress
  }

  protected createEntryState(_chatId: string): { calls: ActivityCall[] } {
    return { calls: [] }
  }

  protected renderEntry(entry: ChatProgressEntry): string {
    return this.safeRender(this.buildSnapshot(entry))
  }

  /**
   * Final-line render: re-uses renderActivityBlock to keep visual
   * parity with intermediate edits, then appends «done -- Ns» as the
   * last line inside the <pre> body so a single block paragraph remains.
   */
  protected renderFinalEntry(entry: ChatProgressEntry): string {
    const snapshot = this.buildSnapshot(entry)
    const block = this.safeRender(snapshot)
    if (!block) return ''
    const elapsedSec = Math.max(0, Math.floor((this.now() - entry.startedAtMs) / 1000))
    const doneLine = `\n\ndone -- ${elapsedSec}s`
    if (block.endsWith('</pre>')) {
      return `${block.slice(0, -'</pre>'.length)}${doneLine}</pre>`
    }
    return `${block}${doneLine}`
  }

  // ─────────────────────────────────────────────────────────────────────
  // Internals
  // ─────────────────────────────────────────────────────────────────────

  /**
   * Mutate `entry.calls` based on the event. tool_start appends; other
   * non-Stop events are render-only (move the elapsed counter forward).
   *
   * Noise-filter: tool names in `NOISY_TOOLS` (Read/Grep/Glob/ToolSearch and
   * the dashi-channel + recall MCP prefixes) update `lastActivityMs` upstream
   * but never enter `entry.calls`, so the rolling card stays focused on
   * meaningful actions (Bash, Edit, Write, WebFetch, Agent, gbrain mutations).
   */
  private applyEvent(entry: ChatProgressEntry, event: ActivityStatusEvent): void {
    switch (event.kind) {
      case 'tool_start': {
        if (shouldSkipTool(event.toolName)) break
        const detail = buildActivityDetail(event.toolName, event.toolInput)
        const humanized = buildHumanizedActivityLine(event.toolName, event.toolInput)
        const call: ActivityCall = { toolName: event.toolName, detail, humanized }
        entry.calls.push(call)
        const cap = this.config.progress.recent_buffer
        if (entry.calls.length > cap) {
          entry.calls.splice(0, entry.calls.length - cap)
        }
        break
      }
      case 'tool_end':
      case 'reasoning':
      case 'session_start':
        // Re-render only. No buffer mutation. The «working -- Ns» header
        // moves forward with elapsed time.
        break
      case 'session_stop':
        // Handled before applyEvent in recordEvent; unreachable here but
        // kept for exhaustiveness.
        break
    }
  }

  // An entry getOrCreate would reuse (not stopped, not TTL-expired).
  private hasLiveEntry(chatId: string): boolean {
    const entry = this.chats.get(chatId)
    if (!entry || entry.stopped) return false
    return this.now() - entry.lastActivityMs <= this.config.progress.session_ttl_ms
  }

  private buildSnapshot(entry: ChatProgressEntry): ActivitySnapshot {
    return {
      startedAtMs: entry.startedAtMs,
      calls: entry.calls,
      phase: entry.calls.length > 0 ? 'tool' : 'reasoning',
    }
  }

  private safeRender(snapshot: ActivitySnapshot): string {
    try {
      return renderActivityBlock(snapshot, this.now())
    } catch (err) {
      this.log.warn('progress reporter render failed (ignored)', {
        error: err instanceof Error ? err.message : String(err),
      })
      return ''
    }
  }
}
