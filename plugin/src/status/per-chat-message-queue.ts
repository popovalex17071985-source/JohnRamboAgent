// PerChatMessageQueue — shared machinery behind ProgressReporter and
// TaskMirror. Both maintain ONE rolling Telegram message per chat, edited as
// Claude hook events arrive, and both implement the identical lifecycle:
//
//   * Single-slot per-chat queue: at most one Telegram request in flight per
//     chat (`flushPromise !== null` guard). New events while one is in flight
//     overwrite `desiredText` so only the freshest snapshot ever publishes.
//   * Throttle via `edit_throttle_ms`: first send bypasses throttle, later
//     edits within the window defer onto a single one-shot timer slot.
//   * Idempotency: identical rendered text → no Telegram round-trip.
//   * TTL eviction on `session_ttl_ms` of idleness — protects against lost
//     `session_stop` hooks and cross-session pollution.
//   * Stop awaits any in-flight flush, posts a final edit (subclass-defined),
//     then evicts the entry. Idempotent.
//   * Telegram failures caught + logged at warn; state stays alive for retry.
//
// Subclasses provide ONLY the differing parts: how to build per-chat render
// state, which config slice to read, how to render the snapshot and the final
// line, and the log-message prefix. The send/edit/throttle/TTL plumbing lives
// here once.

import type { Logger } from '../log.js'
import type { TelegramApiForProgress } from './telegram-api.js'

// HTML parse_mode for both send and edit so inline tags (<b>, <code>, <pre>,
// <i>) render. Shared by every subclass.
const HTML_OPTS = { parse_mode: 'HTML' as const }

// The config slice every queue subclass needs. Both `config.progress` and
// `config.task_mirror` satisfy this shape.
export interface QueueConfigSlice {
  enabled: boolean
  edit_throttle_ms: number
  session_ttl_ms: number
}

// Common single-slot queue state. Subclasses extend this with their own
// render-source fields (e.g. `calls[]` or `todos[]`/`taskMap`).
export interface BaseChatEntry {
  chatId: string
  messageId?: number
  startedAtMs: number
  // Updated on every recordEvent. Used by TTL eviction in getOrCreate.
  lastActivityMs: number
  // Last text we actually sent / edited. Idempotency gate.
  lastRenderedText?: string
  // Timestamp of the last successful send or edit. Used for throttle.
  lastEditAtMs: number
  // Newest snapshot text waiting to be published. Multiple events overwrite
  // so only the freshest view ever lands on Telegram.
  desiredText?: string
  // Single-slot scheduler: non-null while a Telegram op is in flight.
  flushPromise: Promise<void> | null
  // Single-slot throttle timer. Non-null while waiting for the throttle
  // window to elapse before publishing.
  pendingTimer: NodeJS.Timeout | null
  // True once Stop has been processed. Idempotency guard.
  stopped: boolean
}

export interface PerChatMessageQueueDeps {
  telegramApi: TelegramApiForProgress
  log: Logger
  now: () => number
  setTimer: (cb: () => void, ms: number) => NodeJS.Timeout
  clearTimer: (handle: NodeJS.Timeout) => void
}

/**
 * Template base for the per-chat rolling-message queue. `E` is the subclass's
 * concrete entry type (extends BaseChatEntry with its render source).
 *
 * Subclasses MUST implement:
 *   - `getConfigSlice()` — which AppConfig slice governs this queue.
 *   - `createEntryState()` — the subclass-specific fields for a fresh entry.
 *   - `renderEntry(entry)` — the intermediate snapshot text ('' to skip).
 *   - `renderFinalEntry(entry)` — the Stop-time final text ('' to skip).
 *   - `logPrefix` — used to namespace warn/debug log messages.
 */
export abstract class PerChatMessageQueue<E extends BaseChatEntry> {
  protected readonly telegramApi: TelegramApiForProgress
  protected readonly log: Logger
  protected readonly now: () => number
  private readonly setTimer: (cb: () => void, ms: number) => NodeJS.Timeout
  private readonly clearTimer: (handle: NodeJS.Timeout) => void
  protected readonly chats: Map<string, E>

  constructor(deps: PerChatMessageQueueDeps) {
    this.telegramApi = deps.telegramApi
    this.log = deps.log
    this.now = deps.now
    this.setTimer = deps.setTimer
    this.clearTimer = deps.clearTimer
    this.chats = new Map()
  }

  // ── Subclass hooks ────────────────────────────────────────────────────

  protected abstract getConfigSlice(): QueueConfigSlice
  /** Subclass-specific fields for a fresh entry (everything beyond BaseChatEntry). */
  protected abstract createEntryState(chatId: string): Omit<E, keyof BaseChatEntry>
  /** Intermediate render. Return '' to publish nothing this cycle. */
  protected abstract renderEntry(entry: E): string
  /**
   * Final render. Return '' to skip the final edit. `endMs` is when the work
   * ended: now for Stop, the last activity for a TTL-expired entry (so the
   * closed card does not count the idle gap as work).
   */
  protected abstract renderFinalEntry(entry: E, endMs: number): string
  protected abstract readonly logPrefix: string

  // ── Shared machinery ──────────────────────────────────────────────────

  /**
   * Test-only drain — waits until any in-flight Telegram op for the chat
   * settles AND any follow-up reschedule completes. Production callers must
   * NOT depend on this.
   */
  async _idleForTests(chatId: string): Promise<void> {
    for (let i = 0; i < 16; i++) {
      const entry = this.chats.get(chatId)
      if (!entry || entry.flushPromise === null) return
      try {
        await entry.flushPromise
      } catch {
        /* already logged */
      }
    }
  }

