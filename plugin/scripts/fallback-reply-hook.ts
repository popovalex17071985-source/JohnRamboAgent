#!/usr/bin/env bun
// fallback-reply-hook.ts — Claude Code Stop hook → DM fallback reply.
//
// feature/dm-fallback-reply-hook (2026-06-03). The warchief's Telegram DM
// (the main/launcher session) answers him through the
// `mcp__dashi-channel__reply` MCP tool — that send is what actually reaches
// his chat; the session transcript never does. If a turn ends WITHOUT having
// called reply()/edit_message(), the warchief gets silence even though the
// turn produced a final answer. This Stop hook closes that gap: on turn-end it
// reads the session transcript, and IF the turn was answering a Telegram
// message AND did not send an MCP reply this turn, it forwards the turn's
// final assistant text to the plugin's POST /hooks/fallback-reply route, which
// sends it to the warchief's Telegram via the single bot.
//
// This mirrors the multichat per-chat auto-forward (src/chats/hooks/
// stop-to-outbox.py) but for the DM, where sends go through the MCP reply tool
// instead of a per-chat outbox. The turn-walk + dedup logic is ported from
// that Python hook; the route/env-file resolution + dedup-log layout are
// reused from read-receipt-hook.ts.
//
// Suppression invariants (no duplicate to the warchief):
//   * If the turn called mcp__dashi-channel__reply OR
//     mcp__dashi-channel__edit_message AND that call SUCCEEDED → a reply already
//     reached him → silent. fix-loop #7 / fix-loop-2: ONLY a reply whose
//     tool_result came back as an explicit ASK-GUARD BLOCK (isError + the
//     ASK_GUARD marker) is treated as "did NOT reach him" — its final text is
//     still forwarded and the fallback route re-runs the same guard on it. A
//     GENERIC reply error (network/HTTP timeout) is ambiguous — the send may
//     have reached Telegram before the client saw the error — so it KEEPS the
//     suppression to avoid a duplicate delivery.
//   * If the turn has no final assistant text (pure tool / pure thinking) →
//     nothing to forward → silent.
//   * If the turn was not answering a Telegram message (no `<channel
//     source="telegram" ... chat_id="...">` in its user prompt) → silent. This
//     both scopes the fallback to Telegram-driven turns AND supplies the
//     destination chat_id WITHOUT trusting any env-provided chat.
//   * Per-session dedup → at most one forward per turn across repeated Stop
//     fires.
//
// Hard invariants (mirror read-receipt-hook.ts):
//   * Exit code 0 in ALL paths. A non-zero hook blocks the model; a fallback
//     reply must never gate the agent.
//   * Stdout stays EMPTY. Stop-hook stdout is treated as model context.
//   * Stderr lines are short and secret-free (no token, no transcript body).
//
// Configuration (env), in priority order:
//   TELEGRAM_FALLBACK_REPLY_URL    full route URL, e.g.
//                                  http://127.0.0.1:8089/hooks/fallback-reply
//   TELEGRAM_WEBHOOK_TOKEN         bearer token for the route
//   — or, when the explicit URL is absent —
//   TELEGRAM_WEBHOOK_HOST/PORT     host (default 127.0.0.1) + port → route URL
//   TELEGRAM_CHANNEL_ENV_FILE      path to the plugin env file; HOST/PORT/TOKEN
//                                  are read from it (DM session env resolution,
//                                  same linchpin as read-receipt-hook).
//   TELEGRAM_STATE_DIR             base dir for the dedup state (per-session)
//   TELEGRAM_FALLBACK_REPLY_STATE  explicit dedup-state path (overrides dir)
//   FALLBACK_REPLY_RETRY_ATTEMPTS  bounded retry on empty extraction (default 4)
//   FALLBACK_REPLY_RETRY_DELAY_MS  delay between retries (default 120ms)

import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  openSync,
  readSync,
  fstatSync,
  closeSync,
  readdirSync,
  renameSync,
  unlinkSync,
} from 'fs'
import { createHash } from 'crypto'
import { dirname, join } from 'path'

// Reuse the env-file + per-session-state primitives from the read-receipt
// hook so both Stop hooks resolve the route/dedup identically. These are pure
// (no module side effects on import beyond the function defs).
import {
  loadChannelEnvFile,
  parseEnvFile,
} from './read-receipt-hook.js'

// The machine-readable marker that leads every ask-guard block-mode refusal
// (`askGuardBlockMessage`). It is the ONLY isError shape that unsuppresses the
// fallback (owner NOT reached → forward the final text, re-guarded downstream);
// every other reply error is ambiguous (the send may have reached Telegram
// before the client saw the error) and KEEPS the old suppression to avoid a
// duplicate delivery. Imported from the guard so the two stay in lockstep.
import { ASK_GUARD_BLOCK_MARKER } from '../src/safety/ask-guard.js'
// Same chunker the MCP reply tool uses, so a long fallback answer is split on
// paragraph/tag boundaries instead of being guillotined at 4096.
import { splitMessage } from '../src/format/chunk.js'

// Re-export the borrowed helpers under this module too, so tests importing
// from this hook get a single surface. (parseEnvFile is used transitively by
// loadChannelEnvFile; re-exported for symmetry with read-receipt-hook tests.)
export { loadChannelEnvFile, parseEnvFile }

// Tail window for the backward walk — matches stop-to-outbox.py. Sized so a
// whole interactive turn (incl. large tool_result blocks) almost always fits,
// keeping the current turn's user-prompt boundary inside the window. If a
// single turn exceeds this, the boundary can fall outside and the walk could
// reach a previous turn's text; dedup is the secondary guard.
const TAIL_BYTES = 1024 * 1024
// A single JSONL line can be larger than the tail window (one fat tool result on
// a 30 MB transcript). The window then holds no newline at all, the old code
// returned an empty string and the hook went silent -- the answer was in the file
// the whole time. So we grow the window until a line boundary appears.
const TAIL_BYTES_MAX = 32 * 1024 * 1024

// The two MCP tools that deliver a reply to the warchief's Telegram. If either
// was called this turn, the warchief already saw the answer → no fallback.
const REPLY_TOOL_NAMES = new Set<string>([
  'mcp__dashi-channel__reply',
  'mcp__dashi-channel__edit_message',
])

const FETCH_TIMEOUT_MS = 5000
const STATE_CAP_BYTES = 256 * 1024

