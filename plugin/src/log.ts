// Redacted structured logger.
// Format: [ISO-ts] [level] [name] message {ctx-json}
// Output goes to stderr by default so it doesn't poison the MCP stdio transport.
//
// Optional on-disk copy (`filePath`): the MCP host keeps the bridge's stderr
// only for the first moments after start, so long-running lines (idle
// compact attempt / sent ok / failed, ...) used to vanish. With `filePath`
// set, every emitted line is ALSO appended as one JSON object to that file,
// redacted the same way, with size-capped rotation. A file write failure is
// swallowed — logging must never take the bridge down.

import { appendFileSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs'
import { dirname } from 'node:path'

import { redactToken } from './config.js'

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'

export interface Logger {
  debug(msg: string, ctx?: Record<string, unknown>): void
  info(msg: string, ctx?: Record<string, unknown>): void
  warn(msg: string, ctx?: Record<string, unknown>): void
  error(msg: string, ctx?: Record<string, unknown>): void
}

export interface CreateLoggerOptions {
  stream?: NodeJS.WritableStream
  // Exact-substring secrets to redact alongside the pattern-based ones
  // (Telegram bot token, Groq key, Bearer/query tokens). Useful for the
  // configured TELEGRAM_WEBHOOK_TOKEN which has no public pattern.
  secrets?: ReadonlyArray<string>
  // Also append each emitted line as JSON to this file (see header).
  filePath?: string
  // Rotation overrides — defaults are BRIDGE_LOG_MAX_BYTES / BRIDGE_LOG_KEEP_FILES.
  fileMaxBytes?: number
  fileKeep?: number
}

// Live file is rotated once the next line would push it past this size.
export const BRIDGE_LOG_MAX_BYTES = 5 * 1024 * 1024
// Rotated copies kept next to the live file: <file>.1 (newer) .. <file>.N.
export const BRIDGE_LOG_KEEP_FILES = 2
// Owner-only: the state dir also holds tokens and offsets.
const LOG_FILE_MODE = 0o600

export type JsonlFileSink = (
  level: LogLevel,
  name: string,
  msg: string,
  ctx?: Record<string, unknown>,
) => void

export interface JsonlFileSinkOptions {
  secrets?: ReadonlyArray<string>
  maxBytes?: number
  keep?: number
}

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
}

function envLevel(): LogLevel {
  const raw = (process.env.LOG_LEVEL ?? '').toLowerCase()
  if (raw === 'debug' || raw === 'info' || raw === 'warn' || raw === 'error') return raw
  return 'info'
}

function formatLine(
  name: string,
  level: LogLevel,
  msg: string,
  ctx: Record<string, unknown> | undefined,
  secrets: ReadonlyArray<string>,
): string {
  const ts = new Date().toISOString()
  let body = `[${ts}] [${level}] [${name}] ${msg}`
  if (ctx && Object.keys(ctx).length > 0) {
    let serialized: string
    try {
      serialized = JSON.stringify(ctx)
    } catch (err) {
      serialized = `<unserializable:${err instanceof Error ? err.message : String(err)}>`
    }
    body += ` ${redactToken(serialized, secrets)}`
  }
  return redactToken(body, secrets) + '\n'
}

function redactedCtx(
  ctx: Record<string, unknown>,
  secrets: ReadonlyArray<string>,
): unknown {
  let serialized: string
  try {
    serialized = JSON.stringify(ctx)
  } catch (err) {
    return `<unserializable:${err instanceof Error ? err.message : String(err)}>`
  }
  const redacted = redactToken(serialized, secrets)
  try {
    return JSON.parse(redacted) as unknown
  } catch {
    // Redaction broke the JSON shape — keep the redacted text as a string.
    return redacted
  }
}

function formatJsonLine(
  name: string,
  level: LogLevel,
  msg: string,
  ctx: Record<string, unknown> | undefined,
  secrets: ReadonlyArray<string>,
): string {
  const row: Record<string, unknown> = {
    ts: new Date().toISOString(),
    level,
    name,
    msg: redactToken(msg, secrets),
  }
  if (ctx && Object.keys(ctx).length > 0) row.ctx = redactedCtx(ctx, secrets)
  return JSON.stringify(row) + '\n'
}

function fileSize(path: string): number {
  try {
    return statSync(path).size
  } catch {
    return 0
  }
}

// <file>.{keep-1} -> <file>.{keep}, ..., <file> -> <file>.1; the oldest drops.
function rotate(path: string, keep: number): void {
  if (keep < 1) {
    rmSync(path, { force: true })
    return
  }
  rmSync(`${path}.${keep}`, { force: true })
  for (let i = keep - 1; i >= 1; i--) {
    try {
      renameSync(`${path}.${i}`, `${path}.${i + 1}`)
    } catch {
      // gap in the chain — nothing to shift
    }
  }
  renameSync(path, `${path}.1`)
}

/**
 * Append-only JSONL sink with size-capped rotation. Never throws: any fs
 * error (missing dir, read-only disk, ENOSPC) drops that one line.
 */
export function createJsonlFileSink(
  path: string,
  opts: JsonlFileSinkOptions = {},
): JsonlFileSink {
  const secrets = opts.secrets ?? []
  const maxBytes = opts.maxBytes ?? BRIDGE_LOG_MAX_BYTES
  const keep = opts.keep ?? BRIDGE_LOG_KEEP_FILES
  let dirReady = false
  return (level, name, msg, ctx) => {
    try {
      const line = formatJsonLine(name, level, msg, ctx, secrets)
      if (!dirReady) {
        mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
        dirReady = true
      }
      const size = fileSize(path)
      if (size > 0 && size + Buffer.byteLength(line) > maxBytes) rotate(path, keep)
      appendFileSync(path, line, { mode: LOG_FILE_MODE })
    } catch {
      // never let logging throw
    }
  }
}

export function createLogger(name: string, opts: CreateLoggerOptions = {}): Logger {
  const stream: NodeJS.WritableStream = opts.stream ?? process.stderr
  const threshold = LEVEL_ORDER[envLevel()]
  const secrets: ReadonlyArray<string> = opts.secrets ?? []
  const fileSink: JsonlFileSink | undefined =
    opts.filePath !== undefined
      ? createJsonlFileSink(opts.filePath, {
          secrets,
          ...(opts.fileMaxBytes !== undefined ? { maxBytes: opts.fileMaxBytes } : {}),
          ...(opts.fileKeep !== undefined ? { keep: opts.fileKeep } : {}),
        })
      : undefined
  const emit = (level: LogLevel, msg: string, ctx?: Record<string, unknown>): void => {
    if (LEVEL_ORDER[level] < threshold) return
    try {
      stream.write(formatLine(name, level, msg, ctx, secrets))
    } catch {
      // never let logging throw
    }
    fileSink?.(level, name, msg, ctx)
  }
  return {
    debug: (msg, ctx) => emit('debug', msg, ctx),
    info: (msg, ctx) => emit('info', msg, ctx),
    warn: (msg, ctx) => emit('warn', msg, ctx),
    error: (msg, ctx) => emit('error', msg, ctx),
  }
}
