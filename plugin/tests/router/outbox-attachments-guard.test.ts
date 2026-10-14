// Multichat outbox attachments: the file guard in
// MultichatRouter.sendOutboxFiles (secret denylist on the given path, no
// symlinks, regular files only, size cap, secret denylist again on the
// realpath). Per the warchief the secret denylist is the ONLY hard limit on
// what an agent may post into a (public) group, so the guard is the whole
// file-exfil defence on this path.
//
// Mutation audit 14.10.2026: sendOutboxFiles had no test at all — dropping
// the symlink refusal or the realpath re-check left the whole suite green.
// These tests call the private method directly with a spy API, so no timer
// or outbox polling is involved.
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import type { Logger } from '../../src/log.js'
import type { ChatPolicy, MultichatPolicy } from '../../src/chats/policy-loader.js'
import { MultichatRouter, type MultichatTelegramApi } from '../../src/router/multichat-router.js'
import type { TmuxSessionPool } from '../../src/router/tmux-session-pool.js'

const GROUP = '-1001234567890'

const chatPolicy: ChatPolicy = {
  mode: 'public',
  streaming: 'off',
  tmux_mirror: false,
  edit_message_progress: false,
  delivery: 'final_only',
  persona_file: 'persona.md',
  handoff_file: 'handoff.md',
  system_reminder: '',
  idle_ttl_ms: 1_800_000,
  max_queue_depth: 1,
}

const policy: MultichatPolicy = {
  version: 1,
  allowlist: { chats: [GROUP], users: ['164795011'] },
  mention_allowlist: ['164795011'],
  chats: { [GROUP]: chatPolicy },
}

function silentLogger(): Logger {
  const noop = (): void => {}
  return { debug: noop, info: noop, warn: noop, error: noop } as unknown as Logger
}

interface Sent {
  kind: 'doc' | 'photo'
  path: string
}

let tmp: string
let sent: Sent[]
let router: MultichatRouter

function sendFiles(files: string[]): Promise<void> {
  const r = router as unknown as {
    sendOutboxFiles(chatId: string, files: string[], origin: string): Promise<void>
  }
  return r.sendOutboxFiles(GROUP, files, 'test.json')
}

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), 'outbox-attach-'))
  sent = []
  const api = {
    sendMessage: async () => ({ message_id: 1 }),
    sendDocument: async (_chatId: string, path: string) => {
      sent.push({ kind: 'doc', path })
      return { message_id: 1 }
    },
    sendPhoto: async (_chatId: string, path: string) => {
      sent.push({ kind: 'photo', path })
      return { message_id: 1 }
    },
  } as unknown as MultichatTelegramApi
  router = new MultichatRouter({
    policy,
    pool: {} as unknown as TmuxSessionPool,
    stateDir: join(tmp, 'state'),
    workspaceDir: join(tmp, 'workspace'),
    telegramApi: api,
    logger: silentLogger(),
  })
})

afterEach(() => {
  rmSync(tmp, { recursive: true, force: true })
})

describe('sendOutboxFiles — attachment guard', () => {
  test('an ordinary file is sent', async () => {
    const report = join(tmp, 'report.pdf')
    writeFileSync(report, 'pdf')
    await sendFiles([report])
    expect(sent).toEqual([{ kind: 'doc', path: report }])
  })

  test('a symlink with an innocent name is refused, even to an innocent target', async () => {
    const target = join(tmp, 'notes.txt')
    writeFileSync(target, 'hi')
    const link = join(tmp, 'link.txt')
    symlinkSync(target, link)
    await sendFiles([link])
    expect(sent).toEqual([])
  })

  test('a path through a symlinked PARENT dir into a secret store is refused', async () => {
    // home/.ssh/config is a secret by its real path; the agent-visible path
    // `innocent/config` names nothing secret.
    const sshDir = join(tmp, 'home', '.ssh')
    mkdirSync(sshDir, { recursive: true })
    writeFileSync(join(sshDir, 'config'), 'Host *\n  IdentityFile ~/.ssh/id_ed25519\n')
    symlinkSync(sshDir, join(tmp, 'innocent'))
    await sendFiles([join(tmp, 'innocent', 'config')])
    expect(sent).toEqual([])
  })
})