// Telegram's sendMessage hard caps a single message at 4096 chars; the route
// schema rejects anything longer with 400. The bare sendMessage does NOT chunk
// (chunking lives only in the MCP reply tool), so a >4096-char final answer
// would 400-drop forever. FIX 5 (minimum viable): truncate to TELEGRAM_TEXT_MAX
// with a short marker so a long answer always delivers SOMETHING. Marker stays
// within the 4096 budget: body ≤ 4096 − marker length.
const TELEGRAM_TEXT_MAX = 4096
const TRUNCATION_MARKER = '\n…[обрезано]'

/** Truncate a final text to Telegram's 4096-char cap, appending a marker. */
export function truncateForTelegram(text: string): string {
  if (text.length <= TELEGRAM_TEXT_MAX) return text
  const room = TELEGRAM_TEXT_MAX - TRUNCATION_MARKER.length
  return text.slice(0, room) + TRUNCATION_MARKER
}

/**
 * FIX 8 (правка 5, 19.09.2026): split a long answer instead of truncating it.
 *
 * Truncation was the minimum viable fix — it always delivered SOMETHING, but the
 * tail (which in a report is where the numbers and the next step live) was
 * simply thrown away. The route's bare sendMessage does not chunk, so we chunk
 * here with the same splitter the MCP reply tool uses: cuts land on paragraph
 * boundaries and balanced tags are reopened, so each part renders on its own.
 *
 * Bounded by MAX_PARTS: an absurdly long text still ends with a truncation
 * marker rather than spamming the chat with dozens of messages.
 */
export const FALLBACK_CHUNK_MAX = 4000
export const FALLBACK_MAX_PARTS = 6

export function splitForTelegram(text: string): string[] {
  const parts = splitMessage(text, FALLBACK_CHUNK_MAX)
  if (parts.length <= FALLBACK_MAX_PARTS) return parts
  const kept = parts.slice(0, FALLBACK_MAX_PARTS)
  const last = kept[FALLBACK_MAX_PARTS - 1] as string
  const room = Math.max(0, FALLBACK_CHUNK_MAX - TRUNCATION_MARKER.length)
  kept[FALLBACK_MAX_PARTS - 1] = last.slice(0, room) + TRUNCATION_MARKER
  return kept
}

// ─────────────────────────────────────────────────────────────────────
// BUG 2 — strip leaked tool-call machinery from a forwarded final text.
//
// When a tool call is MALFORMED (e.g. a stray token glued before the block,
// `court<invoke name="...">…</invoke>`), the harness does NOT parse it as a
// tool_use — the raw XML lands in the assistant's TEXT block. The fallback
// forward would then post that machinery (`<invoke …>`, `<parameter …>`,
// `</invoke>`) verbatim to the warchief. We remove those blocks/tags; when only
// junk or emptiness survives, the message WAS the broken call → forward nothing.
// ─────────────────────────────────────────────────────────────────────

// Fast presence probe: any opener/closer of a tool-call tag, namespaced
// (`antml:`) or bare. Used to leave normal prose completely untouched.
const TOOL_CALL_SYNTAX_RE = /<\/?(?:antml:)?(?:function_calls|invoke|parameter)\b/i

/** True when the text carries any tool-call XML tag (well-formed or stray). */
export function containsToolCallSyntax(text: string): boolean {
  return TOOL_CALL_SYNTAX_RE.test(text)
}

// Below this many non-whitespace chars, a message that CONTAINED tool-call
// syntax is treated as pure machinery + a stray fragment (the "court" prefix),
// not a real answer → suppressed rather than forwarded.
const MIN_SANITIZED_PROSE = 8

