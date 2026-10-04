// IdleCompactor tests. Every I/O edge (clock, transcript mtime, context usage,
// pane probe, /compact send, timers) is injected, so nothing here touches tmux
// or a real transcript.

import { describe, expect, test } from 'bun:test'

import type { Logger } from '../../src/log.js'
import type { ControlCommandResult, PaneState, TmuxKeysTarget } from '../../src/commands/keys.js'
import {
  createIdleCompactorIo,
  IdleCompactor,
  resolveOwnerTranscriptPath,
  type IdleCompactorDeps,
} from '../../src/status/idle-compactor.js'
import { SessionInfoStore } from '../../src/status/session-info.js'
import type { KeysCaptureExec, KeysExec } from '../../src/commands/keys.js'

const MIN = 60_000
const TARGET: TmuxKeysTarget = { paneTarget: '%1', socketPath: '/tmp/tmux-test/default' }
const PATH = '/home/u/.claude/projects/x/session.jsonl'

interface LogEntry {
  level: string
  msg: string
  ctx?: Record<string, unknown>
}

function recordingLogger(): { log: Logger; entries: LogEntry[] } {
  const entries: LogEntry[] = []
  const push = (level: string) => (msg: string, ctx?: Record<string, unknown>): void => {
    entries.push({ level, msg, ...(ctx !== undefined ? { ctx } : {}) })
  }
  return {
    log: { debug: push('debug'), info: push('info'), warn: push('warn'), error: push('error') },
    entries,
  }
}

// A mutable world the fakes read from, so a test can advance the clock or
// "touch" the transcript between ticks.
interface World {
  now: number
  mtime: number | null
  usedTokens: number | null
  pane: PaneState
  sendResult: ControlCommandResult
  transcriptPath: string | undefined
  sends: number
  probes: number
  usageReads: number
}

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    now: 10 * 60 * MIN,
    mtime: 10 * 60 * MIN - 56 * MIN, // idle 56 min
    usedTokens: 300_000,
    pane: 'idle',
    sendResult: { ok: true },
    transcriptPath: PATH,
    sends: 0,
    probes: 0,
    usageReads: 0,
    ...overrides,
  }
}

function makeCompactor(
  world: World,
  overrides: Partial<IdleCompactorDeps> = {},
): { compactor: IdleCompactor; entries: LogEntry[] } {
  const { log, entries } = recordingLogger()
  const deps: IdleCompactorDeps = {
    log,
    enabled: true,
    idleMinutes: 55,
    minContextTokens: 150_000,
    target: TARGET,
    getTranscriptPath: () => world.transcriptPath,
    statMtimeMs: async () => world.mtime,
    readUsedTokens: async () => {
      world.usageReads++
      return world.usedTokens
    },
    probePane: async () => {
      world.probes++
      return world.pane
    },
    sendCompact: async () => {
      world.sends++
      return world.sendResult
    },
    now: () => world.now,
    ...overrides,
  }
  return { compactor: new IdleCompactor(deps), entries }
}

describe('IdleCompactor.tick — fires', () => {
  test('idle ≥ idle_minutes + large context + idle pane → sends /compact once', async () => {
    const world = makeWorld()
    const { compactor, entries } = makeCompactor(world)
    expect(await compactor.tick()).toBe('sent')
    expect(world.sends).toBe(1)
    const attempt = entries.find((e) => e.level === 'info' && /attempt/.test(e.msg))
    expect(attempt).toBeDefined()
    expect(attempt?.ctx?.['used_tokens']).toBe(300_000)
    expect(entries.some((e) => e.level === 'info' && /ok|sent|fired/.test(e.msg))).toBe(true)
  })

  test('passes the configured target to the pane probe and the send', async () => {
    const world = makeWorld()
    const seen: TmuxKeysTarget[] = []
    const { compactor } = makeCompactor(world, {
      probePane: async (t) => {
        seen.push(t)
        return 'idle'
      },
      sendCompact: async (t) => {
        seen.push(t)
        return { ok: true }
      },
    })
    await compactor.tick()
    expect(seen).toEqual([TARGET, TARGET])
  })

  test('exactly at the threshold counts as idle', async () => {
    const world = makeWorld()
    world.mtime = world.now - 55 * MIN
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('sent')
  })
})

