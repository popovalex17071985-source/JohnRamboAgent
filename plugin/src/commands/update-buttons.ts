// /update buttons: the owner answers with a tap, not a typed command.
//
// The planner (scripts/update-plan.py from FETCH_HEAD) decides which buttons a
// plan gets -- only when the update would touch something of the owner's own:
//   keep  «Обновить, своё не трогать»   -> apply keep
//   all   «Обновить всё, даже своё»     -> apply all (copies kept)
//   no    «Не сейчас»                   -> nothing; the next /update asks again
//
// Callback grammar: `upd:<action>:<fetch_head prefix>` and `upd:locked`. The
// prefix goes back to the planner as `--expect`, so a press under an old message
// never installs a newer plan: the planner answers «Обновление уже поменялось».
//
// Out-of-band like /update itself: the plugin runs the planner and talks to
// Telegram directly. Nothing reaches the model -- no channel notification, zero
// AI tokens.

import type { InlineKeyboardLike } from '../channel/tools.js'
import type { PlannerOutcome, PlannerResult } from './update-choice.js'

export const UPDATE_CB_PREFIX = 'upd:'
const LOCKED = 'upd:locked'
const ACTIONS = ['keep', 'all', 'no'] as const
type UpdateAction = (typeof ACTIONS)[number]
const FH_CHARS = 12
const FH_RE = /^[0-9a-f]{7,40}$/
const MAX_LABEL_CHARS = 60

const NOT_NOW_TEXT = 'Хорошо, ничего не ставлю. Захотите обновить — нажмите /update.'
const BROKEN_TEXT =
  'Не получилось поставить обновление, ничего не менял. Нажмите /update ещё раз чуть позже; '
  + 'если повторится — перешлите это тому, кто ставил агента.'
const NO_TOOLING_TEXT =
  'На этом сервере обновление из чата не настроено. Перешлите это тому, кто ставил агента.'

export function isUpdateCallback(data: string): boolean {
  return data.startsWith(UPDATE_CB_PREFIX)
}

function isAction(a: string): a is UpdateAction {
  return (ACTIONS as readonly string[]).includes(a)
}

/** Inline keyboard for a planner answer; undefined = a plain message. */
export function buildUpdateKeyboard(result: PlannerResult): InlineKeyboardLike | undefined {
  const fh = (result.fetch_head ?? '').toLowerCase()
  if (!FH_RE.test(fh) || !result.buttons) return undefined
  const rows = result.buttons
    .filter(([action, label]) => isAction(action) && label.length > 0)
    .map(([action, label]) => [{
      text: label.slice(0, MAX_LABEL_CHARS),
      callback_data: `${UPDATE_CB_PREFIX}${action}:${fh.slice(0, FH_CHARS)}`,
    }])
  return rows.length > 0 ? { inline_keyboard: rows } : undefined
}

export function parseUpdateCallback(data: string): { action: UpdateAction; fh: string } | 'locked' | null {
  if (data === LOCKED) return 'locked'
  const m = /^upd:([a-z]+):([0-9a-f]{7,40})$/.exec(data)
  if (!m || !isAction(m[1]!)) return null
  return { action: m[1] as UpdateAction, fh: m[2]! }
}

export interface UpdateButton {
  text: string
  callback_data: string
}

/** Structural subset of the grammY callback context this handler needs. */
export interface UpdateCallbackContext {
  data: string
  fromId: number | undefined
  answerCallbackQuery: (text?: string) => Promise<void>
  /** Replace the message's keyboard (collapse to one locked button). */
  editReplyMarkup: (keyboard: UpdateButton[][]) => Promise<void>
  /** A new message (HTML) in the chat of the press. */
  sendMessage: (html: string) => Promise<void>
}

export interface UpdateRuntime {
  runPlanner: (args: readonly string[]) => Promise<PlannerOutcome>
  spawnRestart: () => void
}