/** Remove tool-call blocks and stray tags; collapse leftover whitespace. */
export function stripToolCallSyntax(text: string): string {
  let out = text
  // Whole well-formed blocks first (non-greedy), namespaced or bare.
  out = out.replace(/<(?:antml:)?function_calls\b[\s\S]*?<\/(?:antml:)?function_calls>/gi, ' ')
  out = out.replace(/<(?:antml:)?invoke\b[\s\S]*?<\/(?:antml:)?invoke>/gi, ' ')
  out = out.replace(/<(?:antml:)?parameter\b[\s\S]*?<\/(?:antml:)?parameter>/gi, ' ')
  // Residual stray tags (unbalanced leak): drop the tag tokens themselves.
  out = out.replace(/<\/?(?:antml:)?(?:function_calls|invoke|parameter)\b[^>]*>/gi, ' ')
  return out
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

/**
 * Decide the text to forward. Normal prose passes through untouched. Text that
 * contained tool-call syntax is stripped; if the surviving prose is too thin to
 * be a real answer, returns undefined → the caller forwards NOTHING (never leaks
 * `<invoke …>` machinery, never posts a stray "court" fragment).
 */
export function sanitizeForForward(text: string): string | undefined {
  if (!containsToolCallSyntax(text)) return text
  const cleaned = stripToolCallSyntax(text)
  if (cleaned.replace(/\s+/g, '').length < MIN_SANITIZED_PROSE) return undefined
  return cleaned
}

// ─────────────────────────────────────────────────────────────────────
// Transcript turn-walk. Ported from stop-to-outbox.py's
// read_last_assistant_text + _is_user_prompt: walk the CURRENT TURN backward,
// stopping at the last genuine user prompt, collecting the most recent
// assistant text and detecting whether any assistant message in the turn
// called a reply tool. We also extract the inbound Telegram chat_id from the
// turn's user prompt.
// ─────────────────────────────────────────────────────────────────────

export interface TurnResult {
  // The most recent assistant text of the current turn (joined text blocks),
  // or undefined when the turn produced none (pure tool / thinking turn).
  readonly text?: string | undefined
  // Dedup discriminator: the text-bearing assistant line's `uuid` when
  // present, else undefined (caller falls back to a text hash).
  readonly uuid?: string | undefined
  // True if ANY assistant message in this turn called a reply MCP tool.
  readonly replied: boolean
  // The inbound Telegram chat_id parsed from the turn's user prompt, or
  // undefined when the turn was not answering a Telegram message.
  readonly chatId?: string | undefined
  // The boundary user-prompt's text content (FIX 6 dedup discriminator). Used
  // to distinguish two different turns that have no `uuid` but identical
  // assistant text. Undefined when no boundary prompt text was found.
  readonly promptText?: string | undefined
  // True only when the captured `text` is the turn's TRAILING content — i.e. no
  // tool_use/tool_result block appears after it in the turn. A stable interim
  // followed by a tool cycle (the model is mid-turn, final not yet flushed) is
  // NOT trailing, and must not be forwarded as if it were the final answer.
  readonly textIsTrailing: boolean
  // True when the boundary prompt is a background <task-notification> (a
  // subagent / background job finished). Such a turn is the agent talking to
  // itself: its unreplied final text is a terminal note, never an answer owed
  // to the owner, so it must not fall back to the last DM chat.
  readonly backgroundNotification?: boolean | undefined
}

/**
 * Extract the genuine inbound Telegram chat_id from the LEADING `<channel ...>`
 * envelope of a user-prompt's TEXT. The real inbound envelope ALWAYS leads the
 * user prompt; a `<channel ...>` tag appearing later in the body is untrusted
 * (it could be injected by a message author or echoed transcript content), so
 * we read ONLY the leading tag.
 *
 * Tolerant of both the JSON-escaped transcript form (`chat_id=\"164795011\"`)
 * and the raw form. Only telegram envelopes match (orgrimmar-inbox events carry
 * no telegram source). Returns undefined when the trimmed text does NOT start
 * with a telegram channel envelope → no trusted destination → no forward.
 *
 * FIX 7: the regex is constructed locally (no shared module-level `/g` regex
 * with a mutable `lastIndex` that could carry state across calls).
 */
export function extractLeadingTelegramChatId(promptText: string): string | undefined {
  const trimmed = promptText.trimStart()
  // Anchored at the start: only the LEADING channel tag is considered. The
  // attrs group is non-greedy up to the first `>` so it captures one tag.
  const leadingTag = /^<channel\b([^>]*)>/.exec(trimmed)
  if (!leadingTag) return undefined
  const attrs = leadingTag[1] ?? ''
  if (!/source\s*=\s*\\?"telegram\\?"/.test(attrs)) return undefined
  // chat_id is negative for groups/supergroups, so allow a leading `-`.
  const chat = /chat_id\s*=\s*\\?"(-?\d+)\\?"/.exec(attrs)
  return chat ? (chat[1] as string) : undefined
}

interface TranscriptMessage {
  readonly role?: unknown
  readonly content?: unknown
}
interface TranscriptLine {
  readonly message?: unknown
  readonly uuid?: unknown
  readonly turnCompanion?: unknown
  readonly origin?: unknown
}

// 11.10.2026 (leak, msg 62475): when a Stop hook BLOCKS the turn, Claude Code
// records the hook's reason as a plain-string USER line starting with this
// prefix (followed by a hook_blocking_error attachment and a stop_hook_summary
// system line). It is a continuation of the SAME turn, not a new prompt: real
// Telegram prompts always lead with a <channel> envelope, so the prefix cannot
// collide with one.
const STOP_HOOK_FEEDBACK_PREFIX = 'Stop hook feedback:'

/**
 * True for a user line that Claude Code injects INSIDE the current turn and
 * that therefore is not a turn boundary:
 *   - the `Stop hook feedback:` continuation of a blocked Stop;
 *   - a `turnCompanion: true` line (image metadata after a Read, a loaded
 *     skill's body after a Skill call) that rides along with a tool result.
 * Treating these as boundaries cut the turn short: the original prompt's
 * reply and chat_id were never seen, and the continuation's note to self was
 * forwarded to the last DM chat.
 */
function isSyntheticTurnLine(line: TranscriptLine, promptText: string | undefined): boolean {
  if (line.turnCompanion === true) return true
  return promptText !== undefined && promptText.startsWith(STOP_HOOK_FEEDBACK_PREFIX)
}

/** True when the boundary prompt is a background <task-notification>. */
function isTaskNotification(line: TranscriptLine, promptText: string | undefined): boolean {
  const origin = line.origin
  if (origin !== null && typeof origin === 'object') {
    if ((origin as Record<string, unknown>).kind === 'task-notification') return true
  }
  return promptText !== undefined && promptText.trimStart().startsWith('<task-notification>')
}

/**
 * The `id`s of reply-tool tool_use blocks in an assistant content array. A
 * block with no string `id` (legacy/synthetic transcripts) yields the sentinel
 * '' so it is still counted as a reply (it can never match an is_error result,
 * which always carries a real tool_use_id) — preserving the pre-fix behaviour
 * for transcripts that omit ids.
 */
function replyToolUseIds(content: unknown): string[] {
  if (!Array.isArray(content)) return []
  const ids: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (b.type === 'tool_use' && typeof b.name === 'string' && REPLY_TOOL_NAMES.has(b.name)) {
      ids.push(typeof b.id === 'string' ? b.id : '')
    }
  }
  return ids
}

/** The joined text of a tool_result `content` (string, or `{type:'text'}` blocks). */
function toolResultText(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (typeof b.text === 'string') parts.push(b.text)
  }
  return parts.join('\n')
}

/**
 * The `tool_use_id`s of reply tool_result blocks that came back as an
 * ASK-GUARD BLOCK (`is_error: true` AND the result text carries
 * `ASK_GUARD_BLOCK_MARKER`). fix-loop #7 first unsuppressed on ANY isError
 * reply; fix-loop-2 (Codex round-2 HIGH) narrows that: an ask-guard block
 * provably did NOT reach the owner, so its final text MUST still be forwarded,
 * but a generic reply error (network/HTTP timeout) is AMBIGUOUS — the send may
 * have reached Telegram before the client saw the error — so forwarding it too
 * would DOUBLE-deliver. Only the explicit block marker unsuppresses; every
 * other isError keeps the pre-fix suppression (reply counts as delivered).
 */
function askGuardBlockedReplyIds(content: unknown): string[] {
  if (!Array.isArray(content)) return []
  const ids: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (
      b.type === 'tool_result' &&
      b.is_error === true &&
      typeof b.tool_use_id === 'string' &&
      toolResultText(b.content).includes(ASK_GUARD_BLOCK_MARKER)
    ) {
      ids.push(b.tool_use_id)
    }
  }
  return ids
}

/** True when a content array contains any tool_use block (assistant tool call). */
function contentHasToolUse(content: unknown): boolean {
  if (!Array.isArray(content)) return false
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    if ((block as Record<string, unknown>).type === 'tool_use') return true
  }
  return false
}

/** Collect the joined text blocks of an assistant content array (empty when none). */
function assistantText(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const block of content) {
    if (block === null || typeof block !== 'object') continue
    const b = block as Record<string, unknown>
    if (b.type === 'text' && typeof b.text === 'string') parts.push(b.text)
  }
  return parts.join('\n')
}

