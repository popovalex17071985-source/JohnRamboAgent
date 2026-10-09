import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  armReloginPending,
  clearReloginPending,
  findOauthUrl,
  isReloginPending,
  looksLikeOauthCode,
  paneTail,
  redactSecret,
  reloginPendingRemainingMs,
  runReloginFlow,
  RELOGIN_PENDING_TTL_MS,
  type ReloginIo,
} from '../../src/commands/relogin.js'
import { handleOobCommand, parseOobCommand, type OobContext } from '../../src/commands/oob.js'
import type { TelegramApi } from '../../src/channel/tools.js'
import { makeConfig, makeLogger } from '../helpers/config.js'

// ─────────────────────────────────────────────────────────────────────
// looksLikeOauthCode — the gate that decides whether an inbound DM is
// typed into the pane as a credential or forwarded to Claude as text.
// ─────────────────────────────────────────────────────────────────────

describe('looksLikeOauthCode', () => {
  test('accepts a realistic code#state token', () => {
    expect(
      looksLikeOauthCode('ac_7Gh2kLm9Qw4Rt6Yu8Io0Pa#st_Zx3Cv5Bn7Mm1Qq2Ww4Ee'),
    ).toBe(true)
  })

  test('rejects a long token WITHOUT # — Claude codes are always code#state', () => {
    expect(looksLikeOauthCode('AbCdEfGhIjKlMnOpQrStUvWxYz012345')).toBe(false)
  })

  test('rejects pure-hex strings (git hashes), with or without case mix', () => {
    expect(looksLikeOauthCode('a10ea3fdb691542c8f56f6b89ea0c123')).toBe(false)
    expect(looksLikeOauthCode('A10EA3FDB691542C8F56F6B89EA0C123')).toBe(false)
  })

  test('tolerates surrounding whitespace from a sloppy paste', () => {
    expect(looksLikeOauthCode('  ac_7Gh2kLm9Qw4Rt6Yu8Io0Pa#st_Zx3Cv5Bn7  ')).toBe(true)
  })

  test('rejects short tokens (<= 20 chars)', () => {
    expect(looksLikeOauthCode('abc#def')).toBe(false)
    expect(looksLikeOauthCode('a'.repeat(20))).toBe(false)
  })

  test('rejects ordinary sentences (whitespace)', () => {
    expect(looksLikeOauthCode('привет, как дела, что там с прайсом')).toBe(false)
    expect(looksLikeOauthCode('deploy the thing to production now')).toBe(false)
  })

  test('rejects URLs (charset excludes : / .)', () => {
    expect(looksLikeOauthCode('https://claude.ai/oauth/authorize?code=x')).toBe(false)
  })

  test('rejects slash commands even when long enough', () => {
    expect(looksLikeOauthCode('/superpowers:brainstorming-long-command')).toBe(false)
  })

  test('rejects long Cyrillic words', () => {
    expect(looksLikeOauthCode('человеконенавистничество#да')).toBe(false)
  })
})

// ─────────────────────────────────────────────────────────────────────
// findOauthUrl
// ─────────────────────────────────────────────────────────────────────

describe('findOauthUrl', () => {
  test('extracts the OAuth URL out of pane noise', () => {
    const pane = [
      'Paste code here if prompted:',
      'Browser did not open? Use the url below',
      'https://claude.ai/oauth/authorize?code=true&client_id=abc123&scope=org',
      '? for shortcuts',
    ].join('\n')
    expect(findOauthUrl(pane)).toBe(
      'https://claude.ai/oauth/authorize?code=true&client_id=abc123&scope=org',
    )
  })

  test('matches subdomain form (…console.claude.ai/oauth…)', () => {
    expect(findOauthUrl('go https://console.claude.ai/oauth/x?y=1 now')).toBe(
      'https://console.claude.ai/oauth/x?y=1',
    )
  })

  test('returns undefined when no URL on screen', () => {
    expect(findOauthUrl('Login expired · Please run /login')).toBeUndefined()
  })
})

// ─────────────────────────────────────────────────────────────────────
// relogin-pending flag: arm / TTL / clear.
// ─────────────────────────────────────────────────────────────────────

