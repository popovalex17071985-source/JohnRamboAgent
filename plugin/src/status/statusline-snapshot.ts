// Statusline snapshot — the JSON Claude Code hands its `statusLine` command.
//
// Claude Code pipes a JSON document into the configured status-line command on
// every UI refresh. Two facts in it exist nowhere else the HUD can read:
//   - `context_window.context_window_size` — the REAL window of this session
//     (the model table guesses; it said 200k for a 1M Opus 5.5 session);
//   - `rate_limits.five_hour` / `rate_limits.seven_day` — subscription limit
//     usage (`used_percentage`, `resets_at` in epoch seconds).
// `scripts/statusline-capture.sh` writes that JSON to a file; this module reads
// it back for the pinned HUD (operator 09.10.2026: «в закреп такую штуку»).
//
// Everything here is best-effort: a missing, stale, foreign-session or malformed
// file yields null and the HUD renders exactly as before.

import { readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const DEFAULT_STATUSLINE_FILE = join(homedir(), '.claude', 'dashi-statusline.json')
// The status line refreshes at least every `refreshInterval` seconds while the
// session is up; older than this means the session (or the capture) is gone.
export const STATUSLINE_MAX_AGE_MS = 15 * 60 * 1000

const FIVE_HOURS_S = 5 * 3600
const SEVEN_DAYS_S = 7 * 24 * 3600

export interface RateLimitWindow {
  usedPct: number
  resetsAt: number // epoch seconds
}

export interface StatuslineSnapshot {
  windowTokens?: number
  fiveHour?: RateLimitWindow
  sevenDay?: RateLimitWindow
}

function num(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined
}

function limitWindow(v: unknown): RateLimitWindow | undefined {
  if (v === null || typeof v !== 'object') return undefined
  const o = v as Record<string, unknown>
  const usedPct = num(o.used_percentage)
  const resetsAt = num(o.resets_at)
  if (usedPct === undefined || resetsAt === undefined) return undefined
  return { usedPct, resetsAt }
}

/**
 * Parse a statusline JSON document. PURE. `transcriptPath`, when both sides
 * know it, must match — another Claude session on the same host writes the
 * same file, and its numbers must not land in this chat's pin.
 */
export function parseStatusline(raw: string, transcriptPath?: string): StatuslineSnapshot | null {
  let doc: unknown
  try {
    doc = JSON.parse(raw)
  } catch {
    return null
  }
  if (doc === null || typeof doc !== 'object') return null
  const d = doc as Record<string, unknown>
  const docTranscript = typeof d.transcript_path === 'string' ? d.transcript_path : undefined
  if (transcriptPath !== undefined && docTranscript !== transcriptPath) {
    return null
  }
  const out: StatuslineSnapshot = {}
  const cw = d.context_window
  if (cw !== null && typeof cw === 'object') {
    const size = num((cw as Record<string, unknown>).context_window_size)
    if (size !== undefined && size > 0) out.windowTokens = Math.round(size)
  }
  // Auto-compact fires before the model window is full (operator runs 400k on a
  // 1M model): the bar must fill up to where the context actually gets cut.
  const compact = num(d.dashi_autocompact_window)
  if (compact !== undefined && compact > 0 && (out.windowTokens === undefined || compact < out.windowTokens)) {
    out.windowTokens = Math.round(compact)
  }
  const rl = d.rate_limits
  if (rl !== null && typeof rl === 'object') {
    const r = rl as Record<string, unknown>
    const five = limitWindow(r.five_hour)
    const seven = limitWindow(r.seven_day)
    if (five !== undefined) out.fiveHour = five
    if (seven !== undefined) out.sevenDay = seven
  }
  return out.windowTokens === undefined && out.fiveHour === undefined && out.sevenDay === undefined
    ? null
    : out
}

/**
 * Read + parse the snapshot file; null when absent, stale or unusable. Needs
 * the chat's transcript path: without it there is no proof the file belongs to
 * this session rather than another one on the host.
 */
export function readStatusline(
  path: string,
  transcriptPath: string | undefined,
  nowMs: number,
): StatuslineSnapshot | null {
  if (transcriptPath === undefined || transcriptPath.length === 0) return null
  try {
    if (nowMs - statSync(path).mtimeMs > STATUSLINE_MAX_AGE_MS) return null
    return parseStatusline(readFileSync(path, 'utf8'), transcriptPath)
  } catch {
    return null
  }
}

function fmtReset(resetsAt: number, nowMs: number, timeZone: string, withDay: boolean): string {
  const d = new Date(resetsAt * 1000)
  const opts: Intl.DateTimeFormatOptions = { timeZone, hour: '2-digit', minute: '2-digit', hour12: false }
  if (withDay && resetsAt * 1000 - nowMs > 20 * 3600 * 1000) {
    opts.weekday = 'short'
    opts.day = 'numeric'
    opts.month = '2-digit'
  }
  try {
    return new Intl.DateTimeFormat('ru-RU', opts).format(d)
  } catch {
    return new Intl.DateTimeFormat('ru-RU', { ...opts, timeZone: 'UTC' }).format(d) + ' UTC'
  }
}

function limitLine(
  label: string,
  w: RateLimitWindow,
  periodS: number,
  nowMs: number,
  timeZone: string,
  withDay: boolean,
): string {
  const used = Math.max(0, Math.min(100, Math.round(w.usedPct)))
  // Pace: the share of the window already elapsed is what an even burn would
  // have used by now. Above it = spending faster than the limit allows.
  const leftS = Math.max(0, w.resetsAt - nowMs / 1000)
  const elapsed = Math.max(0, Math.min(1, (periodS - leftS) / periodS))
  const pace = Math.round(elapsed * 100)
  const reset = fmtReset(w.resetsAt, nowMs, timeZone, withDay)
  return `${label}: ${used}% (норма ${pace}%) · сброс ${reset}`
}

/**
 * Rate-limit lines for the HUD, already HTML-safe (digits and fixed words only).
 * PURE given `nowMs`. Empty string when the snapshot has no limits.
 */
export function renderRateLimits(
  snap: StatuslineSnapshot | null,
  nowMs: number,
  timeZone: string,
): string {
  if (snap === null) return ''
  const lines: string[] = []
  if (snap.fiveHour !== undefined) {
    lines.push(limitLine('⏱ <b>Лимит 5 ч</b>', snap.fiveHour, FIVE_HOURS_S, nowMs, timeZone, false))
  }
  if (snap.sevenDay !== undefined) {
    lines.push(limitLine('📅 <b>Неделя</b>', snap.sevenDay, SEVEN_DAYS_S, nowMs, timeZone, true))
  }
  return lines.join('\n')
}
