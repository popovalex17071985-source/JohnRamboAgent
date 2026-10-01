// Out-of-band (OOB) commands handled by the plugin BEFORE a channel
// notification is sent to Claude.
//
// Control commands: /help, /status, /stop, /compact, /new, /mirror, /keys, /cc.
// The session-driving controls (/stop, /compact, /new-confirm, /cc, /keys) act
// on the agent's tmux pane through the RELIABLE injection layer in keys.ts
// (probe → optionally interrupt → send → confirm), never a blind Enter.
// Still NOT a command: /halt.
//
// Parsing rules:
//   - Must start with `/`.
//   - Optional `@botname` suffix is stripped when it matches our bot's
//     username (case-insensitive).
//   - Command word is lowercased.
//   - Trailing `force` token in args sets hasForceFlag (legacy; unused by the
//     current commands but preserved for source-compat).
//
// Handling notes:
//   - /help and /status reply directly to Telegram and DO NOT wake Claude
//     (no channel notification).
//   - /compact injects Claude Code's own /compact into the pane via
//     sendControlCommand and reports the REAL result (ok/busy/dialog/…).
//   - /new is one-tap-with-confirm: a bare /new posts a confirmation card;
//     the tap (newq: callback in server.ts) runs the destructive /clear.
//   - /stop sends Escape (interrupt) into the pane; falls back to a channel
//     signal when no pane is resolvable.

import { spawn, execFile } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'
import type { TelegramApi, InlineKeyboardLike } from '../channel/tools.js'
import { sendChannelNotification, type ChannelEvent } from '../channel/notify.js'
import type { Server } from '@modelcontextprotocol/sdk/server/index.js'
import {
  capturePane,
  classifyPane,
  parseCcCommand,
  sendSlashCommand,
  sendNamedKey,
  sendControlCommand,
  type ControlCommandOpts,
  type KeysCaptureExec,
  type KeysExec,
  type TmuxKeysTarget,
} from './keys.js'
import {
  reloginPendingRemainingMs,
  runReloginFlow,
  type ReloginIo,
} from './relogin.js'
import { buildKeysKeyboard, KEYS_PANEL_HEADER } from '../telegram/keys-panel-ui.js'
import { buildCcKeyboard, CC_PANEL_HEADER } from '../telegram/cc-panel-ui.js'
import { buildNewConfirmCard } from '../telegram/newq-confirm-ui.js'
import { controlFailureMessage } from '../telegram/control-result.js'
import { readContextUsage, formatContextUsage } from '../status/context-usage.js'
import { DEFAULT_CONTEXT_WINDOW_TOKENS, resolveContextWindowForModel } from '../config.js'
import {
  activeLeases,
  humanizeDurationMs,
  loadAutonomyState,
  type AutonomyPaths,
} from '../autonomy/store.js'
import { grantLease, parseLeaseCommandArgs } from '../autonomy/grant.js'

export type OobCommandName =
  | 'help'
  | 'status'
  | 'stop'
  | 'compact'
  | 'new'
  | 'mirror'
  | 'keys'
  | 'cc'
  | 'relogin'
  | 'restart'
  | 'update'
  | 'lease'

const KNOWN_COMMANDS = new Set<OobCommandName>([
  'help',
  'status',
  'stop',
  'compact',
  'new',
  'mirror',
  'keys',
  'cc',
  'relogin',
  'restart',
  'update',
  'lease',
])

// Sub-actions for /mirror. We accept the bare command (= same as `status`),
// plus on/off/status explicit args. Unknown sub-actions render the help line.
export type MirrorAction = 'on' | 'off' | 'status'

export interface ParsedOobCommand {
  name: OobCommandName
  rawText: string
  args: string
  hasForceFlag: boolean
}