/**
 * Extract the TEXT content of a user-prompt message. For a string content the
 * string itself is the text; for an array content we join the `{type:'text'}`
 * blocks ONLY. We deliberately do NOT serialize the whole array (FIX 2): the
 * raw JSON line can carry channel-looking substrings inside tool metadata, and
 * the leading-envelope rule must see the genuine prompt text, not that noise.
 * Returns undefined when there is no usable text content.
 */
function userPromptText(content: unknown): string | undefined {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    const parts: string[] = []
    for (const block of content) {
      if (block === null || typeof block !== 'object') continue
      const b = block as Record<string, unknown>
      if (b.type === 'text' && typeof b.text === 'string') parts.push(b.text)
    }
    return parts.length > 0 ? parts.join('\n') : undefined
  }
  return undefined
}

/**
 * Classify a user-role message: genuine prompt (turn boundary) vs tool_result
 * echo (part of the current turn). Ported from stop-to-outbox.py's
 * `_is_user_prompt`: conservative — a user message is a prompt UNLESS it is
 * confidently a tool_result-only echo (or empty). A string is a prompt when
 * non-blank; a list is a prompt unless EVERY block is a tool_result.
 */
export function isUserPrompt(content: unknown): boolean {
  if (typeof content === 'string') return content.trim().length > 0
  if (Array.isArray(content)) {
    if (content.length === 0) return false
    return content.some((block) => {
      if (block === null || typeof block !== 'object') return true
      return (block as Record<string, unknown>).type !== 'tool_result'
    })
  }
  return false
}

/**
 * Walk the transcript text backward over the CURRENT TURN and return a
 * TurnResult. Pure — no I/O. The transcript is the tail-read JSONL text (one
 * Claude transcript line per `\n`). We stop at the last genuine user prompt so
 * a previous (already-handled) turn is never resurfaced. Along the way we:
 *   - capture the most recent assistant TEXT of the turn (the final reply),
 *   - flag whether ANY assistant message of the turn called a reply tool,
 *   - on the boundary user prompt, extract the inbound Telegram chat_id.
 *
 * `replied` and `chatId` are determined for the WHOLE turn, so we keep walking
 * to the user-prompt boundary even after we've found the final text.
 */
export function analyzeCurrentTurn(transcript: string): TurnResult {
  const lines = transcript.split('\n').filter((l) => l.trim().length > 0)
  let text: string | undefined
  let uuid: string | undefined
  let replied = false
  // Walking backward, any tool activity we meet BEFORE the most-recent text was
  // emitted AFTER that text chronologically → the text is a mid-turn interim,
  // not the trailing final. Tracked only until `text` is captured.
  let sawToolAfter = false
  // fix-loop #7 / fix-loop-2: tool_use_ids of reply results that came back as an
  // ASK-GUARD BLOCK (isError + marker). We walk BACKWARD, so a tool_result echo
  // (later in the transcript) is seen BEFORE its tool_use (earlier) — this set
  // is populated by the time we reach the reply tool_use, so a BLOCKED reply
  // never sets `replied`. A generic reply error is NOT collected here, so it
  // still sets `replied` (suppressed → no duplicate delivery).
  const blockedReplyIds = new Set<string>()
  for (let i = lines.length - 1; i >= 0; i--) {
    let obj: unknown
    try {
      obj = JSON.parse(lines[i] as string)
    } catch {
      continue
    }
    if (obj === null || typeof obj !== 'object') continue
    const line = obj as TranscriptLine
    const rawMessage = line.message
    if (rawMessage === null || typeof rawMessage !== 'object') continue
    const message = rawMessage as TranscriptMessage
    const role = message.role
    const content = message.content

    if (role === 'user') {
      // tool_result echo → part of this turn, keep walking. Genuine prompt →
      // turn boundary: extract the inbound telegram chat_id from the LEADING
      // envelope of the prompt's TEXT (FIX 2) and stop. We use only the
      // prompt's text blocks — never the raw JSON line — so injected
      // `<channel ...>` substrings in tool metadata cannot redirect the send.
      if (isUserPrompt(content)) {
        const promptText = userPromptText(content)
        if (isSyntheticTurnLine(line, promptText)) {
          // Same turn continues above this line. A companion rides with a tool
          // result, so it counts as tool activity after a not-yet-found text;
          // a stop-hook continuation does not.
          if (text === undefined && line.turnCompanion === true) sawToolAfter = true
          continue
        }
        const chatId =
          promptText !== undefined ? extractLeadingTelegramChatId(promptText) : undefined
        return {
          text,
          uuid,
          replied,
          chatId,
          promptText,
          textIsTrailing: text !== undefined && !sawToolAfter,
          backgroundNotification: isTaskNotification(line, promptText),
        }
      }
      // tool_result echo (not a genuine prompt) → tool activity. If it sits
      // after the most-recent text, that text is a non-trailing interim.
      if (text === undefined) sawToolAfter = true
      // Record any ask-guard-BLOCKED reply results before continuing
      // (generic errors are deliberately NOT recorded: ambiguous).
      for (const id of askGuardBlockedReplyIds(content)) blockedReplyIds.add(id)
      continue
    }

    if (role !== 'assistant') continue
    // A reply counts as delivered UNLESS it was an ASK-GUARD BLOCK (proven
    // undelivered). A generic reply error is ambiguous and still counts as
    // delivered so the fallback does not double-send.
    for (const id of replyToolUseIds(content)) {
      if (!blockedReplyIds.has(id)) replied = true
    }
    if (text === undefined) {
      const t = assistantText(content)
      if (t.length > 0) {
        text = t
        const u = line.uuid
        uuid = typeof u === 'string' && u.length > 0 ? u : undefined
      } else if (contentHasToolUse(content)) {
        // tool-only assistant message after the (later-found) text.
        sawToolAfter = true
      }
    }
  }
  // Reached the top without a genuine user prompt: no turn boundary found, so
  // we cannot confirm a Telegram chat_id → no fallback. Still report replied
  // (harmless) but leave chatId/promptText undefined.
  return { text, uuid, replied, chatId: undefined, promptText: undefined, textIsTrailing: text !== undefined && !sawToolAfter }
}

// ─────────────────────────────────────────────────────────────────────
// Tail-read the transcript (matches stop-to-outbox.py): read at most the
// trailing TAIL_BYTES and drop the first possibly-truncated line when not
// starting at byte 0.
// ─────────────────────────────────────────────────────────────────────