describe('IdleCompactor.tick — does not fire', () => {
  test('context below min_context_tokens', async () => {
    const world = makeWorld({ usedTokens: 149_999 })
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('small-context')
    expect(world.sends).toBe(0)
    expect(world.probes).toBe(0)
  })

  test('context usage unknown (null)', async () => {
    const world = makeWorld({ usedTokens: null })
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('usage-unknown')
    expect(world.sends).toBe(0)
  })

  test('not idle long enough', async () => {
    const world = makeWorld()
    world.mtime = world.now - 54 * MIN
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('not-idle')
    expect(world.sends).toBe(0)
    expect(world.usageReads).toBe(0) // cheap checks first
  })

  test('idle past the cache TTL → pointless (cache already cold), no send', async () => {
    const world = makeWorld()
    world.mtime = world.now - 61 * MIN
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('cache-expired')
    expect(world.sends).toBe(0)
  })

  for (const pane of ['busy', 'dialog', 'unknown'] as const) {
    test(`pane ${pane} → no send, and the idle period is NOT consumed`, async () => {
      const world = makeWorld({ pane })
      const { compactor } = makeCompactor(world)
      expect(await compactor.tick()).toBe('pane-not-idle')
      expect(world.sends).toBe(0)
      // The pane frees up a minute later — same idle period, still eligible.
      world.pane = 'idle'
      world.now += MIN
      expect(await compactor.tick()).toBe('sent')
      expect(world.sends).toBe(1)
    })
  }

  test('no transcript path known yet', async () => {
    const world = makeWorld({ transcriptPath: undefined })
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('no-transcript')
    expect(world.sends).toBe(0)
  })

  test('transcript stat fails (file gone)', async () => {
    const world = makeWorld({ mtime: null })
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('no-transcript')
    expect(world.sends).toBe(0)
  })

  test('no tmux target → inert, logged once', async () => {
    const world = makeWorld()
    const { compactor, entries } = makeCompactor(world, { target: undefined })
    expect(await compactor.tick()).toBe('no-target')
    expect(await compactor.tick()).toBe('no-target')
    compactor.start()
    compactor.stop()
    expect(world.sends).toBe(0)
    expect(world.usageReads).toBe(0)
    expect(entries.filter((e) => /no tmux|inert/i.test(e.msg)).length).toBe(1)
  })

  test('disabled → inert', async () => {
    const world = makeWorld()
    const { compactor } = makeCompactor(world, { enabled: false })
    expect(await compactor.tick()).toBe('disabled')
    expect(world.sends).toBe(0)
    expect(world.usageReads).toBe(0)
  })
})