// Parse a leading `/cmd[@botname] args...` token. Returns null if the text
// is not an OOB command (plain text, unknown command, no leading slash).
export function parseOobCommand(
  text: string,
  botUsername?: string,
): ParsedOobCommand | null {
  if (typeof text !== 'string' || text.length === 0) return null
  const trimmed = text.replace(/^\s+/, '')
  if (!trimmed.startsWith('/')) return null

  // Split on first whitespace run. parts[0] = "/word[@bot]", rest = args.
  const wsIdx = trimmed.search(/\s/)
  const head = wsIdx === -1 ? trimmed : trimmed.slice(0, wsIdx)
  const args = wsIdx === -1 ? '' : trimmed.slice(wsIdx + 1).trim()

  // Strip leading slash, optional @botname suffix.
  let word = head.slice(1)
  const atIdx = word.indexOf('@')
  if (atIdx !== -1) {
    const suffix = word.slice(atIdx + 1)
    word = word.slice(0, atIdx)
    // gateway.py strips ANY @suffix without verifying the bot identity, so we
    // mirror that here. botUsername is accepted for future tightening, but
    // not enforced — stripping any suffix matches gateway.py:3044-3045.
    void suffix
    void botUsername
  }

  const lower = word.toLowerCase() as OobCommandName
  if (!KNOWN_COMMANDS.has(lower)) return null

  const hasForceFlag = /^\s*force\s*$/i.test(args)

  return {
    name: lower,
    rawText: text,
    args,
    hasForceFlag,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Handler context and result shape.
// ─────────────────────────────────────────────────────────────────────

// Minimal surface of TmuxMirror that the OOB layer needs. Decoupled from
// the concrete class so tests don't need to spin up the full mirror.
//
// `bump` is optional because it's used by the inbound-message handler
// (not by /mirror commands) — keeping it optional avoids forcing every
// OOB unit test to stub a method it never exercises.
export interface TmuxMirrorControl {
  start(): Promise<void>
  stop(): Promise<void>
  bump?(): Promise<void>
  // MED-A #2: recovery from a permanent Telegram error (403 / parse)
  // that flipped `disabled=true`. /mirror on calls reset() before
  // start() so the warchief never has to restart the plugin.
  // Optional for source-compat with existing test stubs.
  reset?(): void
  status(): {
    enabled: boolean
    messageId?: number
    lastError?: string
    lastPollAt?: number
  }
}

export interface OobContext {
  chatId: string
  senderId: string
  config: AppConfig
  telegramApi: TelegramApi
  log: Logger
  // For /status, pulled lazily so handler stays decoupled from the
  // status manager (T11) and poller/webhook plumbing (T13).
  pollerStatus?: () => { offset: number | undefined; lastError?: string }
  statusManager?: {
    isActive: (chatId: string) => boolean
    cancel: (chatId: string, reason: string) => Promise<void>
  }
  webhookStatus?: () => { enabled: boolean; port: number }
  // /mirror control — undefined when tmux_mirror.enabled=false at startup.
  // The handler then replies «mirror disabled in config».
  tmuxMirror?: TmuxMirrorControl
  // /keys target — the pane of the agent's Claude session. Undefined when the
  // plugin can't resolve a pane (no tmux config); the handler then explains.
  // `exec` (send-keys) / `captureExec` (capture-pane) / `sleep` are test-only
  // injection seams — production wires only `target`, so /compact drives the
  // real tmux through sendControlCommand's own defaults.
  tmuxKeys?: {
    target: TmuxKeysTarget
    exec?: KeysExec
    captureExec?: KeysCaptureExec
    sleep?: (ms: number) => Promise<void>
  }
  // Identity bits surfaced by /status.
  botId?: number
  stateDir?: string
  // Context-usage bits for /status (task 5). transcriptPath comes from the
  // SessionInfoStore (latest hook event); modelName from a SessionStart hook;
  // contextWindowTokens from config (resolveContextWindowTokens — the resolved
  // override-or-default, used as the FALLBACK denominator). All optional — when
  // transcriptPath is absent /status shows «контекст: —».
  transcriptPath?: string
  modelName?: string
  contextWindowTokens?: number
  // The EXPLICIT operator override (resolveContextWindowOverride), passed
  // SEPARATELY from contextWindowTokens so /status can resolve the window
  // model-aware (transcript model → 1M for Fable) exactly like the pinned HUD:
  // override wins, else the transcript model's table window, else the fallback.
  // Undefined when no operator override is configured.
  contextWindowOverride?: number
  // The hosting Claude Code process's `--model` flag (readLaunchModelId). Some
  // 1M variants are served under a BARE transcript id (`claude-opus-5` from
  // `--model claude-opus-5[1m]`), so this is the only surviving proof of the
  // window. Undefined when the flag could not be read.
  launchModel?: string
  // Process uptime in seconds (process.uptime()); rendered when present.
  uptimeSeconds?: number
  // /restart test seams. Production leaves this undefined and the handler
  // falls back to process.env.AGENT_ID / fs.existsSync / a real detached
  // spawn — tests inject all three to avoid touching the host system.
  restart?: {
    agentId?: string
    fileExists?: (path: string) => boolean
    spawnDetached?: (cmd: string, args: readonly string[]) => void
    // /update: runs `sudo -n <ctl> update [force]` and returns its status
    // line (see install-agent.sh ctl template). Tests inject a fake.
    runCtl?: (ctl: string, args: readonly string[]) => Promise<{ code: number; out: string }>
  }
  // Autonomy M2: inbound message id, used to build the idempotent grantSourceId
  // (`cmd:<chatId>:<messageId>`) for /lease so a replayed command mints one
  // lease. Undefined → the grant falls back to a time-based source id.
  messageId?: number
}

export interface OobResult {
  handled: true
  command: OobCommandName
  notifyChannel?: { content: string; meta: Record<string, string> }
  // `inlineKeyboard` (optional, additive) attaches a reply_markup keypad to
  // the Telegram reply — used by /keys to render the tap panel. Mirrors how
  // the permission gate sends its Allow/Deny keyboard. Existing replies omit
  // it and Telegram sends a plain message.
  replyToTelegram?: { text: string; parseMode?: 'HTML'; inlineKeyboard?: InlineKeyboardLike }
}

// ─────────────────────────────────────────────────────────────────────
// /help text. Lists the control commands. /halt is intentionally absent.
// ─────────────────────────────────────────────────────────────────────

function helpText(): string {
  return (
    '<b>команды</b>\n\n'
    + '<code>/help</code> — эта справка\n'
    + '<code>/status</code> — снимок плагина и сессии (+ расход контекста)\n'
    + '<code>/stop</code> — прервать текущую задачу (Escape в сессию)\n'
    + '<code>/compact</code> — сжать контекст сессии\n'
    + '<code>/new</code> — начать новый диалог (очистит контекст — спросит подтверждение)\n'
    + '<code>/mirror on|off|status</code> — управлять зеркалом терминала (tmux, обновляется в реальном времени)\n'
    + '<code>/keys</code> — панель кнопок: тап = нажатие в сессии (ответить на нативный диалог Claude Code; есть ⌫ backspace и 🧹 clear)\n'
    + '<code>/cc</code> — панель команд Claude Code (тап = выполнить); либо <code>/cc &lt;команда&gt;</code>: <code>/cc model opus</code>\n'
    + '<code>/relogin</code> — обновить вход в Claude: пришлю ссылку, потом жду код сюда\n'
    + '<code>/restart</code> — перезапустить мост (systemd, связь моргнёт)\n'
    + '<code>/update</code> — обновить мост до свежей версии (бэкап, откат при сбое, рестарт)\n'
    + '<code>/lease &lt;scope&gt;</code> — выдать мандат автономии (напр. <code>/lease деплой стейджинга; ttl=48h</code>); без аргумента — список активных\n\n'
    + '<i>примечание: /stop — best-effort: посылает Escape в сессию, но не может '
    + 'гарантировать прерывание посреди вызова инструмента.</i>'
  )
}

// Public so server.ts can feed the SAME list to bot.api.setMyCommands and
// Telegram autocomplete stays in sync with what the parser actually accepts.
// Technical commands (mirror, keys, cc, lease) are deliberately left out of the
// menu -- the owner never uses them; they still parse when typed.
export interface BotCommandSpec {
  command: string
  description: string
}
export const BOT_COMMANDS: ReadonlyArray<BotCommandSpec> = [
  { command: 'help', description: 'справка по командам' },
  { command: 'status', description: 'снимок плагина и сессии' },
  { command: 'stop', description: 'прервать текущую задачу' },
  { command: 'compact', description: 'сжать контекст сессии' },
  { command: 'new', description: 'новый диалог (очистит контекст, с подтверждением)' },
  { command: 'relogin', description: 'обновить вход в Claude (ссылка + код)' },
  { command: 'restart', description: 'перезапустить мост (systemd)' },
  { command: 'update', description: 'обновить мост до свежей версии' },
]

// ponytail: Jarvis-specific paths hardcoded — this is Jarvis's own fork, not
// the generic upstream plugin. If reused elsewhere, lift to config/env.
const JARVIS_CORE = '/home/edgelab/.claude-lab/jarvis/.claude/core'
const CTX_WINDOW = 400_000 // CLAUDE_CODE_AUTO_COMPACT_WINDOW
// OpenViking auto-memory index — the MEMORY.md actually injected into context.
const MEM_INDEX =
  '/home/edgelab/.claude/projects/-home-edgelab--claude-lab-jarvis--claude-dashi-plugin-claude-code/memory/MEMORY.md'

// Format process uptime seconds as a compact human string (e.g. `2h 15m`).
function formatUptime(sec: number): string {
  const s = Math.max(0, Math.floor(sec))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  if (h > 0) return `${h}h ${m}m`
  const secs = s % 60
  return m > 0 ? `${m}m ${secs}s` : `${secs}s`
}

function kb(bytes: number): string {
  return bytes < 1024 ? `${bytes} Б` : `${(bytes / 1024).toFixed(1)} КБ`
}

// usage-logger writes `window` = the last sub-request's exact context fill. Old
// rows lack it (pre-2026-06-22); for those, approximate by dividing the per-turn
// aggregate (which sums cache_read across all num_turns sub-requests) back out.
function contextFill(): number | undefined {
  try {
    const raw = readFileSync(`${JARVIS_CORE}/usage.jsonl`, 'utf8').trimEnd()
    const last = raw.slice(raw.lastIndexOf('\n') + 1)
    const r = JSON.parse(last) as {
      input?: number; cache_read?: number; cache_creation?: number
      num_turns?: number; window?: number
    }
    if (r.window) return r.window
    const turns = Math.max(r.num_turns ?? 1, 1)
    return Math.round(((r.input ?? 0) + (r.cache_read ?? 0) + (r.cache_creation ?? 0)) / turns)
  } catch {
    return undefined
  }
}

function fileStat(path: string): { bytes: number; entries: number } | undefined {
  try {
    const txt = readFileSync(path, 'utf8')
    return { bytes: Buffer.byteLength(txt, 'utf8'), entries: (txt.match(/^### /gm) ?? []).length }
  } catch {
    return undefined
  }
}

// Async because it reads the session transcript tail for context usage (task 5).
// The transcript read is bounded (~256 KB tail) and never throws — a null
// usage renders «контекст: —».
async function statusText(ctx: OobContext): Promise<string> {
  const lines: string[] = ['<b>статус</b>']
  if (ctx.botId !== undefined) {
    lines.push(`bot_id: <code>${escapeHtml(String(ctx.botId))}</code>`)
  }
  if (ctx.stateDir) {
    lines.push(`state_dir: <code>${escapeHtml(ctx.stateDir)}</code>`)
  }
  lines.push(`allowed_user: <code>${escapeHtml(ctx.senderId)}</code>`)

  if (ctx.pollerStatus) {
    const ps = ctx.pollerStatus()
    const off = ps.offset === undefined ? '—' : String(ps.offset)
    lines.push(`update_offset: <code>${escapeHtml(off)}</code>`)
    if (ps.lastError) {
      lines.push(`poller_error: <code>${escapeHtml(ps.lastError)}</code>`)
    }
  }

  if (ctx.statusManager) {
    const active = ctx.statusManager.isActive(ctx.chatId) ? 'active' : 'idle'
    lines.push(`status_manager: <code>${active}</code>`)
  }

  if (ctx.webhookStatus) {
    const ws = ctx.webhookStatus()
    const w = ws.enabled ? `on:${ws.port}` : 'off'
    lines.push(`webhook: <code>${w}</code>`)
  }

  // Jarvis memory snapshot — recent.md/handoff.md sizes plus the MEMORY.md
  // that is ACTUALLY auto-loaded into every session's context (the OpenViking
  // index), not core/MEMORY.md (the cold-memory pointer, NOT in context).
  // 2026-06-24 fix: showing the in-context file is the one that matters.
  const fill = contextFill()
  if (fill !== undefined) {
    const pct = Math.round((fill / CTX_WINDOW) * 100)
    const flag = pct >= 80 ? ' ⚠️' : ''
    lines.push(`usage.jsonl контекст: ~${Math.round(fill / 1000)}k / ${CTX_WINDOW / 1000}k (${pct}%)${flag}`)
  }
  const recent = fileStat(`${JARVIS_CORE}/hot/recent.md`)
  if (recent) lines.push(`recent.md: ${recent.entries} записей, ${kb(recent.bytes)}`)
  const handoff = fileStat(`${JARVIS_CORE}/hot/handoff.md`)
  if (handoff) lines.push(`handoff.md: ${kb(handoff.bytes)} (последние 5)`)
  const mem = fileStat(MEM_INDEX)
  if (mem) lines.push(`MEMORY.md (в контексте): ${kb(mem.bytes)}`)

  if (ctx.modelName) {
    lines.push(`model: <code>${escapeHtml(ctx.modelName)}</code>`)
  }

  // Context usage — read the transcript tail when we have a path. `usage` is
  // null on any read failure / no usable turn → render «—». The window passed
  // to readContextUsage only seeds usage.pct (which formatContextUsage
  // recomputes), so a provisional fallback here is safe — the DISPLAYED
  // denominator is resolved model-aware below, matching the pinned HUD.
  const fallbackWindow = ctx.contextWindowTokens ?? DEFAULT_CONTEXT_WINDOW_TOKENS
  let contextLine = '—'
  if (ctx.transcriptPath) {
    const usage = await readContextUsage(ctx.transcriptPath, fallbackWindow)
    if (usage) {
      // Same precedence as ContextHud: explicit override > transcript model
      // (usage.model) > fallback. So a Fable session reports its 1M window here
      // instead of the 200k default — /status and the HUD agree.
      const windowTokens = resolveContextWindowForModel(usage.model, {
        override: ctx.contextWindowOverride,
        fallback: fallbackWindow,
        launchModel: ctx.launchModel,
      })
      contextLine = formatContextUsage(usage, windowTokens)
    }
  }
  lines.push(`контекст: <code>${escapeHtml(contextLine)}</code>`)

  if (ctx.uptimeSeconds !== undefined) {
    lines.push(`uptime: <code>${escapeHtml(formatUptime(ctx.uptimeSeconds))}</code>`)
  }

  return lines.join('\n')
}

function escapeHtml(s: string): string {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
}

// ─────────────────────────────────────────────────────────────────────
// /lease — autonomy M2 owner command. Grants a lease (or lists active ones
// on a bare command). The store write happens HERE (async side effect),
// then the confirmation is returned as a normal replyToTelegram. The message
// is NOT forwarded to the agent session (OOB commands are swallowed in
// handlers.ts) — it is a control command, not conversation.
// ─────────────────────────────────────────────────────────────────────

async function handleLeaseCommand(
  parsed: ParsedOobCommand,
  ctx: OobContext,
): Promise<OobResult> {
  if (ctx.stateDir === undefined) {
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: '<b>/lease</b> — недоступно: не сконфигурирован каталог состояния.',
        parseMode: 'HTML',
      },
    }
  }
  const paths: AutonomyPaths = { root: ctx.stateDir }
  const cmd = parseLeaseCommandArgs(parsed.args)

  if (cmd.kind === 'bare') {
    // No scope → list active leases + usage hint, grant nothing.
    const state = loadAutonomyState(paths, ctx.chatId, ctx.log)
    const leases = activeLeases(state, Date.now())
    const lines: string[] = ['<b>активные мандаты</b>']
    if (leases.length === 0) {
      lines.push('нет активных мандатов.')
    } else {
      for (const l of leases) {
        const left = humanizeDurationMs(l.expiresAtMs - Date.now())
        lines.push(`<code>${escapeHtml(l.id)}</code> — «${escapeHtml(l.scope)}» (ещё ${escapeHtml(left)})`)
      }
    }
    lines.push('', '<i>usage: /lease &lt;scope&gt;[; ttl=48h]</i>')
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: { text: lines.join('\n'), parseMode: 'HTML' },
    }
  }

  // Fail-closed grammar errors (fix-loop #3/#6/#8): a present-but-malformed
  // trailing ttl option or an over-long scope is a USAGE ERROR — nothing is
  // granted, nothing is silently defaulted or truncated.
  if (cmd.kind === 'invalid') {
    const reason = cmd.reason === 'ttl'
      ? 'некорректный ttl — допустимо целое 1..72 в форме <code>ttl=48h</code> (строго строчными)'
      : cmd.reason === 'scope_charset'
        ? 'scope содержит управляющие/форматирующие символы (перенос строки, bidi) — недопустимо'
        : 'scope длиннее 400 символов — сократи формулировку'
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: `<b>/lease</b> — ${reason}.\n<i>usage: /lease &lt;scope&gt;[; ttl=48h]</i>`,
        parseMode: 'HTML',
      },
    }
  }

  // Grant. Idempotency key ties a replayed /lease command to one lease.
  const grantSourceId = `cmd:${ctx.chatId}:${ctx.messageId ?? Date.now()}`
  const res = await grantLease(
    paths,
    ctx.chatId,
    {
      scope: cmd.scope,
      ttlHours: cmd.ttlHours,
      source: 'owner_cmd',
      grantSourceId,
    },
    ctx.log,
  )

  if (res.kind === 'writer_conflict') {
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: '<b>/lease</b> — реестр занят другим процессом, попробуй ещё раз.',
        parseMode: 'HTML',
      },
    }
  }
  if (res.kind === 'version_unsupported') {
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: '<b>/lease</b> — реестр новее этой версии плагина (только чтение). Обнови плагин.',
        parseMode: 'HTML',
      },
    }
  }

  const lease = res.lease
  ctx.log.info('oob /lease grant', {
    chat_id: ctx.chatId,
    outcome: res.outcome,
    lease_id: lease?.id,
  })

  // Honest refusal on a source-id collision with a DIFFERENT scope
  // (fix-loop #2, Fable): never silently swallow a legit grant.
  if (res.outcome === 'source_conflict') {
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: '<b>мандат НЕ выдан</b> — этот запрос уже обрабатывался с ДРУГИМ scope (source_conflict). Отправь команду новым сообщением.',
        parseMode: 'HTML',
      },
    }
  }

  if (lease === undefined) {
    // duplicate_source whose lease tombstone was already pruned — the ledger
    // still remembers the grant. Honest report, no re-mint.
    if (res.outcome === 'duplicate_source') {
      return {
        handled: true,
        command: 'lease',
        replyToTelegram: {
          text: '<b>мандат не выдан повторно</b> — этот грант уже был обработан ранее (запись мандата уже удалена ротацией).',
          parseMode: 'HTML',
        },
      }
    }
    return {
      handled: true,
      command: 'lease',
      replyToTelegram: {
        text: '<b>/lease</b> — не удалось выдать мандат.',
        parseMode: 'HTML',
      },
    }
  }

  // Heading states the REAL status (fix-loop #8): a duplicate against a
  // TERMINAL lease must not claim «уже активен».
  const now = Date.now()
  let heading: string
  if (res.outcome === 'duplicate_source' || res.outcome === 'duplicate_scope') {
    if (lease.revokedAtMs !== undefined) heading = 'мандат по этому гранту был ОТОЗВАН — новый не выдан'
    else if (lease.consumedAtMs !== undefined && lease.consumedAtMs !== null) heading = 'мандат по этому гранту уже ИСПОЛЬЗОВАН — новый не выдан'
    else if (lease.expiresAtMs <= now) heading = 'мандат по этому гранту ИСТЁК — новый не выдан'
    else heading = 'мандат уже активен'
  } else {
    heading = 'мандат выдан'
  }
  const left = humanizeDurationMs(lease.expiresAtMs - now)
  const text =
    `<b>${heading}</b>\n`
    + `<code>${escapeHtml(lease.id)}</code>\n`
    + `scope: «${escapeHtml(lease.scope)}»\n`
    + (lease.expiresAtMs > now ? `истекает через ${escapeHtml(left)}` : 'без остатка действия')
  return {
    handled: true,
    command: 'lease',
    replyToTelegram: { text, parseMode: 'HTML' },
  }
}

