// /update buttons: «Обновить, своё не трогать» / «Обновить всё, даже своё» /
// «Не сейчас». The planner (scripts/update-plan.py) decides which buttons to
// show; the plugin turns them into an inline keyboard and handles the presses
// itself — out-of-band, never through the model.
import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  buildUpdateKeyboard,
  handleUpdateCallback,
  isUpdateCallback,
  parseUpdateCallback,
  type UpdateCallbackContext,
  type UpdateRuntime,
} from '../../src/commands/update-buttons.js'
import type { PlannerOutcome } from '../../src/commands/update-choice.js'
import { makeLogger } from '../helpers/config.js'

const OWNER = 164795011
const FH = 'f'.repeat(40)
const STALE = 'Обновление уже поменялось, нажмите /update ещё раз.'

const BUTTONS: Array<[string, string]> = [
  ['keep', 'Обновить, своё не трогать'],
  ['all', 'Обновить всё, даже своё (копию сохраню)'],
  ['no', 'Не сейчас'],
]

describe('buildUpdateKeyboard', () => {
  test('one row per planner button, callback carries the plan version', () => {
    const kb = buildUpdateKeyboard({ status: 'PLAN', text_html: 'x', buttons: BUTTONS, fetch_head: FH })
    expect(kb).toEqual({
      inline_keyboard: [
        [{ text: 'Обновить, своё не трогать', callback_data: `upd:keep:${FH.slice(0, 12)}` }],
        [{ text: 'Обновить всё, даже своё (копию сохраню)', callback_data: `upd:all:${FH.slice(0, 12)}` }],
        [{ text: 'Не сейчас', callback_data: `upd:no:${FH.slice(0, 12)}` }],
      ],
    })
  })
  test('no buttons (nothing of the owner is touched) → no keyboard', () => {
    expect(buildUpdateKeyboard({ status: 'UPDATED', text_html: 'x', buttons: [], fetch_head: FH })).toBeUndefined()
    expect(buildUpdateKeyboard({ status: 'PLAN', text_html: 'x' })).toBeUndefined()
  })
  test('unknown actions and a missing/odd fetch_head are dropped', () => {
    expect(buildUpdateKeyboard({ status: 'PLAN', text_html: 'x', buttons: [['rm', 'x']], fetch_head: FH }))
      .toBeUndefined()
    expect(buildUpdateKeyboard({ status: 'PLAN', text_html: 'x', buttons: BUTTONS, fetch_head: 'zz' }))
      .toBeUndefined()
  })
})

describe('parseUpdateCallback', () => {
  test('grammar', () => {
    expect(isUpdateCallback('upd:keep:abc')).toBe(true)
    expect(isUpdateCallback('ord:done:x')).toBe(false)
    expect(parseUpdateCallback(`upd:all:${FH.slice(0, 12)}`)).toEqual({ action: 'all', fh: FH.slice(0, 12) })
    expect(parseUpdateCallback('upd:locked')).toBe('locked')
    expect(parseUpdateCallback('upd:rm:abc')).toBeNull()
    expect(parseUpdateCallback('upd:keep:../x')).toBeNull()
  })
})

interface Recorded {
  calls: string[]
  acks: Array<string | undefined>
  keyboards: Array<Array<Array<{ text: string; callback_data: string }>>>
  sent: string[]
  plannerCalls: string[][]
  restarts: number
}

function setup(
  outcome: PlannerOutcome,
  opts: { fromId?: number | undefined; runtime?: boolean } = {},
): { ctx: (data: string) => UpdateCallbackContext; rec: Recorded; runtime: () => UpdateRuntime | undefined } {
  const rec: Recorded = { calls: [], acks: [], keyboards: [], sent: [], plannerCalls: [], restarts: 0 }
  const ctx = (data: string): UpdateCallbackContext => ({
    data,
    fromId: 'fromId' in opts ? opts.fromId : OWNER,
    answerCallbackQuery: async (text) => { rec.calls.push('ack'); rec.acks.push(text) },
    editReplyMarkup: async (kb) => { rec.calls.push('edit'); rec.keyboards.push(kb) },
    sendMessage: async (html) => { rec.calls.push('send'); rec.sent.push(html) },
  })
  const runtime = (): UpdateRuntime | undefined => opts.runtime === false ? undefined : {
    runPlanner: async (args) => { rec.plannerCalls.push([...args]); return outcome },
    spawnRestart: () => { rec.calls.push('restart'); rec.restarts += 1 },
  }
  return { ctx, rec, runtime }
}

const deps = (runtime: () => UpdateRuntime | undefined) => ({
  allowedUserIds: [OWNER], runtime, log: makeLogger(),
})