  /**
   * Evict the chat's entry if it has been idle past `session_ttl_ms`. The
   * expired card never got its Stop (lost hook, forked side query), so it is
   * closed with the same final render Stop would post instead of hanging on
   * «работаю» forever. Fire-and-forget: stays sync, never throws.
   */
  protected evictIfExpired(chatId: string): void {
    const existing = this.chats.get(chatId)
    if (!existing) return
    const idle = this.now() - existing.lastActivityMs
    if (idle <= this.getConfigSlice().session_ttl_ms) return
    this.log.debug(`${this.logPrefix} entry TTL expired, starting fresh thread`, {
      chat_id: chatId,
      idle_ms: idle,
    })
    this.chats.delete(chatId)
    void this.finalizeEntry(existing, existing.lastActivityMs).catch((err: unknown) => {
      this.log.warn(`${this.logPrefix} TTL finalize failed (ignored)`, {
        chat_id: chatId,
        error: err instanceof Error ? err.message : String(err),
      })
    })
  }

  protected getOrCreate(chatId: string): E {
    this.evictIfExpired(chatId)
    const existing = this.chats.get(chatId)
    if (existing) return existing
    const base: BaseChatEntry = {
      chatId,
      startedAtMs: this.now(),
      lastActivityMs: this.now(),
      lastEditAtMs: 0,
      flushPromise: null,
      pendingTimer: null,
      stopped: false,
    }
    const entry = { ...base, ...this.createEntryState(chatId) } as E
    this.chats.set(chatId, entry)
    return entry
  }

  /**
   * Render the current snapshot and schedule a flush. Idempotent — if a flush
   * is already in flight or a timer is armed, just update `desiredText`.
   */
  protected scheduleFlush(entry: E): void {
    if (entry.stopped) return
    const text = this.renderEntry(entry)
    if (!text || text === entry.lastRenderedText) return
    entry.desiredText = text

    if (entry.flushPromise !== null || entry.pendingTimer !== null) return

    const isFirstSend = entry.messageId === undefined
    const elapsed = this.now() - entry.lastEditAtMs
    const wait = isFirstSend
      ? 0
      : Math.max(0, this.getConfigSlice().edit_throttle_ms - elapsed)

    if (wait > 0) {
      entry.pendingTimer = this.setTimer(() => {
        entry.pendingTimer = null
        this.startFlush(entry)
      }, wait)
    } else {
      this.startFlush(entry)
    }
  }

  private startFlush(entry: E): void {
    if (entry.stopped) return
    if (entry.flushPromise !== null) return
    const text = entry.desiredText
    if (text === undefined || text === entry.lastRenderedText) return
    delete entry.desiredText

    entry.flushPromise = this.executeFlush(entry, text).finally(() => {
      entry.flushPromise = null
      if (
        !entry.stopped &&
        entry.desiredText !== undefined &&
        entry.desiredText !== entry.lastRenderedText
      ) {
        this.scheduleFlush(entry)
      }
    })
  }

  private async executeFlush(entry: E, text: string): Promise<void> {
    if (entry.messageId === undefined) {
      try {
        const sent = await this.telegramApi.sendMessage(entry.chatId, text, HTML_OPTS)
        if (!entry.stopped) {
          entry.messageId = sent.message_id
          entry.lastRenderedText = text
          entry.lastEditAtMs = this.now()
        } else {
          this.log.warn(`${this.logPrefix} send completed after stop (orphan)`, {
            chat_id: entry.chatId,
            message_id: sent.message_id,
          })
        }
      } catch (err) {
        this.log.warn(`${this.logPrefix} sendMessage failed (ignored)`, {
          chat_id: entry.chatId,
          error: err instanceof Error ? err.message : String(err),
        })
      }
      return
    }

    try {
      await this.telegramApi.editMessageText(entry.chatId, entry.messageId, text, HTML_OPTS)
      if (!entry.stopped) {
        entry.lastRenderedText = text
        entry.lastEditAtMs = this.now()
      }
    } catch (err) {
      this.log.warn(`${this.logPrefix} editMessageText failed (ignored)`, {
        chat_id: entry.chatId,
        message_id: entry.messageId,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  /**
   * Stop handler — cancels the throttle timer, awaits any in-flight flush,
   * posts a final edit (if a message exists and the subclass renders one),
   * then evicts the entry. Idempotent: a second call is a no-op.
   */
  protected async handleStop(chatId: string): Promise<void> {
    const entry = this.chats.get(chatId)
    if (!entry || entry.stopped) return
    await this.finalizeEntry(entry, this.now())
    // Only evict if the slot still holds this entry (a TTL restart may have
    // replaced it while we awaited).
    if (this.chats.get(chatId) === entry) this.chats.delete(chatId)
  }

  /**
   * Mark the entry stopped, cancel its throttle timer, await any in-flight
   * flush and post the subclass's final render. Never throws; does NOT touch
   * `this.chats` (callers own eviction). Idempotent via `stopped`.
   */
  private async finalizeEntry(entry: E, endMs: number): Promise<void> {
    if (entry.stopped) return
    entry.stopped = true

    if (entry.pendingTimer !== null) {
      this.clearTimer(entry.pendingTimer)
      entry.pendingTimer = null
    }

    if (entry.flushPromise !== null) {
      try {
        await entry.flushPromise
      } catch {
        /* already logged inside executeFlush */
      }
    }

    if (entry.messageId !== undefined) {
      const text = this.renderFinalEntry(entry, endMs)
      if (text && text !== entry.lastRenderedText) {
        try {
          await this.telegramApi.editMessageText(entry.chatId, entry.messageId, text, HTML_OPTS)
          entry.lastRenderedText = text
        } catch (err) {
          this.log.warn(`${this.logPrefix} final edit failed (ignored)`, {
            chat_id: entry.chatId,
            message_id: entry.messageId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
      }
    }
  }
}