// ─────────────────────────────────────────────────────────────────────
// Main dispatcher. Pure data — caller actually issues sendMessage and
// channel notification calls based on the OobResult. This keeps the
// function trivially testable.
// ─────────────────────────────────────────────────────────────────────

export async function handleOobCommand(
  parsed: ParsedOobCommand,
  ctx: OobContext,
): Promise<OobResult> {
  const baseMeta: Record<string, string> = {
    source: 'telegram',
    chat_id: ctx.chatId,
    user_id: ctx.senderId,
    ts: new Date().toISOString(),
    command: parsed.name,
  }

  switch (parsed.name) {
    case 'help': {
      ctx.log.info('oob /help', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'help',
        replyToTelegram: { text: helpText(), parseMode: 'HTML' },
      }
    }

    case 'status': {
      ctx.log.info('oob /status', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'status',
        replyToTelegram: { text: await statusText(ctx), parseMode: 'HTML' },
      }
    }

    case 'lease': {
      // Autonomy M2 — one of only TWO authenticated lease-grant surfaces. The
      // handlers.ts OOB gate already enforced: private chat + sender in
      // config.allowed_user_ids + chat in allowed_chat_ids. No agent-callable
      // path reaches here.
      return await handleLeaseCommand(parsed, ctx)
    }

    case 'stop': {
      ctx.log.info('oob /stop', { chat_id: ctx.chatId })
      // Cancel any active status — the user explicitly asked to halt, so
      // leaving "Печатает..." pulsing while we wait for Claude to notice
      // the channel event would be confusing. Best-effort: errors in cancel
      // are swallowed inside the manager.
      if (ctx.statusManager && ctx.statusManager.isActive(ctx.chatId)) {
        try {
          await ctx.statusManager.cancel(ctx.chatId, 'user stop')
        } catch (err) {
          ctx.log.warn('oob /stop status cancel failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
      }
      // Real interrupt: Escape stops Claude's current generation/tool. Falls
      // back to the channel-notification signal when no pane is resolvable.
      if (ctx.tmuxKeys) {
        const sent = await sendNamedKey(ctx.tmuxKeys.target, 'Escape', ctx.tmuxKeys.exec)
        return {
          handled: true,
          command: 'stop',
          replyToTelegram: {
            text: sent.ok
              ? '<b>stop</b> — Escape отправлен в сессию (прерывание).'
              : `<b>stop</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
            parseMode: 'HTML',
          },
        }
      }
      return {
        handled: true,
        command: 'stop',
        replyToTelegram: {
          text: '<b>stop</b> — запрос принят. Claude увидит сигнал остановки при следующем чтении канала.',
          parseMode: 'HTML',
        },
        notifyChannel: {
          content: '/stop',
          meta: baseMeta,
        },
      }
    }

    case 'compact': {
      // Non-destructive: shrink the session context. Runs Claude Code's own
      // /compact reliably (probe → interrupt-if-busy → send → confirm) and
      // reports the REAL outcome so the warchief knows if it actually fired.
      if (!ctx.tmuxKeys) {
        return {
          handled: true,
          command: 'compact',
          replyToTelegram: {
            text: '<b>compact</b> — недоступно: нет tmux-pane.',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /compact', { chat_id: ctx.chatId })
      const opts: ControlCommandOpts = { interruptIfBusy: true }
      if (ctx.tmuxKeys.exec) opts.exec = ctx.tmuxKeys.exec
      if (ctx.tmuxKeys.captureExec) opts.captureExec = ctx.tmuxKeys.captureExec
      if (ctx.tmuxKeys.sleep) opts.sleep = ctx.tmuxKeys.sleep
      const res = await sendControlCommand(ctx.tmuxKeys.target, 'compact', opts)
      return {
        handled: true,
        command: 'compact',
        replyToTelegram: {
          text: res.ok
            ? '<b>контекст сжимается</b> — команда принята сессией.'
            : controlFailureMessage(res.reason),
          parseMode: 'HTML',
        },
      }
    }

    case 'new': {
      // Destructive (/clear wipes the context) → one-tap-with-confirm. A bare
      // /new posts a confirmation card; the tap runs the clear through the
      // reliable injection layer (newq: callback in server.ts).
      ctx.log.info('oob /new', { chat_id: ctx.chatId })
      const card = buildNewConfirmCard()
      return {
        handled: true,
        command: 'new',
        replyToTelegram: {
          text: card.text,
          parseMode: 'HTML',
          inlineKeyboard: card.inlineKeyboard,
        },
      }
    }

    case 'mirror': {
      // Sub-action lives in `args`. Empty args → behave like `status`.
      const action = parsed.args.trim().toLowerCase()
      const mirror = ctx.tmuxMirror
      if (!mirror) {
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text:
              '<b>зеркало терминала</b> — отключено в конфиге\n\n'
              + 'Установи <code>tmux_mirror.enabled = true</code> и перезапусти плагин.',
            parseMode: 'HTML',
          },
        }
      }
      if (action === 'on') {
        ctx.log.info('oob /mirror on', { chat_id: ctx.chatId })
        try {
          // MED-A #2: a permanent error (403 / parse) flips the
          // mirror's `disabled` flag and the polling loop becomes a
          // no-op forever — `/mirror off; /mirror on` alone never
          // cleared the flag because start() short-circuits on a
          // disabled mirror. Call reset() first so /mirror on
          // unconditionally re-arms the mirror after a permanent
          // error. Idempotent when the mirror is healthy. Optional
          // on the control interface for source-compat with test
          // stubs that don't implement it.
          if (mirror.reset) mirror.reset()
          await mirror.start()
        } catch (err) {
          ctx.log.warn('oob /mirror on start failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text: '<b>зеркало терминала</b> — <code>on</code>',
            parseMode: 'HTML',
          },
        }
      }
      if (action === 'off') {
        ctx.log.info('oob /mirror off', { chat_id: ctx.chatId })
        try {
          await mirror.stop()
        } catch (err) {
          ctx.log.warn('oob /mirror off stop failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text: '<b>зеркало терминала</b> — <code>off</code>',
            parseMode: 'HTML',
          },
        }
      }
      // Default / explicit `status` — read-only snapshot.
      const s = mirror.status()
      const lines = [
        '<b>зеркало терминала — статус</b>',
        `enabled: <code>${s.enabled ? 'on' : 'off'}</code>`,
      ]
      if (s.messageId !== undefined) lines.push(`message_id: <code>${s.messageId}</code>`)
      if (s.lastPollAt !== undefined) {
        const age = Math.max(0, Math.floor((Date.now() - s.lastPollAt) / 1000))
        lines.push(`last poll: <code>${age}s ago</code>`)
      }
      if (s.lastError) lines.push(`last error: <code>${s.lastError.slice(0, 200)}</code>`)
      if (action !== '' && action !== 'status') {
        lines.push('', '<i>usage: /mirror on | off | status</i>')
      }
      return {
        handled: true,
        command: 'mirror',
        replyToTelegram: {
          text: lines.join('\n'),
          parseMode: 'HTML',
        },
      }
    }

    case 'keys': {
      // Render the one-tap keypad. Each button injects one whitelisted
      // keystroke — their `kkey:` callbacks are dispatched in server.ts with
      // the same fail-closed allowlist auth. We only need a resolvable pane to
      // make the panel useful; if none, explain that the pane is unavailable.
      if (!ctx.tmuxKeys) {
        return {
          handled: true,
          command: 'keys',
          replyToTelegram: {
            text: '<b>/keys</b> — недоступно: плагин не знает tmux-pane сессии (нет tmux-конфига).',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /keys', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'keys',
        replyToTelegram: {
          text: KEYS_PANEL_HEADER,
          parseMode: 'HTML',
          inlineKeyboard: buildKeysKeyboard(),
        },
      }
    }

    case 'cc': {
      // Passthrough to Claude Code's OWN slash commands (/compact, /model,
      // /context, custom skills…) by typing them into the agent pane.
      if (!ctx.tmuxKeys) {
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: '<b>/cc</b> — недоступно: плагин не знает tmux-pane сессии.',
            parseMode: 'HTML',
          },
        }
      }
      // Bare `/cc` (no args) → render the one-tap command panel. The buttons
      // run the SAME passthrough `/cc <command>` does — their `ccmd:` callbacks
      // are dispatched in server.ts with the same fail-closed allowlist auth.
      if (parsed.args.trim() === '') {
        ctx.log.info('oob /cc panel', { chat_id: ctx.chatId })
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: CC_PANEL_HEADER,
            parseMode: 'HTML',
            inlineKeyboard: buildCcKeyboard(),
          },
        }
      }
      const cc = parseCcCommand(parsed.args)
      if ('error' in cc) {
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: { text: escapeHtml(cc.error), parseMode: 'HTML' },
        }
      }
      ctx.log.info('oob /cc', { chat_id: ctx.chatId, name: cc.name })
      const shown = cc.rest ? `/${cc.name} ${cc.rest}` : `/${cc.name}`

      // IT2-6: typed `/cc clear` is DESTRUCTIVE (wipes the context) → route
      // through the SAME confirm card as /new, hud:new and ccmd:clear. Never a
      // one-tap clear, whatever the entry point. The tap's `newq:confirm` runs
      // the reliable /clear.
      if (cc.rest === '' && cc.name === 'clear') {
        ctx.log.info('oob /cc clear → confirm card', { chat_id: ctx.chatId })
        const card = buildNewConfirmCard()
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: card.text,
            parseMode: 'HTML',
            inlineKeyboard: card.inlineKeyboard,
          },
        }
      }

      // FIX-6 (Codex): the typed /cc path must NOT blind-fire into a busy pane
      // or an open dialog. Argless CONTROL `compact` goes through the reliable
      // state-aware sender (probe → interrupt-if-busy → confirm), exactly like the
      // ccmd: button, and reports the REAL result. `compact` is non-destructive so
      // it stays one-tap.
      if (cc.rest === '' && cc.name === 'compact') {
        const opts: ControlCommandOpts = { interruptIfBusy: true }
        if (ctx.tmuxKeys.exec) opts.exec = ctx.tmuxKeys.exec
        if (ctx.tmuxKeys.captureExec) opts.captureExec = ctx.tmuxKeys.captureExec
        if (ctx.tmuxKeys.sleep) opts.sleep = ctx.tmuxKeys.sleep
        const res = await sendControlCommand(ctx.tmuxKeys.target, cc.name, opts)
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: res.ok
              ? `<b>отправлено в сессию:</b> <code>${escapeHtml(shown)}</code>`
              : controlFailureMessage(res.reason),
            parseMode: 'HTML',
          },
        }
      }

      // Other /cc <cmd> (argful, e.g. `model opus`, or read-only `context`):
      // at MINIMUM probe the pane and refuse if it is not idle (dialog/busy/
      // unknown), so a trailing Enter can never approve a dialog or get queued
      // behind a busy tool. Only a positively-idle pane gets the blind send.
      const state = classifyPane(await capturePane(ctx.tmuxKeys.target, ctx.tmuxKeys.captureExec))
      if (state !== 'idle') {
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text:
              `<b>/cc</b> — сессия не готова (<code>${state}</code>), не отправляю `
              + `<code>${escapeHtml(shown)}</code>. Попробуй позже или через /keys.`,
            parseMode: 'HTML',
          },
        }
      }
      const sent = await sendSlashCommand(ctx.tmuxKeys.target, cc, ctx.tmuxKeys.exec)
      return {
        handled: true,
        command: 'cc',
        replyToTelegram: {
          text: sent.ok
            ? `<b>отправлено в сессию:</b> <code>${escapeHtml(shown)}</code>`
            : `<b>/cc</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
          parseMode: 'HTML',
        },
      }
    }

    case 'relogin': {
      // Monthly Claude re-login, end-to-end from chat (relogin.ts). The flow
      // runs DETACHED: the ack below is delivered by executeOobResult right
      // away, while the background task types /login, hunts the OAuth URL for
      // ~40s and reports every outcome via its own Telegram messages. It must
      // work even when Claude is stuck on «Login expired», which is exactly
      // why it uses the blind 3-shot instead of the state-aware sender.
      if (!ctx.tmuxKeys || !ctx.stateDir) {
        return {
          handled: true,
          command: 'relogin',
          replyToTelegram: {
            text: '<b>relogin</b> — недоступно: плагин не знает tmux-pane или state-dir.',
            parseMode: 'HTML',
          },
        }
      }
      // Double-invocation guard: a live relogin-pending flag means a link is
      // already out and the code-interception window is open. Launching a
      // SECOND flow would type another /login into the pane and invalidate
      // the link the owner may be mid-way through using.
      const remainingMs = reloginPendingRemainingMs(ctx.stateDir)
      if (remainingMs !== undefined) {
        const mins = Math.max(1, Math.ceil(remainingMs / 60_000))
        return {
          handled: true,
          command: 'relogin',
          replyToTelegram: {
            text:
              '<b>перелогин</b> — уже жду код: отправь его сюда '
              + `или подожди ~${mins} мин, пока окно закроется.`,
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /relogin', { chat_id: ctx.chatId })
      const io: ReloginIo = {
        target: ctx.tmuxKeys.target,
        chatId: ctx.chatId,
        stateDir: ctx.stateDir,
        telegramApi: ctx.telegramApi,
        log: ctx.log,
        ...(ctx.tmuxKeys.exec ? { exec: ctx.tmuxKeys.exec } : {}),
        ...(ctx.tmuxKeys.captureExec ? { captureExec: ctx.tmuxKeys.captureExec } : {}),
        ...(ctx.tmuxKeys.sleep ? { sleep: ctx.tmuxKeys.sleep } : {}),
      }
      // runReloginFlow never rejects by contract (all errors handled inside);
      // the void marks the deliberate fire-and-forget.
      void runReloginFlow(io)
      return {
        handled: true,
        command: 'relogin',
        replyToTelegram: {
          text: '<b>перелогин</b> — отправил /login в сессию, ищу ссылку (до 40 сек)…',
          parseMode: 'HTML',
        },
      }
    }

    case 'restart': {
      // Full bridge restart via the root-owned per-agent ctl script that
      // install-agent.sh drops into /usr/local/bin (sudoers NOPASSWD, exactly
      // this one path). Executed DETACHED with a 2s grace so the ack reply
      // reaches Telegram before systemd kills this very process.
      const agentId = ctx.restart?.agentId ?? process.env.AGENT_ID
      const fileExists = ctx.restart?.fileExists ?? existsSync
      // Defensive shape check: the id becomes part of an absolute path. The
      // installer only ever writes [a-z0-9-] names, so anything else means a
      // corrupted env — refuse rather than probe a weird path.
      const ctl =
        agentId !== undefined && /^[A-Za-z0-9_-]+$/.test(agentId)
          ? `/usr/local/bin/dashi-ctl-${agentId}`
          : undefined
      if (ctl === undefined || !fileExists(ctl)) {
        return {
          handled: true,
          command: 'restart',
          replyToTelegram: {
            text:
              '<b>restart</b> — на этом сервере нет штатного dashi-ctl '
              + `(${ctl !== undefined ? `<code>${escapeHtml(ctl)}</code> отсутствует` : 'AGENT_ID не задан в окружении'}). `
              + 'Перезапусти сервис руками.',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /restart', { chat_id: ctx.chatId, ctl })
      const spawnDetached =
        ctx.restart?.spawnDetached
        ?? ((cmd: string, args: readonly string[]): void => {
          const child = spawn(cmd, args as string[], { detached: true, stdio: 'ignore' })
          child.unref()
        })
      // bash -c with the ctl path passed as $0 — never interpolated into the
      // script text. `sleep 2` decouples the restart from this process's
      // lifetime AND from the ack send racing it. sudo -n: the sudoers rule
      // is NOPASSWD; if it is missing, failing silently-detached is the
      // accepted trade-off (the ack already told the owner what was attempted).
      spawnDetached('bash', ['-c', 'sleep 2; exec sudo -n "$0" restart', ctl])
      return {
        handled: true,
        command: 'restart',
        replyToTelegram: {
          text: '<b>restart</b> — принято, перезапускаю сервис. Связь моргнёт на ~10 сек.',
          parseMode: 'HTML',
        },
      }
    }

    case 'update': {
      // Plugin self-update from chat. The work (dirty check → backup → git
      // reset → bun install, rollback on failure) lives in the root-owned
      // dashi-ctl script; here we only translate its one-word status into a
      // reply and, on UPDATED, schedule the same detached restart as /restart.
      const agentId = ctx.restart?.agentId ?? process.env.AGENT_ID
      const fileExists = ctx.restart?.fileExists ?? existsSync
      const ctl =
        agentId !== undefined && /^[A-Za-z0-9_-]+$/.test(agentId)
          ? `/usr/local/bin/dashi-ctl-${agentId}`
          : undefined
      if (ctl === undefined || !fileExists(ctl)) {
        return {
          handled: true,
          command: 'update',
          replyToTelegram: {
            text: '<b>update</b> — на этом сервере нет штатного dashi-ctl. Обнови плагин руками (git pull + bun install + restart).',
            parseMode: 'HTML',
          },
        }
      }
      const runCtl =
        ctx.restart?.runCtl
        ?? ((cmd: string, args: readonly string[]) =>
          new Promise<{ code: number; out: string }>((resolve) => {
            execFile('sudo', ['-n', cmd, ...args], { timeout: 180_000 }, (err, stdout) => {
              const code = err && typeof (err as { code?: unknown }).code === 'number'
                ? (err as { code: number }).code
                : err ? 1 : 0
              resolve({ code, out: String(stdout ?? '') })
            })
          }))
      const args = parsed.hasForceFlag ? ['update', 'force'] : ['update']
      ctx.log.info('oob /update', { chat_id: ctx.chatId, ctl, force: parsed.hasForceFlag })
      const { code, out } = await runCtl(ctl, args)
      const line = out.trim().split('\n').pop() ?? ''
      const [word = '', ...rest] = line.split(/\s+/)
      let text: string
      let restart = false
      switch (word) {
        case 'UPTODATE':
          text = '<b>update</b> — уже стоит последняя версия, обновлять нечего.'
          break
        case 'DIRTY':
          text =
            '<b>update</b> — в коде плагина есть правки руками: '
            + `<code>${escapeHtml(rest.join(' ') || '?')}</code>. Обновление их перетрёт. `
            + 'Сохрани их или ответь <code>/update force</code> — перетру, бэкап оставлю рядом (.bak).'
          break
        case 'NOFETCH':
          text = '<b>update</b> — не дотянулся до GitHub, попробуй позже.'
          break
        case 'ROLLBACK':
          text = '<b>update</b> — обновление упало, откатил на прежнюю версию. Сервис не трогал, всё работает как раньше.'
          break
        case 'UPDATED': {
          const [n = '?', sha = '?'] = rest
          text = `<b>update</b> — обновил до <code>${escapeHtml(sha)}</code> (${escapeHtml(n)} коммит.), перезапускаю. Связь моргнёт на ~10 сек.`
          restart = true
          break
        }
        default:
          text = `<b>update</b> — dashi-ctl ответил непонятно (код ${code}): <code>${escapeHtml(line || 'пусто')}</code>. Посмотри логи.`
      }
      if (restart) {
        const spawnDetached =
          ctx.restart?.spawnDetached
          ?? ((cmd: string, a: readonly string[]): void => {
            const child = spawn(cmd, a as string[], { detached: true, stdio: 'ignore' })
            child.unref()
          })
        spawnDetached('bash', ['-c', 'sleep 2; exec sudo -n "$0" restart', ctl])
      }
      return { handled: true, command: 'update', replyToTelegram: { text, parseMode: 'HTML' } }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Convenience side-effect runner used by handlers.ts. Keeps the wiring
// in one place: send the Telegram reply (if any) and emit the channel
// notification (if any). Errors during the Telegram send are logged but
// never thrown — a /help send-failure must not crash the update loop.
// ─────────────────────────────────────────────────────────────────────

export async function executeOobResult(
  result: OobResult,
  ctx: OobContext,
  server: Server,
): Promise<void> {
  if (result.replyToTelegram) {
    try {
      await ctx.telegramApi.sendMessage(ctx.chatId, result.replyToTelegram.text, {
        ...(result.replyToTelegram.parseMode !== undefined
          ? { parse_mode: result.replyToTelegram.parseMode }
          : {}),
        ...(result.replyToTelegram.inlineKeyboard !== undefined
          ? { reply_markup: result.replyToTelegram.inlineKeyboard }
          : {}),
      })
    } catch (err) {
      ctx.log.warn('oob reply send failed', {
        command: result.command,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }
  if (result.notifyChannel) {
    const event: ChannelEvent = {
      content: result.notifyChannel.content,
      meta: result.notifyChannel.meta,
    }
    await sendChannelNotification(server, event, ctx.log)
  }
}