describe('handleUpdateCallback', () => {
  const fh = FH.slice(0, 12)

  test('«своё не трогать» → apply keep for exactly that plan, result sent, restart last', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'Обновил. Что нового:' } })
    await handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(s.runtime))
    expect(s.rec.plannerCalls).toEqual([['--expect', fh, 'apply', 'keep']])
    expect(s.rec.sent).toEqual(['Обновил. Что нового:'])
    expect(s.rec.calls.at(-1)).toBe('restart')
    expect(s.rec.calls.indexOf('send')).toBeLessThan(s.rec.calls.indexOf('restart'))
    // the keyboard collapses to one locked button with the result
    const last = s.rec.keyboards.at(-1)!
    expect(last).toHaveLength(1)
    expect(last[0]).toHaveLength(1)
    expect(last[0]![0]!.callback_data).toBe('upd:locked')
    expect(last[0]![0]!.text).toContain('Обновлено')
  })

  test('«даже своё» → apply all; no restart when the planner says so', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: false, text_html: 'ok' } })
    await handleUpdateCallback(s.ctx(`upd:all:${fh}`), deps(s.runtime))
    expect(s.rec.plannerCalls).toEqual([['--expect', fh, 'apply', 'all']])
    expect(s.rec.restarts).toBe(0)
  })

  test('«Не сейчас» → nothing installed, nothing skipped forever, keyboard locked', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', text_html: 'x' } })
    await handleUpdateCallback(s.ctx(`upd:no:${fh}`), deps(s.runtime))
    expect(s.rec.plannerCalls).toHaveLength(0)
    expect(s.rec.sent[0]).toContain('/update')
    expect(s.rec.keyboards.at(-1)![0]![0]!.callback_data).toBe('upd:locked')
  })

  test('stale plan → the planner refusal reaches the owner plainly, keyboard locked', async () => {
    const s = setup({ kind: 'ok', result: { status: 'STALE', restart: false, text_html: STALE } })
    await handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(s.runtime))
    expect(s.rec.sent).toEqual([STALE])
    expect(s.rec.restarts).toBe(0)
    expect(s.rec.keyboards.at(-1)![0]![0]!.callback_data).toBe('upd:locked')
  })

  test('owner-only: a stranger is refused before anything runs', async () => {
    for (const fromId of [42, undefined]) {
      const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'x' } }, { fromId })
      await handleUpdateCallback(s.ctx(`upd:all:${fh}`), deps(s.runtime))
      expect(s.rec.plannerCalls).toHaveLength(0)
      expect(s.rec.keyboards).toHaveLength(0)
      expect(s.rec.sent).toHaveLength(0)
      expect(s.rec.acks).toEqual(['не авторизовано'])
    }
  })

  test('locked / unknown buttons only clear the spinner', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', text_html: 'x' } })
    await handleUpdateCallback(s.ctx('upd:locked'), deps(s.runtime))
    await handleUpdateCallback(s.ctx('upd:rm:abc'), deps(s.runtime))
    expect(s.rec.calls).toEqual(['ack', 'ack'])
  })

  test('planner broke → plain message, no restart', async () => {
    const s = setup({ kind: 'error', detail: 'код 1: Traceback' })
    await handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(s.runtime))
    expect(s.rec.sent[0]).toContain('Не получилось')
    expect(s.rec.sent[0]).not.toContain('Traceback')
    expect(s.rec.restarts).toBe(0)
  })

  test('no update tooling on this server → plain answer, nothing run', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', text_html: 'x' } }, { runtime: false })
    await handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(s.runtime))
    expect(s.rec.plannerCalls).toHaveLength(0)
    expect(s.rec.sent).toHaveLength(1)
  })

  test('a second press while the first is installing does not run twice', async () => {
    let release!: () => void
    const gate = new Promise<void>((r) => { release = r })
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: false, text_html: 'ok' } })
    const slow = (): UpdateRuntime => ({
      runPlanner: async (args) => { s.rec.plannerCalls.push([...args]); await gate; return { kind: 'ok', result: { status: 'UPDATED', text_html: 'ok' } } },
      spawnRestart: () => {},
    })
    const first = handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(slow))
    await handleUpdateCallback(s.ctx(`upd:all:${fh}`), deps(slow))
    release()
    await first
    expect(s.rec.plannerCalls).toHaveLength(1)
  })

  test('out-of-band: only Telegram calls, never the channel / model', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'ok' } })
    await handleUpdateCallback(s.ctx(`upd:keep:${fh}`), deps(s.runtime))
    expect(new Set(s.rec.calls)).toEqual(new Set(['ack', 'edit', 'send', 'restart']))
  })
})

describe('server.ts wiring of upd: presses', () => {
  const src = readFileSync(join(import.meta.dir, '..', '..', 'src', 'server.ts'), 'utf8')
  const start = src.indexOf('if (isUpdateCallback(data))')
  const block = src.slice(start, src.indexOf('\n    return\n  }', start))

  test('dispatched before the permission fallthrough', () => {
    expect(start).toBeGreaterThan(0)
    expect(start).toBeLessThan(src.indexOf('await handlePermissionCallback(adapted'))
  })
  test('the press never emits a channel notification (zero model tokens)', () => {
    expect(block).toContain('handleUpdateCallback(')
    for (const wake of ['sendChannelNotification', 'notifications/claude', 'mcp.notification', 'notifyChannel']) {
      expect(block).not.toContain(wake)
    }
  })
})
