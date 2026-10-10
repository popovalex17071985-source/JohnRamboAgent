// Bridge on-disk log (JSONL) — the MCP host only keeps the bridge's stderr
// for the first moments after start, so long-running lines such as
// «idle compact attempt / sent ok / failed» were lost. The logger now also
// appends one JSON object per line to <state>/logs/bridge.jsonl with
// size-capped rotation. These tests pin that contract.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Writable } from 'stream'

import { getStatePaths, type AppConfig, type RuntimeEnv } from '../src/config.js'
import {
  BRIDGE_LOG_KEEP_FILES,
  BRIDGE_LOG_MAX_BYTES,
  createJsonlFileSink,
  createLogger,
} from '../src/log.js'

let dir: string

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'dashi-bridge-log-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function captureStream(): { stream: Writable; text: () => string } {
  const chunks: string[] = []
  const stream = new Writable({
    write(chunk, _enc, cb) {
      chunks.push(String(chunk))
      cb()
    },
  })
  return { stream, text: () => chunks.join('') }
}

function readJsonl(path: string): Array<Record<string, unknown>> {
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter(l => l.length > 0)
    .map(l => JSON.parse(l) as Record<string, unknown>)
}

describe('createLogger with filePath', () => {
  test('appends one JSON object per line and still writes to the stream', () => {
    const file = join(dir, 'bridge.jsonl')
    const cap = captureStream()
    const log = createLogger('dashi-channel', { stream: cap.stream, filePath: file })

    log.info('idle compact attempt', { used_tokens: 123, idle_minutes: 7 })
    log.warn('idle compact failed', { reason: 'busy' })

    const rows = readJsonl(file)
    expect(rows).toHaveLength(2)
    expect(rows[0]).toMatchObject({
      level: 'info',
      name: 'dashi-channel',
      msg: 'idle compact attempt',
      ctx: { used_tokens: 123, idle_minutes: 7 },
    })
    expect(typeof rows[0]!.ts).toBe('string')
    expect(Number.isNaN(Date.parse(String(rows[0]!.ts)))).toBe(false)
    expect(rows[1]).toMatchObject({ level: 'warn', msg: 'idle compact failed' })
    expect(cap.text()).toContain('idle compact attempt')
  })

  test('omits ctx when none is given', () => {
    const file = join(dir, 'bridge.jsonl')
    const log = createLogger('t', { stream: captureStream().stream, filePath: file })
    log.info('plain line')
    const rows = readJsonl(file)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.msg).toBe('plain line')
    expect('ctx' in rows[0]!).toBe(false)
  })

  test('respects the level threshold (debug is not written at default info)', () => {
    const prev = process.env.LOG_LEVEL
    delete process.env.LOG_LEVEL
    try {
      const file = join(dir, 'bridge.jsonl')
      const log = createLogger('t', { stream: captureStream().stream, filePath: file })
      log.debug('noise')
      log.info('signal')
      const rows = readJsonl(file)
      expect(rows.map(r => r.msg)).toEqual(['signal'])
    } finally {
      if (prev !== undefined) process.env.LOG_LEVEL = prev
    }
  })

  test('redacts pattern secrets and exact-substring secrets in the file', () => {
    const file = join(dir, 'bridge.jsonl')
    const botToken = '123456789:AAHfakeTokenValue_abcdefghijklmnopqrstu'
    const webhookSecret = 'my-very-private-webhook-secret-xyz'
    const log = createLogger('t', {
      stream: captureStream().stream,
      filePath: file,
      secrets: [webhookSecret],
    })
    log.error(`failed with ${botToken}`, { header: webhookSecret, nested: { t: botToken } })

    const raw = readFileSync(file, 'utf8')
    expect(raw).not.toContain(botToken)
    expect(raw).not.toContain(webhookSecret)
    // Still valid JSON after redaction.
    const rows = readJsonl(file)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.level).toBe('error')
  })

  test('creates the file owner-only (0600)', () => {
    const file = join(dir, 'bridge.jsonl')
    const log = createLogger('t', { stream: captureStream().stream, filePath: file })
    log.info('x')
    expect(statSync(file).mode & 0o777).toBe(0o600)
  })

  test('a write failure never throws and the stream still gets the line', () => {
    // Parent "directory" is a regular file -> every append fails with ENOTDIR.
    const blocker = join(dir, 'not-a-dir')
    writeFileSync(blocker, '')
    const file = join(blocker, 'bridge.jsonl')
    const cap = captureStream()
    const log = createLogger('t', { stream: cap.stream, filePath: file })

    expect(() => {
      log.info('first')
      log.error('second', { a: 1 })
    }).not.toThrow()
    expect(cap.text()).toContain('first')
    expect(cap.text()).toContain('second')
  })

  test('creates a missing parent directory on first write', () => {
    const file = join(dir, 'logs', 'nested', 'bridge.jsonl')
    const log = createLogger('t', { stream: captureStream().stream, filePath: file })
    log.info('hello')
    expect(readJsonl(file)).toHaveLength(1)
  })
})

