// IdleCompactor — proactive /compact before the prompt cache goes cold.
//
// Why: Claude Code's prompt cache has a 1-hour TTL. When the agent sits idle
// past it with a large context (~300k tokens), the NEXT inbound message pays a
// full cache WRITE of that whole context. Running Claude Code's own /compact a
// few minutes BEFORE the TTL expires costs only a cheap cache READ, and the next
// message then lands on a small, freshly-compacted context.
//
// How: a 60 s (unref'd) tick checks, cheapest first:
//   1. enabled + a resolved tmux target (else inert; no target is logged once);
//   2. the owner session's transcript path is known and stat-able;
//   3. transcript untouched for >= idle_minutes but < CACHE_TTL (past the TTL
//      the cache is already cold and compacting saves nothing);
//   4. this idle period (keyed on the observed transcript mtime) has not been
//      attempted yet, and the 30-min hard cooldown since the last attempt has
//      elapsed;
//   5. context usage >= min_context_tokens (a compact boundary newer than the
//      last turn reads as 0, so an already-compacted session is never redone);
//   6. the pane POSITIVELY classifies as idle — a busy/dialog/unknown pane is
//      skipped WITHOUT consuming the idle period (re-checked next tick);
//   7. sendControlCommand(target, 'compact', { interruptIfBusy: false }) — it
//      re-probes and refuses a busy pane itself, never interrupting work.
// Step 7's outcome (ok or not) consumes the idle period: no retry until the
// transcript changes. Outcomes are logged at info; nothing goes to Telegram.
//
// Long foreground tool call: a `sleep 3600`-style Bash call writes nothing to
// the transcript, so mtime looks idle — but the pane shows the interrupt hint
// (classifyPane → 'busy'), step 6 skips, and sendControlCommand would refuse a
// busy pane anyway. When the tool finishes the transcript is written, starting
// a fresh idle period.
//
// All I/O is injected so the decision logic is unit-testable without tmux.

import { stat } from 'node:fs/promises'

import type { Logger } from '../log.js'
import {
  capturePane,
  classifyPane,
  sendControlCommand,
  type ControlCommandOpts,
  type ControlCommandResult,
  type KeysCaptureExec,
  type KeysExec,
  type PaneState,
  type TmuxKeysTarget,
} from '../commands/keys.js'
import { readContextUsage } from './context-usage.js'
import type { SessionInfoStore } from './session-info.js'

export const IDLE_COMPACT_TICK_MS = 60_000
export const IDLE_COMPACT_COOLDOWN_MS = 30 * 60_000
// Claude Code's prompt cache TTL. Idle beyond it = cache already cold.
export const PROMPT_CACHE_TTL_MS = 60 * 60_000

const MINUTE_MS = 60_000

export type IdleCompactTickResult =
  | 'disabled'
  | 'no-target'
  | 'in-flight'
  | 'no-transcript'
  | 'not-idle'
  | 'cache-expired'
  | 'already-attempted'
  | 'cooldown'
  | 'usage-unknown'
  | 'small-context'
  | 'pane-not-idle'
  | 'sent'
  | 'send-failed'

export interface IdleCompactorDeps {
  log: Logger
  enabled: boolean
  idleMinutes: number
  minContextTokens: number
  // The agent pane (server's resolved tmux keys target). undefined → inert.
  target: TmuxKeysTarget | undefined
  // The owner session's current transcript path (from SessionInfoStore).
  getTranscriptPath: () => string | undefined
  // Transcript mtime in ms, or null when the file cannot be stat'ed.
  statMtimeMs: (path: string) => Promise<number | null>
  // Current context usage in tokens, or null when unknown.
  readUsedTokens: (path: string) => Promise<number | null>
  // capturePane + classifyPane.
  probePane: (target: TmuxKeysTarget) => Promise<PaneState>
  // sendControlCommand(target, 'compact', { interruptIfBusy: false }).
  sendCompact: (target: TmuxKeysTarget) => Promise<ControlCommandResult>
  now?: () => number
  setInterval?: (fn: () => void, ms: number) => ReturnType<typeof setInterval>
  clearInterval?: (handle: ReturnType<typeof setInterval>) => void
}

export class IdleCompactor {
  private readonly deps: IdleCompactorDeps
  private readonly now: () => number
  private timer: ReturnType<typeof setInterval> | null = null
  private running = false
  private noTargetLogged = false
  // mtime of the idle period we already attempted (no retry until it changes).
  private attemptedMtime: number | null = null
  private lastAttemptAt: number | null = null

  constructor(deps: IdleCompactorDeps) {
    this.deps = deps
    this.now = deps.now ?? Date.now
  }

  start(): void {
    const { log, enabled, target } = this.deps
    if (!enabled) {
      log.info('idle compact disabled by config')
      return
    }
    if (target === undefined) {
      this.logNoTargetOnce()
      return
    }
    if (this.timer !== null) return
    const set =
      this.deps.setInterval ??
      ((fn: () => void, ms: number): ReturnType<typeof setInterval> => setInterval(fn, ms))
    const handle = set(() => {
      void this.tick().catch((err: unknown) => {
        log.warn('idle compact tick failed (ignored)', {
          error: err instanceof Error ? err.message : String(err),
        })
      })
    }, IDLE_COMPACT_TICK_MS)
    // Never keep the process alive just for this housekeeping timer.
    ;(handle as { unref?: () => unknown }).unref?.()
    this.timer = handle
    log.info('idle compact armed', {
      idle_minutes: this.deps.idleMinutes,
      min_context_tokens: this.deps.minContextTokens,
    })
  }

