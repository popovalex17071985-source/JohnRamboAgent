import { describe, expect, test } from 'bun:test'
import { mkdtempSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { parseStatusline, readStatusline, renderRateLimits } from '../../src/status/statusline-snapshot.js'
import { renderHud } from '../../src/status/context-hud.js'

const T = '/home/x/.claude/projects/p/s1.jsonl'
// 2026-10-09 03:00:00 UTC = 08:00 Perm
const NOW = Date.UTC(2026, 9, 9, 3, 0, 0)
const doc = (over: Record<string, unknown> = {}) => JSON.stringify({
  transcript_path: T,
  context_window: { context_window_size: 1_000_000, used_percentage: 18 },
  rate_limits: {
    five_hour: { used_percentage: 40, resets_at: NOW / 1000 + 2.5 * 3600 },
    seven_day: { used_percentage: 33, resets_at: NOW / 1000 + 3.5 * 24 * 3600 },
  },
  ...over,
})

describe('statusline snapshot', () => {
  test('parses window and both limits', () => {
    const s = parseStatusline(doc(), T)
    expect(s?.windowTokens).toBe(1_000_000)
    expect(s?.fiveHour?.usedPct).toBe(40)
    expect(s?.sevenDay?.usedPct).toBe(33)
  })

  test('auto-compact window caps the model window', () => {
    expect(parseStatusline(doc({ dashi_autocompact_window: 400_000 }), T)?.windowTokens).toBe(400_000)
    expect(parseStatusline(doc({ dashi_autocompact_window: 2_000_000 }), T)?.windowTokens).toBe(1_000_000)
  })

  test('another session, garbage or empty doc -> null', () => {
    expect(parseStatusline(doc(), '/other.jsonl')).toBeNull()
    expect(parseStatusline('{not json', T)).toBeNull()
    expect(parseStatusline(JSON.stringify({ transcript_path: T }), T)).toBeNull()
  })

  test('limit lines: pace and reset in the operator zone', () => {
    const txt = renderRateLimits(parseStatusline(doc(), T), NOW, 'Asia/Yekaterinburg')
    // 5h window, 2.5h left -> half elapsed -> pace 50%; reset 05:30 UTC = 10:30 Perm
    expect(txt).toContain('Лимит 5 ч</b>: 40% (норма 50%) · сброс 10:30')
    // 7d window, 3.5d left -> pace 50%; reset far away -> shows the day too
    expect(txt).toMatch(/Неделя<\/b>: 33% \(норма 50%\) · сброс .*\d{2}:\d{2}/)
    expect(renderRateLimits(null, NOW, 'Asia/Yekaterinburg')).toBe('')
  })

  test('file reader: needs transcript, rejects stale', () => {
    const dir = mkdtempSync(join(tmpdir(), 'sl-'))
    const f = join(dir, 's.json')
    writeFileSync(f, doc())
    expect(readStatusline(f, undefined, Date.now())).toBeNull()
    expect(readStatusline(f, T, Date.now())?.windowTokens).toBe(1_000_000)
    const old = (Date.now() - 60 * 60 * 1000) / 1000
    utimesSync(f, old, old)
    expect(readStatusline(f, T, Date.now())).toBeNull()
    expect(readStatusline(join(dir, 'missing.json'), T, Date.now())).toBeNull()
  })

  test('HUD puts the limits right under the context line', () => {
    const { text } = renderHud({ usedTokens: 180_000 }, 1_000_000, 'claude-opus-5-5', undefined, undefined,
      '⏱ <b>Лимит 5 ч</b>: 40%')
    const lines = text.split('\n')
    expect(lines[0]).toContain('18% (180k / 1M)')
    expect(lines[1]).toBe('⏱ <b>Лимит 5 ч</b>: 40%')
  })
})