export function tailReadTranscript(
  path: string,
  read: (p: string, bytes?: number) => { text: string; truncated: boolean } = readTailDefault,
): string {
  let bytes = TAIL_BYTES
  for (;;) {
    const { text, truncated } = read(path, bytes)
    if (!truncated) return text
    const nl = text.indexOf('\n')
    if (nl >= 0) return text.slice(nl + 1)
    // No line boundary in the window: the last line alone is bigger than it.
    // Grow and retry; give up only at TAIL_BYTES_MAX and hand back what we have
    // rather than an empty string, so a caller still sees the tail.
    if (bytes >= TAIL_BYTES_MAX) return text
    bytes = Math.min(bytes * 4, TAIL_BYTES_MAX)
  }
}

function readTailDefault(path: string, bytes: number = TAIL_BYTES): { text: string; truncated: boolean } {
  let fd = -1
  try {
    fd = openSync(path, 'r')
    const size = fstatSync(fd).size
    if (size === 0) return { text: '', truncated: false }
    const length = Math.min(size, bytes)
    const start = size - length
    const buf = Buffer.alloc(length)
    readSync(fd, buf, 0, length, start)
    return { text: buf.toString('utf8'), truncated: start > 0 }
  } finally {
    if (fd >= 0) {
      try {
        closeSync(fd)
      } catch {
        /* ignore */
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Route config resolution. Mirrors read-receipt-hook's resolveReactConfig,
// targeting the /hooks/fallback-reply route instead.
// ─────────────────────────────────────────────────────────────────────

export interface FallbackConfig {
  readonly url: string
  readonly token: string
}
export interface FallbackConfigError {
  readonly kind: 'error'
  readonly reason: string
}
export type FallbackConfigResult = FallbackConfig | FallbackConfigError

export function resolveFallbackConfig(
  env: Readonly<Record<string, string | undefined>>,
): FallbackConfigResult {
  const token = env.TELEGRAM_WEBHOOK_TOKEN
  if (!token) return { kind: 'error', reason: 'missing TELEGRAM_WEBHOOK_TOKEN' }

  if (env.TELEGRAM_FALLBACK_REPLY_URL) {
    return { url: env.TELEGRAM_FALLBACK_REPLY_URL, token }
  }

  const host = env.TELEGRAM_WEBHOOK_HOST ?? '127.0.0.1'
  const port = env.TELEGRAM_WEBHOOK_PORT
  if (!port) return { kind: 'error', reason: 'missing TELEGRAM_WEBHOOK_PORT' }
  return { url: `http://${host}:${port}/hooks/fallback-reply`, token }
}

// ─────────────────────────────────────────────────────────────────────
// Per-session dedup state. Same layout idea as stop-to-outbox.py's
// last-stop-outbox.json: record (session_id, transcript_path, dedupe_token);
// an identical triple short-circuits. Keyed per-session so each session writes
// only its own file (no cross-session race). dedupe_token = assistant uuid or
// text hash, so two DIFFERENT turns with identical text are NOT suppressed.
// ─────────────────────────────────────────────────────────────────────

export interface DedupState {
  readonly session_id: string
  readonly transcript_path: string
  readonly dedupe_token: string
}

function safeSessionId(sessionId: string): string {
  const cleaned = sessionId.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 128)
  return cleaned.length > 0 ? cleaned : 'session'
}

/**
 * Per-session dedup-state path. Explicit TELEGRAM_FALLBACK_REPLY_STATE wins
 * (tests / single writer). Base dir falls back through TELEGRAM_STATE_DIR →
 * MULTICHAT_STATE_DIR (the DM session has the former). Returns undefined when
 * no base dir is resolvable → dedup is then in-memory only for the run.
 */
export function resolveStatePath(
  env: Readonly<Record<string, string | undefined>>,
  sessionId?: string,
): string | undefined {
  if (env.TELEGRAM_FALLBACK_REPLY_STATE) return env.TELEGRAM_FALLBACK_REPLY_STATE
  const base = env.TELEGRAM_STATE_DIR ?? env.MULTICHAT_STATE_DIR
  if (!base) return undefined
  const file = sessionId ? `${safeSessionId(sessionId)}.json` : 'fallback-reply.json'
  return join(base, 'fallback-reply', file)
}

/**
 * DM-scoped "last seen Telegram chat_id" path. Resolvable ONLY from
 * TELEGRAM_STATE_DIR (the single-peer DM session) — never MULTICHAT_STATE_DIR,
 * so a group session can't reuse a stale chat_id and misroute. Lets a turn
 * triggered by a background task-notification (whose boundary prompt carries no
 * <channel chat_id=…> envelope) still reach the user instead of dropping silent.
 */
export function lastChatPath(
  env: Readonly<Record<string, string | undefined>>,
): string | undefined {
  const base = env.TELEGRAM_STATE_DIR
  if (!base) return undefined
  return join(base, 'fallback-reply', 'last-chat')
}

export function readLastChat(
  path: string | undefined,
  readFile: (p: string) => string = (p) => readFileSync(p, 'utf8'),
): string | undefined {
  if (!path) return undefined
  try {
    const v = readFile(path).trim()
    return v.length > 0 ? v : undefined
  } catch {
    return undefined
  }
}

/**
 * Destination for a fallback forward. The turn's own Telegram envelope wins.
 * An envelope-less turn falls back to the last DM chat — EXCEPT a background
 * <task-notification> turn: its unreplied final text is the agent's note to
 * itself (often English), and forwarding it leaked terminal chatter to the
 * owner. Scheduled / watchdog prompts (also envelope-less) keep the fallback:
 * they are told to report to the owner and rely on it when reply is skipped.
 */
export function resolveFallbackChat(
  turn: TurnResult,
  readLast: () => string | undefined,
): string | undefined {
  if (turn.chatId !== undefined) return turn.chatId
  if (turn.backgroundNotification === true) return undefined
  return readLast()
}

export function persistLastChat(path: string | undefined, chatId: string): void {
  if (!path) return
  // Groups never become the fallback anchor. A group message used to make the
  // NEXT envelope-less turn (background task notification, hook retry) post the
  // operator's working notes into that public chat — 03.09.2026 a status meant
  // for the DM landed in «Агентская схема». Only a private chat (positive id)
  // is a safe default destination; a group gets the fallback only when THAT
  // turn is anchored in it.
  if (chatId.startsWith('-')) return
  try {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, chatId, { mode: 0o600 })
  } catch {
    /* best-effort: a stale/absent last-chat only loses the fallback, never sends wrong */
  }
}

/**
 * Per-turn dedup token. When the transcript line carries a `uuid` it uniquely
 * identifies the turn → use it alone. Without a uuid (legacy transcripts) the
 * assistant text alone is NOT a turn discriminator: two DIFFERENT turns in the
 * same session with identical assistant text would collide and the second
 * would be suppressed, losing the warchief an answer (FIX 6). So we fold the
 * boundary user-prompt's text into the hash — different prompts → different
 * tokens even when the assistant text matches.
 */
export function dedupeToken(
  uuid: string | undefined,
  text: string,
  promptText?: string | undefined,
): string {
  if (uuid) return uuid
  const material = promptText !== undefined ? `${promptText} ${text}` : text
  return createHash('sha256').update(material, 'utf8').digest('hex')
}

export function loadDedupState(
  path: string,
  readFile: (p: string) => string = (p) => readFileSync(p, 'utf8'),
): DedupState | undefined {
  try {
    const parsed: unknown = JSON.parse(readFile(path))
    if (parsed === null || typeof parsed !== 'object') return undefined
    const p = parsed as Record<string, unknown>
    if (
      typeof p.session_id === 'string' &&
      typeof p.transcript_path === 'string' &&
      typeof p.dedupe_token === 'string'
    ) {
      return {
        session_id: p.session_id,
        transcript_path: p.transcript_path,
        dedupe_token: p.dedupe_token,
      }
    }
    return undefined
  } catch {
    return undefined
  }
}

/** True when `prior` records the exact same turn we are about to forward. */
export function alreadyForwarded(prior: DedupState | undefined, next: DedupState): boolean {
  return (
    prior !== undefined &&
    prior.session_id === next.session_id &&
    prior.transcript_path === next.transcript_path &&
    prior.dedupe_token === next.dedupe_token
  )
}

function persistDedupState(path: string, state: DedupState): void {
  try {
    mkdirSync(dirname(path), { recursive: true })
    const body = JSON.stringify(state)
    // Bound the file: a single small JSON object never approaches this, but
    // guard against an accidental append-style write elsewhere corrupting it.
    if (Buffer.byteLength(body) <= STATE_CAP_BYTES) {
      writeFileSync(path, body, { mode: 0o600 })
    }
  } catch {
    /* persistence is best-effort; a re-send next turn is a rare duplicate */
  }
}

// ─────────────────────────────────────────────────────────────────────
// Bounded int knob reader (ported from stop-to-outbox.py's _env_int).
// ─────────────────────────────────────────────────────────────────────

function envInt(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
  def: number,
  minimum: number,
  maximum: number,
): number {
  const raw = env[name]
  if (!raw) return def
  const val = Number.parseInt(raw, 10)
  if (!Number.isFinite(val)) return def
  if (val < minimum) return def
  if (val > maximum) return maximum
  return val
}

// ─────────────────────────────────────────────────────────────────────
// HTTP + stdin plumbing (mirrors read-receipt-hook.ts).
// ─────────────────────────────────────────────────────────────────────

interface BunGlobal {
  readonly stdin?: { readonly text?: () => Promise<string> }
}

async function readStdin(): Promise<string> {
  try {
    const bun = (globalThis as { Bun?: BunGlobal }).Bun
    const fn = bun?.stdin?.text
    if (typeof fn === 'function') return await fn.call(bun?.stdin)
  } catch {
    /* fall through */
  }
  return await new Promise<string>((resolve) => {
    const chunks: Buffer[] = []
    process.stdin.on('data', (chunk: Buffer) => chunks.push(chunk))
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    process.stdin.on('error', () => resolve(''))
  })
}

function warn(reason: string): void {
  const safe = reason.length > 80 ? `${reason.slice(0, 77)}...` : reason
  process.stderr.write(`fallback-reply-hook: ${safe}\n`)
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

/**
 * POST one fallback reply. Returns true ONLY when the route confirms the send
 * actually reached Telegram ({status:'sent'}).
 *
 * FIX 1: the route returns HTTP 200 for BOTH a real send AND a fail-soft send
 * failure ({status:'send_failed'}). Treating any 200 as success would persist
 * dedup on a transient send failure → a repeat Stop fire for the same turn is
 * suppressed → the warchief never gets the answer. So we parse the body and
 * succeed only on `{status:'sent'}`. For `{status:'send_failed'}`, an
 * unparseable body, or any non-200 → return false (dedup NOT written → a repeat
 * Stop fire retries the send).
 */
async function postFallback(config: FallbackConfig, chatId: string, text: string): Promise<boolean> {
  try {
    const response = await fetch(config.url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.token}`,
      },
      body: JSON.stringify({ chat_id: chatId, text }),
      // Bound the wait: the route awaits a rate-limited sendMessage whose 429
      // backoff can otherwise hold the connection open, and a Stop hook must
      // not linger and delay session teardown.
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
    if (!response.ok) return false
    let body: unknown
    try {
      body = await response.json()
    } catch {
      // Unparseable body on a 200 — cannot confirm the send → do NOT dedup.
      return false
    }
    if (body === null || typeof body !== 'object') return false
    return (body as Record<string, unknown>).status === 'sent'
  } catch {
    return false
  }
}

async function main(): Promise<void> {
  // A nested `claude -p` spawned by our own tooling (e.g. the memory pilot's
  // question/judge generation) must not forward its final text to the user —
  // that leaks internal JSON into the chat. The spawner sets this to opt out.
  if (process.env.DASHI_SUPPRESS_FALLBACK === '1') return
  let raw = ''
  try {
    raw = await readStdin()
  } catch {
    warn('stdin read failed')
    return
  }
  if (raw.trim().length === 0) return

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    warn('stdin not valid JSON')
    return
  }
  if (typeof parsed !== 'object' || parsed === null) return
  const fields = parsed as Record<string, unknown>
  const transcriptPath = fields.transcript_path
  if (typeof transcriptPath !== 'string' || transcriptPath.length === 0) return
  const sessionId = typeof fields.session_id === 'string' ? fields.session_id : ''

  // Merge the env file UNDER the process env (same precedence as
  // read-receipt-hook): the env-file supplies token/port when the process env
  // lacks them, while real process env wins where both define a key.
  const fileVars = loadChannelEnvFile(process.env)
  const env: Record<string, string | undefined> = { ...fileVars, ...process.env }

  // Bounded retry. Two races, same fix — re-read until the latest assistant
  // text STABILISES (unchanged across two reads), not just until it is non-empty:
  //   1. extended-thinking: [thinking] flushes first, [text] a beat later → an
  //      early read sees no text (stop-to-outbox.py's original case).
  //   2. lost-final (2026-06-22): a turn emits an interim narrative line, then
  //      tool calls, then the FINAL text. A Stop hook that reads after the
  //      interim flushed but before the final flushed grabs the STALE interim,
  //      forwards it, writes dedup — and the final, landing a beat later, gets
  //      no second Stop → silently lost. Breaking on first-non-empty caused this.
  // A genuinely text-less turn (pure tool / pure thinking) just exhausts the
  // budget. Knobs are upper-clamped so an oversized value cannot hang the hook.
  const attempts = envInt(env, 'FALLBACK_REPLY_RETRY_ATTEMPTS', 8, 1, 50)
  const delayMs = envInt(env, 'FALLBACK_REPLY_RETRY_DELAY_MS', 120, 0, 2000)

  let turn: TurnResult = { replied: false, textIsTrailing: false }
  // FIX 3: cap the CUMULATIVE sleep at a hard ceiling regardless of the
  // attempts×delay knob product (up to 50×2000 = 100s otherwise). Once the
  // budget is exhausted we stop sleeping but still run the remaining read
  // attempts back-to-back, so a transcript that lands late is still picked up
  // without hanging the synchronous Stop hook.
  const SLEEP_BUDGET_MS = 6000
  let sleptMs = 0
  let prevText: string | undefined
  for (let attempt = 0; attempt < attempts; attempt++) {
    let transcript = ''
    try {
      transcript = tailReadTranscript(transcriptPath)
    } catch {
      // FIX 4: a transient read/write race must NOT abort the whole retry
      // loop. Skip to the next attempt; only give up after all attempts are
      // exhausted (bounded by the FIX 3 sleep budget).
      if (attempt < attempts - 1 && delayMs > 0 && sleptMs < SLEEP_BUDGET_MS) {
        await sleep(delayMs)
        sleptMs += delayMs
      }
      continue
    }
    turn = analyzeCurrentTurn(transcript)
    // A reply already reached the warchief this turn → never fall back.
    if (turn.replied) return
    const cur = turn.text?.trim() ?? ''
    // Settled: non-empty, identical to the previous read, AND trailing (no tool
    // cycle after it). A stable interim that is followed by tool_use/tool_result
    // means the model is mid-turn and the real final has not flushed yet — keep
    // retrying within the budget rather than forwarding the interim as final.
    if (cur.length > 0 && cur === prevText && turn.textIsTrailing) break
    if (cur.length > 0) prevText = cur
    if (attempt < attempts - 1 && delayMs > 0 && sleptMs < SLEEP_BUDGET_MS) {
      await sleep(delayMs)
      sleptMs += delayMs
    }
  }

  // BUG 1 — final anti-duplicate guard. The retry loop can BREAK on a stable,
  // TRAILING interim text a beat BEFORE the turn's reply tool_use line is
  // durably flushed to the transcript: the model emits the final text and then
  // delivers it via `mcp__dashi-channel__reply` as its last action. At that
  // instant `replied` reads false (the reply block hasn't landed yet) and the
  // hook would forward a duplicate of what reply already sent. The turn-walk
  // itself is correct on a COMPLETE transcript — the miss is purely a flush
  // race — so we take ONE more fresh read (after a short settle) and abort if
  // the reply signal is now present. A genuinely reply-less turn just
  // re-confirms `replied === false` here and proceeds to forward as before.
  try {
    const settle = Math.min(delayMs || 120, Math.max(0, SLEEP_BUDGET_MS - sleptMs))
    if (settle > 0) await sleep(settle)
    const finalTurn = analyzeCurrentTurn(tailReadTranscript(transcriptPath))
    if (finalTurn.replied) return
    // Prefer the freshest turn view (text/uuid/chatId) when it still carries
    // final text; otherwise keep the last good `turn` from the loop.
    if (finalTurn.text !== undefined && finalTurn.text.trim().length > 0) turn = finalTurn
  } catch {
    /* a transient re-read failure must not gate delivery — keep last `turn` */
  }

  // Remember the chat_id from any Telegram-anchored turn so background-triggered
  // turns (task-notification boundary, no envelope) can still reach the user.
  const lastPath = lastChatPath(env)
  if (turn.chatId !== undefined) persistLastChat(lastPath, turn.chatId)

  if (turn.replied) return
  const rawText = turn.text
  if (rawText === undefined || rawText.trim().length === 0) return
  // BUG 2 — never forward leaked tool-call machinery. Strip `<invoke …>` /
  // `<parameter …>` blocks from a malformed-tool-call text; if only junk/empty
  // survives, stay silent instead of posting the raw syntax to the warchief.
  const text = sanitizeForForward(rawText)
  if (text === undefined || text.trim().length === 0) return
  // chat_id from the turn boundary, else the last DM chat_id we saw — never
  // for a background task-notification turn (see resolveFallbackChat). Silent
  // when no destination remains (e.g. a group session with no prior anchor).
  const chatId = resolveFallbackChat(turn, () => readLastChat(lastPath))
  if (chatId === undefined) return

  const config = resolveFallbackConfig(env)
  if ('kind' in config && config.kind === 'error') {
    warn(config.reason)
    return
  }

  // FIX 6: fold the boundary prompt text into the dedup token so two different
  // turns with identical assistant text but no uuid don't collide.
  const token = dedupeToken(turn.uuid, text, turn.promptText)
  const next: DedupState = {
    session_id: sessionId,
    transcript_path: transcriptPath,
    dedupe_token: token,
  }
  const statePath = resolveStatePath(env, sessionId)
  if (statePath) {
    const prior = loadDedupState(statePath)
    if (alreadyForwarded(prior, next)) return
  }

  // FIX 5: truncate-with-marker so a >4096-char answer delivers SOMETHING
  // rather than 400-dropping at the route's schema cap.
  const parts = splitForTelegram(text)
  const send = (toChat: string, body: string): Promise<boolean> =>
    postFallback(config as FallbackConfig, toChat, body)
  // Deliver every part in order. On the first failure, park the REMAINDER (the
  // part that failed plus everything after it) so a retry resumes where the send
  // stopped instead of re-sending what already landed.
  let ok = true
  let outText = parts[0] ?? ''
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i] as string
    if (await send(chatId, part)) continue
    ok = false
    outText = parts.slice(i).join('\n')
    break
  }
  if (ok && statePath) persistDedupState(statePath, next)
  const undeliveredDir = resolveUndeliveredDir(env, statePath)
  if (!ok && undeliveredDir) {
    // FIX 7: a Stop fires once per turn, so "skip dedup and hope for a retry"
    // lost the answer outright. Park it; the next run drains it.
    parkUndelivered(undeliveredDir, {
      chat_id: chatId,
      text: outText,
      session_id: sessionId,
      transcript_path: transcriptPath,
      dedupe_token: token,
      state_path: statePath,
      first_failed_at: new Date().toISOString(),
      attempts: 1,
    })
    warn('send unconfirmed — answer parked for retry')
  }
  if (ok && undeliveredDir) {
    // Drain AFTER the fresh answer so the current turn is never delayed behind
    // a backlog, and ONLY when this turn's own send succeeded — the route is
    // clearly down otherwise, and re-hitting it (including the record just
    // parked) would double the load for nothing. Writing dedup state on success
    // keeps a parked answer from being sent twice.
    await retryUndelivered(undeliveredDir, send, (record) => {
      if (record.state_path && record.dedupe_token) {
        persistDedupState(record.state_path, {
          session_id: record.session_id ?? '',
          transcript_path: record.transcript_path ?? '',
          dedupe_token: record.dedupe_token,
        })
      }
    })
  }
}

// ─────────────────────────────────────────────────────────────────────
// FIX 7 (2026-09-19): an undelivered answer must be quarantined and retried,
// never dropped. Until today a failed send only skipped the dedup write and
// hoped a LATER Stop fire for the same turn would retry — but a turn fires Stop
// once, so a transient Telegram/route failure meant the answer was gone with no
// trace. Now the payload is parked as a file and every subsequent hook run (a
// later turn, or the 2-minute sweeper) drains the quarantine first.
// ─────────────────────────────────────────────────────────────────────

const UNDELIVERED_MAX_ATTEMPTS = 10
const UNDELIVERED_MAX_AGE_MS = 24 * 60 * 60 * 1000
/** Per-run drain cap: a Stop hook must not linger behind a long backlog. */
const UNDELIVERED_DRAIN_PER_RUN = 5

export interface UndeliveredRecord {
  readonly chat_id: string
  readonly text: string
  readonly session_id?: string
  readonly transcript_path?: string
  readonly dedupe_token?: string
  readonly state_path?: string | undefined
  readonly first_failed_at: string
  readonly attempts: number
}

/**
 * Quarantine directory for answers whose send did not confirm. It sits NEXT TO
 * the dedup state file, so an explicit TELEGRAM_FALLBACK_REPLY_STATE (tests, a
 * pinned state path) keeps its quarantine in the same place and never writes
 * into the shared runtime dir.
 */
export function resolveUndeliveredDir(
  env: Readonly<Record<string, string | undefined>>,
  statePath?: string,
): string | undefined {
  if (statePath) return join(dirname(statePath), 'undelivered')
  const base = env.TELEGRAM_STATE_DIR ?? env.MULTICHAT_STATE_DIR
  if (!base) return undefined
  return join(base, 'fallback-reply', 'undelivered')
}

/**
 * Park an unconfirmed answer in the quarantine. Best-effort: a failure here is
 * logged and swallowed — parking must never throw out of the Stop hook.
 */
export function parkUndelivered(dir: string, record: UndeliveredRecord): string | undefined {
  try {
    mkdirSync(dir, { recursive: true })
    const name = `${Date.now()}-${Math.random().toString(16).slice(2, 6)}.json`
    const path = join(dir, name)
    writeFileSync(path, JSON.stringify(record), 'utf8')
    return path
  } catch (err) {
    warn(`park failed: ${err instanceof Error ? err.message : 'unknown'}`)
    return undefined
  }
}

/**
 * Drain the quarantine: oldest first, at most UNDELIVERED_DRAIN_PER_RUN per run.
 *
 * A delivered record is unlinked and its dedup state written through
 * `onDelivered`, so the same answer can never be sent twice (once from the
 * quarantine, once from a later transcript read). A record that fails again has
 * its attempt counter bumped; one that is too old or has burnt its attempts is
 * renamed to `*.failed` so it stops consuming the budget but stays readable.
 *
 * Returns how many records were actually delivered.
 */
export async function retryUndelivered(
  dir: string,
  send: (chatId: string, text: string) => Promise<boolean>,
  onDelivered?: (record: UndeliveredRecord) => void,
  now: number = Date.now(),
): Promise<number> {
  let names: string[]
  try {
    names = readdirSync(dir)
      .filter((n) => n.endsWith('.json'))
      .sort()
  } catch {
    return 0 // No quarantine dir — nothing to drain.
  }
  let delivered = 0
  for (const name of names.slice(0, UNDELIVERED_DRAIN_PER_RUN)) {
    const path = join(dir, name)
    let record: UndeliveredRecord
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'))
      if (parsed === null || typeof parsed !== 'object') throw new Error('not an object')
      record = parsed as UndeliveredRecord
      if (typeof record.chat_id !== 'string' || typeof record.text !== 'string') {
        throw new Error('missing chat_id/text')
      }
    } catch {
      // Unreadable/corrupt payload: retiring it keeps the queue moving.
      try {
        renameSync(path, `${path}.failed`)
      } catch {
        /* ignore */
      }
      continue
    }
    const firstFailedMs = Date.parse(record.first_failed_at ?? '')
    const tooOld = Number.isFinite(firstFailedMs) && now - firstFailedMs > UNDELIVERED_MAX_AGE_MS
    const attempts = typeof record.attempts === 'number' ? record.attempts : 0
    if (tooOld || attempts >= UNDELIVERED_MAX_ATTEMPTS) {
      warn(`undelivered retired after ${attempts} attempts`)
      try {
        renameSync(path, `${path}.failed`)
      } catch {
        /* ignore */
      }
      continue
    }
    let ok = false
    try {
      ok = await send(record.chat_id, record.text)
    } catch {
      ok = false
    }
    if (ok) {
      delivered += 1
      try {
        onDelivered?.(record)
      } catch {
        /* dedup bookkeeping must not undo a successful send */
      }
      try {
        unlinkSync(path)
      } catch {
        /* ignore */
      }
      continue
    }
    try {
      writeFileSync(path, JSON.stringify({ ...record, attempts: attempts + 1 }), 'utf8')
    } catch {
      /* ignore */
    }
  }
  return delivered
}

const isMainModule = (() => {
  try {
    const arg = process.argv[1] ?? ''
    return arg.endsWith('fallback-reply-hook.ts') || arg.endsWith('fallback-reply-hook.js')
  } catch {
    return false
  }
})()

if (isMainModule) {
  await main().catch((err) => {
    warn(err instanceof Error ? err.message : 'unknown error')
  })
}