describe('relogin-pending flag', () => {
  test('arm → pending → clear lifecycle', () => {
    const dir = mkdtempSync(join(tmpdir(), 'relogin-flag-'))
    try {
      expect(isReloginPending(dir)).toBe(false)
      armReloginPending(dir)
      expect(isReloginPending(dir)).toBe(true)
      clearReloginPending(dir)
      expect(isReloginPending(dir)).toBe(false)
      // Idempotent clear must not throw.
      clearReloginPending(dir)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('flag expires after the 15-min TTL', () => {
    const dir = mkdtempSync(join(tmpdir(), 'relogin-flag-'))
    try {
      armReloginPending(dir)
      const stale = (Date.now() - RELOGIN_PENDING_TTL_MS - 1000) / 1000
      utimesSync(join(dir, 'relogin-pending'), stale, stale)
      expect(isReloginPending(dir)).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// ─────────────────────────────────────────────────────────────────────
// Helpers used by the failure replies.
// ─────────────────────────────────────────────────────────────────────

describe('paneTail / redactSecret', () => {
  test('paneTail keeps the last N content lines, drops blank bottom', () => {
    const capture = [...Array.from({ length: 30 }, (_, i) => `line${i}`), '', '', ''].join('\n')
    const tail = paneTail(capture, 15)
    expect(tail.split('\n')).toHaveLength(15)
    expect(tail.endsWith('line29')).toBe(true)
  })

  test('redactSecret scrubs every occurrence of the code', () => {
    const code = 'ac_7Gh2kLm9Qw4Rt6Yu8Io0Pa#st_Zx3'
    const tail = `> ${code}\nsomething\n${code} again`
    const scrubbed = redactSecret(tail, code)
    expect(scrubbed).not.toContain(code)
    expect(scrubbed).toContain('•••')
  })
})

// ─────────────────────────────────────────────────────────────────────
// runReloginFlow — flag-arming order. The flag opens a 15-min window in
// which code-shaped DMs are typed into the pane instead of reaching
// Claude, so it must arm ONLY after the link send actually landed.
// ─────────────────────────────────────────────────────────────────────

function makeFlowIo(
  dir: string,
  sendMessage: TelegramApi['sendMessage'],
): ReloginIo {
  const pane = [
    'Browser did not open? Use the url below',
    'https://claude.ai/oauth/authorize?code=true&client_id=abc',
  ].join('\n')
  return {
    target: { paneTarget: '%1', socketPath: '/tmp/fake-sock' },
    chatId: '164795011',
    stateDir: dir,
    telegramApi: { ...makeTelegramApi(), sendMessage },
    log: makeLogger(),
    exec: async () => ({ exitCode: 0, stderr: '' }),
    captureExec: async () => ({ exitCode: 0, stdout: pane, stderr: '' }),
    sleep: async () => {},
  }
}

describe('runReloginFlow — flag arming', () => {
  test('link delivered → flag armed', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'relogin-flow-'))
    try {
      const io = makeFlowIo(dir, async () => ({ message_id: 1 }))
      await runReloginFlow(io)
      expect(isReloginPending(dir)).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('link send FAILED → flag stays un-armed (no silent interception window)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'relogin-flow-'))
    try {
      const io = makeFlowIo(dir, async () => {
        throw new Error('telegram down')
      })
      await runReloginFlow(io)
      expect(isReloginPending(dir)).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// ─────────────────────────────────────────────────────────────────────
// OOB wiring: /relogin and /restart parse + /restart handler behaviour.
// ─────────────────────────────────────────────────────────────────────

function makeTelegramApi(): TelegramApi {
  const fail = (name: string) => {
    return (): never => {
      throw new Error(`unexpected TelegramApi call: ${name}`)
    }
  }
  return {
    sendMessage: fail('sendMessage') as TelegramApi['sendMessage'],
    sendRichMessage: fail('sendRichMessage') as TelegramApi['sendRichMessage'],
    editMessageText: fail('editMessageText') as TelegramApi['editMessageText'],
    setMessageReaction: fail('setMessageReaction') as TelegramApi['setMessageReaction'],
    sendChatAction: fail('sendChatAction') as TelegramApi['sendChatAction'],
    sendDocument: fail('sendDocument') as TelegramApi['sendDocument'],
    sendPhoto: fail('sendPhoto') as TelegramApi['sendPhoto'],
    downloadFile: fail('downloadFile') as TelegramApi['downloadFile'],
    deleteMessage: fail('deleteMessage') as TelegramApi['deleteMessage'],
    answerGuestQuery: fail('answerGuestQuery') as TelegramApi['answerGuestQuery'],
  }
}

function makeCtx(overrides: Partial<OobContext> = {}): OobContext {
  return {
    chatId: '164795011',
    senderId: '164795011',
    config: makeConfig(),
    telegramApi: makeTelegramApi(),
    log: makeLogger(),
    botId: 8507713167,
    stateDir: '/tmp/state',
    ...overrides,
  }
}

describe('oob /relogin and /restart', () => {
  test('parseOobCommand recognises both', () => {
    expect(parseOobCommand('/relogin')!.name).toBe('relogin')
    expect(parseOobCommand('/restart')!.name).toBe('restart')
  })

  test('/relogin without tmux pane explains unavailability', async () => {
    const res = await handleOobCommand(parseOobCommand('/relogin')!, makeCtx())
    expect(res.command).toBe('relogin')
    expect(res.replyToTelegram!.text).toContain('недоступно')
  })

  test('/relogin while the flag is live refuses a second flow', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'relogin-guard-'))
    try {
      armReloginPending(dir)
      expect(reloginPendingRemainingMs(dir)).toBeGreaterThan(0)
      const ctx = makeCtx({
        stateDir: dir,
        tmuxKeys: {
          target: { paneTarget: '%1', socketPath: '/tmp/fake-sock' },
          // Seams present so an accidental flow launch would use fakes, not
          // real tmux — but the guard must return BEFORE any exec happens.
          exec: async () => {
            throw new Error('flow must not run')
          },
          captureExec: async () => {
            throw new Error('flow must not run')
          },
          sleep: async () => {},
        },
      })
      const res = await handleOobCommand(parseOobCommand('/relogin')!, ctx)
      expect(res.replyToTelegram!.text).toContain('уже жду код')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test('/restart without a ctl script replies gracefully, spawns nothing', async () => {
    const spawned: string[] = []
    const ctx = makeCtx({
      restart: {
        agentId: 'canary',
        fileExists: () => false,
        spawnDetached: (cmd) => {
          spawned.push(cmd)
        },
      },
    })
    const res = await handleOobCommand(parseOobCommand('/restart')!, ctx)
    expect(res.replyToTelegram!.text).toContain('нет штатного dashi-ctl')
    expect(spawned).toHaveLength(0)
  })

  test('/restart with ctl present spawns the detached restart', async () => {
    const calls: Array<{ cmd: string; args: readonly string[] }> = []
    const ctx = makeCtx({
      restart: {
        agentId: 'canary',
        fileExists: (p) => p === '/usr/local/bin/dashi-ctl-canary',
        spawnDetached: (cmd, args) => {
          calls.push({ cmd, args })
        },
      },
    })
    const res = await handleOobCommand(parseOobCommand('/restart')!, ctx)
    expect(res.replyToTelegram!.text).toContain('перезапускаю')
    expect(calls).toHaveLength(1)
    expect(calls[0]!.cmd).toBe('bash')
    // The ctl path travels as $0 — never interpolated into the script text.
    expect(calls[0]!.args[calls[0]!.args.length - 1]).toBe('/usr/local/bin/dashi-ctl-canary')
  })

  // These cover the dashi-ctl fallback: the planner from FETCH_HEAD is reported
  // unreachable, exactly as when the fetch fails or the fresh version has none.
  const UNAVAILABLE = async () => ({ kind: 'unavailable' as const, reason: 'test' })

  test('/update without a ctl script replies gracefully, runs nothing', async () => {
    let ran = 0
    const ctx = makeCtx({
      restart: {
        agentId: 'canary',
        fileExists: () => false,
        runCtl: async () => { ran++; return { code: 0, out: 'UPTODATE' } },
        runPlanner: UNAVAILABLE,
      },
    })
    const res = await handleOobCommand(parseOobCommand('/update')!, ctx)
    expect(res.replyToTelegram!.text).toContain('нет штатного dashi-ctl')
    expect(ran).toBe(0)
  })

  test('/update DIRTY → refuses, names files, no restart; force passes the flag', async () => {
    const calls: string[][] = []
    const spawned: string[] = []
    const ctx = makeCtx({
      restart: {
        agentId: 'canary',
        fileExists: (p) => p === '/usr/local/bin/dashi-ctl-canary',
        runCtl: async (_ctl, args) => { calls.push([...args]); return { code: 3, out: 'DIRTY plugin/src/x.ts\n' } },
        runPlanner: UNAVAILABLE,
        spawnDetached: (cmd) => { spawned.push(cmd) },
      },
    })
    const res = await handleOobCommand(parseOobCommand('/update')!, ctx)
    expect(res.replyToTelegram!.text).toContain('plugin/src/x.ts')
    expect(res.replyToTelegram!.text).toContain('/update force')
    expect(spawned).toHaveLength(0)
    await handleOobCommand(parseOobCommand('/update force')!, ctx)
    expect(calls).toEqual([['update'], ['update', 'force']])
  })

  test('/update UPDATED → reports sha and schedules the detached restart', async () => {
    const calls: Array<{ cmd: string; args: readonly string[] }> = []
    const ctx = makeCtx({
      restart: {
        agentId: 'canary',
        fileExists: (p) => p === '/usr/local/bin/dashi-ctl-canary',
        runCtl: async () => ({ code: 0, out: 'UPDATED 3 abc1234\n' }),
        runPlanner: UNAVAILABLE,
        spawnDetached: (cmd, args) => { calls.push({ cmd, args }) },
      },
    })
    const res = await handleOobCommand(parseOobCommand('/update')!, ctx)
    expect(res.replyToTelegram!.text).toContain('abc1234')
    expect(res.replyToTelegram!.text).toContain('перезапускаю')
    expect(calls).toHaveLength(1)
    expect(calls[0]!.args[calls[0]!.args.length - 1]).toBe('/usr/local/bin/dashi-ctl-canary')
  })

  test('/update UPTODATE and ROLLBACK → plain replies, no restart', async () => {
    for (const [out, expected] of [['UPTODATE', 'последняя версия'], ['ROLLBACK', 'откатил']] as const) {
      const spawned: string[] = []
      const ctx = makeCtx({
        restart: {
          agentId: 'canary',
          fileExists: () => true,
          runCtl: async () => ({ code: 0, out }),
          runPlanner: UNAVAILABLE,
          spawnDetached: (cmd) => { spawned.push(cmd) },
        },
      })
      const res = await handleOobCommand(parseOobCommand('/update')!, ctx)
      expect(res.replyToTelegram!.text).toContain(expected)
      expect(spawned).toHaveLength(0)
    }
  })
})