export interface UpdateCallbackDeps {
  allowedUserIds: readonly number[]
  /** Planner + restart of this agent; undefined when the server has no ctl. */
  runtime: () => UpdateRuntime | undefined
  log: {
    info: (m: string, ctx?: Record<string, unknown>) => void
    warn: (m: string, ctx?: Record<string, unknown>) => void
  }
}

// One install at a time per process: a second tap while the first runs
// (bun install takes minutes) must not start a parallel reset.
let installing = false

function locked(text: string): UpdateButton[][] {
  return [[{ text, callback_data: LOCKED }]]
}

async function quiet(p: Promise<void>, deps: UpdateCallbackDeps, what: string): Promise<void> {
  try {
    await p
  } catch (err) {
    deps.log.warn(`update-buttons: ${what} failed`, {
      error: err instanceof Error ? err.message : String(err),
    })
  }
}

/** Handle one `upd:*` press. Never throws; the spinner is always cleared. */
export async function handleUpdateCallback(ctx: UpdateCallbackContext, deps: UpdateCallbackDeps): Promise<void> {
  // AUTH FIRST: the same allowlist that gates the /update command.
  if (typeof ctx.fromId !== 'number' || !deps.allowedUserIds.includes(ctx.fromId)) {
    deps.log.warn('update-buttons: unauthorized press', { user_id: ctx.fromId, data: ctx.data })
    await quiet(ctx.answerCallbackQuery('не авторизовано'), deps, 'ack')
    return
  }
  const parsed = parseUpdateCallback(ctx.data)
  if (parsed === null || parsed === 'locked') {
    await quiet(ctx.answerCallbackQuery(), deps, 'ack')
    return
  }
  if (parsed.action === 'no') {
    await quiet(ctx.answerCallbackQuery(), deps, 'ack')
    await quiet(ctx.editReplyMarkup(locked('Не сейчас — ничего не ставил')), deps, 'edit')
    await quiet(ctx.sendMessage(NOT_NOW_TEXT), deps, 'send')
    return
  }
  if (installing) {
    await quiet(ctx.answerCallbackQuery('Уже ставлю, подождите'), deps, 'ack')
    return
  }
  const runtime = deps.runtime()
  if (runtime === undefined) {
    await quiet(ctx.answerCallbackQuery(), deps, 'ack')
    await quiet(ctx.sendMessage(NO_TOOLING_TEXT), deps, 'send')
    return
  }
  installing = true
  try {
    await quiet(ctx.answerCallbackQuery('Ставлю…'), deps, 'ack')
    await quiet(ctx.editReplyMarkup(locked('Ставлю…')), deps, 'edit')
    deps.log.info('update-buttons: apply', { action: parsed.action })
    const outcome = await runtime.runPlanner(['--expect', parsed.fh, 'apply', parsed.action])
    if (outcome.kind !== 'ok') {
      deps.log.warn('update-buttons: planner failed', {
        kind: outcome.kind,
        ...(outcome.kind === 'error' ? { detail: outcome.detail } : { reason: outcome.reason }),
        ...(outcome.kind === 'error' && outcome.stderr !== undefined ? { stderr: outcome.stderr } : {}),
      })
      await quiet(ctx.editReplyMarkup(locked('Не получилось')), deps, 'edit')
      await quiet(ctx.sendMessage(BROKEN_TEXT), deps, 'send')
      return
    }
    const { status, text_html: text, restart } = outcome.result
    const label = status === 'UPDATED' ? 'Обновлено'
      : status === 'STALE' ? 'Устарело'
      : status === 'NOTHING' ? 'Нечего ставить'
      : 'Не получилось'
    await quiet(ctx.editReplyMarkup(locked(label)), deps, 'edit')
    await quiet(ctx.sendMessage(text), deps, 'send')
    // Restart last: the result has left before the link blinks.
    if (restart === true) runtime.spawnRestart()
  } finally {
    installing = false
  }
}