describe('size-capped rotation', () => {
  test('defaults are a few MB and keep 1-2 old files', () => {
    expect(BRIDGE_LOG_MAX_BYTES).toBeGreaterThanOrEqual(1024 * 1024)
    expect(BRIDGE_LOG_MAX_BYTES).toBeLessThanOrEqual(16 * 1024 * 1024)
    expect(BRIDGE_LOG_KEEP_FILES).toBeGreaterThanOrEqual(1)
    expect(BRIDGE_LOG_KEEP_FILES).toBeLessThanOrEqual(2)
  })

  test('rotates file -> file.1 -> file.2 and never keeps more than `keep` old files', () => {
    const file = join(dir, 'bridge.jsonl')
    const maxBytes = 400
    const log = createLogger('t', {
      stream: captureStream().stream,
      filePath: file,
      fileMaxBytes: maxBytes,
      fileKeep: 2,
    })
    for (let i = 0; i < 60; i++) log.info(`line ${i}`, { pad: 'x'.repeat(40) })

    expect(existsSync(file)).toBe(true)
    expect(existsSync(`${file}.1`)).toBe(true)
    expect(existsSync(`${file}.2`)).toBe(true)
    expect(existsSync(`${file}.3`)).toBe(false)
    for (const p of [file, `${file}.1`, `${file}.2`]) {
      expect(statSync(p).size).toBeLessThanOrEqual(maxBytes)
      // Every rotated file is still whole JSON lines.
      expect(() => readJsonl(p)).not.toThrow()
    }
    // Newest line lives in the live file.
    const live = readJsonl(file)
    expect(live[live.length - 1]!.msg).toBe('line 59')
  })

  test('rotation honours a file that already existed before start', () => {
    const file = join(dir, 'bridge.jsonl')
    writeFileSync(file, `${JSON.stringify({ msg: 'old' })}\n`.repeat(20))
    const before = statSync(file).size
    const log = createLogger('t', {
      stream: captureStream().stream,
      filePath: file,
      fileMaxBytes: before + 10,
      fileKeep: 1,
    })
    log.info('new line that does not fit')
    expect(existsSync(`${file}.1`)).toBe(true)
    expect(readJsonl(`${file}.1`)[0]!.msg).toBe('old')
    expect(readJsonl(file).map(r => r.msg)).toEqual(['new line that does not fit'])
  })
})

describe('createJsonlFileSink (crash handlers)', () => {
  test('writes a redacted JSON line and swallows failures', () => {
    const file = join(dir, 'bridge.jsonl')
    const secret = 'sekret-value-for-crash-path'
    const sink = createJsonlFileSink(file, { secrets: [secret] })
    sink('error', 'dashi-channel', `uncaught exception: boom ${secret}`)
    const rows = readJsonl(file)
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ level: 'error', name: 'dashi-channel' })
    expect(readFileSync(file, 'utf8')).not.toContain(secret)

    mkdirSync(join(dir, 'dir-as-file'))
    const broken = createJsonlFileSink(join(dir, 'dir-as-file'))
    expect(() => broken('error', 'x', 'y')).not.toThrow()
  })
})

describe('state paths + server wiring', () => {
  test('state paths put the bridge log at <state>/logs/bridge.jsonl', () => {
    const paths = getStatePaths({} as AppConfig, { TELEGRAM_STATE_DIR: dir } as RuntimeEnv)
    expect(paths.logs.server).toBe(join(dir, 'logs', 'bridge.jsonl'))
  })

  test('server.ts hands the bridge log path to the main logger', () => {
    const src = readFileSync(join(import.meta.dir, '..', 'src', 'server.ts'), 'utf8')
    expect(src).toMatch(
      /createLogger\('dashi-channel',\s*\{[^}]*filePath:\s*statePaths\.logs\.server/,
    )
  })
})