  stop(): void {
    if (this.timer === null) return
    const clear = this.deps.clearInterval ?? clearInterval
    clear(this.timer)
    this.timer = null
  }

  async tick(): Promise<IdleCompactTickResult> {
    const { enabled, target } = this.deps
    if (!enabled) return 'disabled'
    if (target === undefined) {
      this.logNoTargetOnce()
      return 'no-target'
    }
    if (this.running) return 'in-flight'
    this.running = true
    try {
      return await this.evaluate(target)
    } finally {
      this.running = false
    }
  }

  private async evaluate(target: TmuxKeysTarget): Promise<IdleCompactTickResult> {
    const { log } = this.deps
    const path = this.deps.getTranscriptPath()
    if (path === undefined || path.length === 0) return 'no-transcript'
    const mtime = await this.deps.statMtimeMs(path)
    if (mtime === null) return 'no-transcript'

    const now = this.now()
    const idleMs = now - mtime
    if (idleMs < this.deps.idleMinutes * MINUTE_MS) return 'not-idle'
    if (idleMs >= PROMPT_CACHE_TTL_MS) return 'cache-expired'
    if (this.attemptedMtime === mtime) return 'already-attempted'
    if (this.lastAttemptAt !== null && now - this.lastAttemptAt < IDLE_COMPACT_COOLDOWN_MS) {
      return 'cooldown'
    }

    const usedTokens = await this.deps.readUsedTokens(path)
    if (usedTokens === null) return 'usage-unknown'
    if (usedTokens < this.deps.minContextTokens) return 'small-context'

    const pane = await this.deps.probePane(target)
    if (pane !== 'idle') {
      log.debug('idle compact: pane not idle, will re-check', { pane })
      return 'pane-not-idle'
    }

    // From here on the idle period is consumed, whatever the outcome.
    this.attemptedMtime = mtime
    this.lastAttemptAt = now
    const idleMinutes = Math.floor(idleMs / MINUTE_MS)
    log.info('idle compact attempt', { used_tokens: usedTokens, idle_minutes: idleMinutes })
    let res: ControlCommandResult
    try {
      res = await this.deps.sendCompact(target)
    } catch (err) {
      log.warn('idle compact failed', {
        reason: 'exception',
        error: err instanceof Error ? err.message : String(err),
      })
      return 'send-failed'
    }
    if (res.ok) {
      log.info('idle compact sent ok', { used_tokens: usedTokens })
      return 'sent'
    }
    log.info('idle compact failed', { reason: res.reason })
    return 'send-failed'
  }

  private logNoTargetOnce(): void {
    if (this.noTargetLogged) return
    this.noTargetLogged = true
    this.deps.log.info('idle compact inert: no tmux pane resolvable')
  }
}

// The owner DM session's transcript. Keyed strictly by owner chat ids — never
// the store's global `latest`, which in multichat can be a GROUP session whose
// size says nothing about the DM pane we would compact.
export function resolveOwnerTranscriptPath(
  sessionInfo: Pick<SessionInfoStore, 'get'>,
  ownerChatIds: ReadonlyArray<number | string>,
): string | undefined {
  for (const id of ownerChatIds) {
    const path = sessionInfo.get(String(id)).transcriptPath
    if (path !== undefined && path.length > 0) return path
  }
  return undefined
}

export interface IdleCompactorIoOpts {
  exec?: KeysExec
  captureExec?: KeysCaptureExec
  sleep?: (ms: number) => Promise<void>
}

export type IdleCompactorIo = Pick<
  IdleCompactorDeps,
  'statMtimeMs' | 'readUsedTokens' | 'probePane' | 'sendCompact'
>

// Real I/O for IdleCompactor. tmux execs are overridable for tests only.
export function createIdleCompactorIo(opts: IdleCompactorIoOpts = {}): IdleCompactorIo {
  return {
    statMtimeMs: async (path) => {
      try {
        return (await stat(path)).mtimeMs
      } catch {
        return null
      }
    },
    readUsedTokens: async (path) => {
      // usedTokens does not depend on the window; pass 0 (pct is ignored).
      const usage = await readContextUsage(path, 0, { resetAtCompactBoundary: true })
      return usage === null ? null : usage.usedTokens
    },
    // undefined captureExec → capturePane's own default (real tmux).
    probePane: async (target) => classifyPane(await capturePane(target, opts.captureExec)),
    sendCompact: (target) => {
      const ctl: ControlCommandOpts = { interruptIfBusy: false }
      if (opts.exec) ctl.exec = opts.exec
      if (opts.captureExec) ctl.captureExec = opts.captureExec
      if (opts.sleep) ctl.sleep = opts.sleep
      return sendControlCommand(target, 'compact', ctl)
    },
  }
}