describe('IdleCompactor.tick — once per idle period + cooldown', () => {
  test('second tick in the same idle period does nothing', async () => {
    const world = makeWorld()
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('sent')
    world.now += MIN
    expect(await compactor.tick()).toBe('already-attempted')
    expect(world.sends).toBe(1)
  })

  test('fires again after the transcript changes, a new idle period AND the cooldown', async () => {
    const world = makeWorld()
    const { compactor } = makeCompactor(world)
    expect(await compactor.tick()).toBe('sent')
    const firstAt = world.now

    // Agent answers a message 2 min later → transcript touched.
    world.mtime = firstAt + 2 * MIN
    // 25 min after that the session is idle 55+ min? No — only 25 min idle.
    world.now = firstAt + 27 * MIN
    expect(await compactor.tick()).toBe('not-idle')

    // New idle period reached (idle 55 min) and > 30 min since the attempt.
    world.now = world.mtime + 55 * MIN
    expect(await compactor.tick()).toBe('sent')
    expect(world.sends).toBe(2)
  })

  test('30-min hard cooldown holds even when a new idle period is reached sooner', async () => {
    const world = makeWorld()
    // Short idle threshold so a new idle period can arrive inside the cooldown.
    const { compactor } = makeCompactor(world, { idleMinutes: 10 })
    world.mtime = world.now - 10 * MIN
    expect(await compactor.tick()).toBe('sent')
    const firstAt = world.now

    world.mtime = firstAt + MIN
    world.now = firstAt + 11 * MIN // idle 10 min again, but only 11 min since attempt
    expect(await compactor.tick()).toBe('cooldown')
    expect(world.sends).toBe(1)

    world.now = firstAt + 30 * MIN // cooldown elapsed, same idle period still open
    expect(await compactor.tick()).toBe('sent')
    expect(world.sends).toBe(2)
  })

  test('send failure is logged and NOT retried in the same idle period', async () => {
    const world = makeWorld({ sendResult: { ok: false, reason: 'not-submitted' } })
    const { compactor, entries } = makeCompactor(world)
    expect(await compactor.tick()).toBe('send-failed')
    const fail = entries.find((e) => /fail/i.test(e.msg))
    expect(fail).toBeDefined()
    expect(fail?.ctx?.['reason']).toBe('not-submitted')
    world.now += MIN
    world.sendResult = { ok: true }
    expect(await compactor.tick()).toBe('already-attempted')
    expect(world.sends).toBe(1)
  })

  test('a throwing send is caught, logged, and counts as the attempt', async () => {
    const world = makeWorld()
    const { compactor, entries } = makeCompactor(world, {
      sendCompact: async () => {
        world.sends++
        throw new Error('tmux exploded')
      },
    })
    expect(await compactor.tick()).toBe('send-failed')
    expect(entries.some((e) => e.level === 'warn' && /fail/i.test(e.msg))).toBe(true)
    world.now += MIN
    expect(await compactor.tick()).toBe('already-attempted')
    expect(world.sends).toBe(1)
  })

  test('overlapping ticks: a tick while one is in flight is skipped', async () => {
    const world = makeWorld()
    let release: () => void = () => {}
    const { compactor } = makeCompactor(world, {
      sendCompact: () =>
        new Promise<ControlCommandResult>((resolve) => {
          world.sends++
          release = () => resolve({ ok: true })
        }),
    })
    const first = compactor.tick()
    // Let the first tick reach the (pending) send.
    for (let i = 0; i < 50; i++) await Promise.resolve()
    expect(await compactor.tick()).toBe('in-flight')
    release()
    expect(await first).toBe('sent')
    expect(world.sends).toBe(1)
  })
})

describe('IdleCompactor.start/stop', () => {
  test('schedules a 60s unref’d interval and clears it on stop', async () => {
    const world = makeWorld()
    let scheduledMs = 0
    let unrefCalled = false
    let cleared: unknown = null
    let cb: (() => void) | null = null
    const handle = {
      unref: () => {
        unrefCalled = true
        return handle
      },
    }
    const { compactor } = makeCompactor(world, {
      setInterval: (fn, ms) => {
        cb = fn
        scheduledMs = ms
        return handle as unknown as ReturnType<typeof setInterval>
      },
      clearInterval: (h) => {
        cleared = h
      },
    })
    compactor.start()
    expect(scheduledMs).toBe(60_000)
    expect(unrefCalled).toBe(true)
    expect(cb).not.toBeNull()
    cb!()
    for (let i = 0; i < 50; i++) await Promise.resolve()
    expect(world.sends).toBe(1)
    compactor.stop()
    expect(cleared).toBe(handle)
  })

  test('disabled → start() schedules nothing', () => {
    const world = makeWorld()
    let scheduled = false
    const { compactor } = makeCompactor(world, {
      enabled: false,
      setInterval: (() => {
        scheduled = true
        return 0 as unknown as ReturnType<typeof setInterval>
      }) as NonNullable<IdleCompactorDeps['setInterval']>,
    })
    compactor.start()
    expect(scheduled).toBe(false)
  })
})

// ─── Owner transcript resolution (multichat-safe) ─────────────────────────

describe('resolveOwnerTranscriptPath', () => {
  test('returns the first owner chat that has a transcript', () => {
    const store = new SessionInfoStore()
    store.record('111', { sessionId: 's1' }) // no transcript yet
    store.record('222', { transcriptPath: '/t/owner.jsonl' })
    expect(resolveOwnerTranscriptPath(store, [111, 222])).toBe('/t/owner.jsonl')
  })

  test('never falls back to another chat’s (e.g. a group’s) latest session', () => {
    const store = new SessionInfoStore()
    store.record('-100500', { transcriptPath: '/t/group.jsonl' })
    expect(resolveOwnerTranscriptPath(store, [111])).toBeUndefined()
  })

  test('no owner chats → undefined', () => {
    const store = new SessionInfoStore()
    store.record('111', { transcriptPath: '/t/owner.jsonl' })
    expect(resolveOwnerTranscriptPath(store, [])).toBeUndefined()
  })
})

// ─── Default I/O composition ──────────────────────────────────────────────

const IDLE_PANE = [
  'assistant said something useful',
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
  '  ? for shortcuts',
].join('\n')

const BUSY_PANE = [
  '● Running a tool…',
  '✳ Working… (esc to interrupt)',
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
].join('\n')

describe('createIdleCompactorIo', () => {
  test('statMtimeMs reads the file mtime; missing file → null', async () => {
    const { mkdtempSync, rmSync, writeFileSync, utimesSync } = await import('node:fs')
    const { join } = await import('node:path')
    const { tmpdir } = await import('node:os')
    const dir = mkdtempSync(join(tmpdir(), 'idlecompact-'))
    try {
      const p = join(dir, 's.jsonl')
      writeFileSync(p, '{}\n')
      const when = new Date('2026-10-01T10:00:00Z')
      utimesSync(p, when, when)
      const io = createIdleCompactorIo()
      expect(await io.statMtimeMs(p)).toBe(when.getTime())
      expect(await io.statMtimeMs(join(dir, 'nope.jsonl'))).toBeNull()
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('readUsedTokens: live usage, and 0 right after a compact boundary', async () => {
    const { mkdtempSync, rmSync, writeFileSync } = await import('node:fs')
    const { join } = await import('node:path')
    const { tmpdir } = await import('node:os')
    const dir = mkdtempSync(join(tmpdir(), 'idlecompact-'))
    try {
      const turn = JSON.stringify({
        type: 'assistant',
        isSidechain: false,
        message: { role: 'assistant', usage: { input_tokens: 10, cache_read_input_tokens: 290000 } },
      })
      const boundary = JSON.stringify({ type: 'system', subtype: 'compact_boundary', isSidechain: false })
      const live = join(dir, 'live.jsonl')
      const compacted = join(dir, 'compacted.jsonl')
      writeFileSync(live, turn + '\n')
      writeFileSync(compacted, turn + '\n' + boundary + '\n')
      const io = createIdleCompactorIo()
      expect(await io.readUsedTokens(live)).toBe(290010)
      expect(await io.readUsedTokens(compacted)).toBe(0)
      expect(await io.readUsedTokens(join(dir, 'nope.jsonl'))).toBeNull()
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('probePane classifies the captured pane', async () => {
    let snap = IDLE_PANE
    const captureExec: KeysCaptureExec = async () => ({ exitCode: 0, stdout: snap, stderr: '' })
    const io = createIdleCompactorIo({ captureExec })
    expect(await io.probePane(TARGET)).toBe('idle')
    snap = BUSY_PANE
    expect(await io.probePane(TARGET)).toBe('busy')
  })

  test('sendCompact never interrupts a busy pane (no keys sent)', async () => {
    const sent: Array<readonly string[]> = []
    const exec: KeysExec = async (args) => {
      sent.push(args)
      return { exitCode: 0, stderr: '' }
    }
    const captureExec: KeysCaptureExec = async () => ({ exitCode: 0, stdout: BUSY_PANE, stderr: '' })
    const io = createIdleCompactorIo({ exec, captureExec, sleep: async () => {} })
    expect(await io.sendCompact(TARGET)).toEqual({ ok: false, reason: 'busy' })
    expect(sent).toEqual([]) // no Escape, no /compact
  })
})
