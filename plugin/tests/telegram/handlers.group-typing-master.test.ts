// Master-routed group shows the header `typing…` (03.10.2026).
//
// A group with `route: master` skips the router (so no M7 typing loop) and
// has `streaming: 'off'` (so no status bubble) — people in the group saw
// nothing until the answer landed. The handler must start the typing-only
// header via StatusManager, and must not do it for groups the router owns.

import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Context } from 'grammy'

import { handleInboundText } from '../../src/telegram/handlers.js'
import type { HandlerDeps } from '../../src/telegram/handlers.js'
import type {
  ChatPolicy,
  MultichatPolicy,
} from '../../src/chats/policy-loader.js'
import type { AppConfig, StatePaths } from '../../src/config.js'
import { createLogger } from '../../src/log.js'
import type { TelegramApi } from '../../src/channel/tools.js'
import type { BotIdentity } from '../../src/prompt/build.js'
import type { MultichatRouter } from '../../src/router/multichat-router.js'
import type { InboundMessage } from '../../src/router/inbox-bridge.js'
import type { StatusManager } from '../../src/status/status-manager.js'

const silentLog = createLogger('test', {
  stream: { write: () => true } as unknown as NodeJS.WritableStream,
})

const WARCHIEF_USER_ID = 164795011
const ALLOWED_GROUP_CHAT_ID = -1003784643974
const BOT_ID = 8507713167

function makeConfig(): AppConfig {
  return {
    bot_id: BOT_ID,
    dm_only: true,
    allowed_user_ids: [WARCHIEF_USER_ID],
    allowed_chat_ids: [WARCHIEF_USER_ID],
    status: {
      enabled: false,
      interval_ms: 700,
      ttl_ms: 300_000,
      delete_on_complete: true,
      suppress_typing_bubble: false,
    },
    album: { flush_ms: 2000 },
    voice: { provider: 'groq', language: 'ru', model: 'whisper-large-v3-turbo' },
    webhook: { enabled: false, host: '127.0.0.1', port: 0 },
    permission_relay: { enabled: false, allowed_user_ids: [], bash_only_proof: true },
    commands: { help: true, status: true, stop: true, reset: true, new: true },
    memory: {
      enabled: false,
      source_tag: 'tg',
      max_hot_bytes: 20480,
      trim_keep_lines: 600,
      buffer_ttl_ms: 5 * 60 * 1000,
      buffer_max_entries: 100,
    },
    progress: {
      enabled: true,
      edit_throttle_ms: 3000,
      recent_buffer: 10,
      session_ttl_ms: 600000,
    },
    task_mirror: {
      enabled: true,
      edit_throttle_ms: 3000,
      session_ttl_ms: 600000,
      collapse_completed_after: 5,
    },
    watcher: {
      enabled: true,
      debounce_ms: 10_000,
      busy_threshold_ms: 30_000,
    },
  } as unknown as AppConfig
}

function makeStatePaths(): StatePaths {
  const root = mkdtempSync(join(tmpdir(), 'dashi-voice-mc-test-'))
  return {
    root,
    env: join(root, '.env'),
    config: join(root, 'config.json'),
    allowlist: join(root, 'allowlist.json'),
    pid: join(root, 'bot.pid'),
    lock: join(root, 'bot.lock'),
    updateOffset: join(root, 'update-offset'),
    inbox: join(root, 'inbox'),
    sessionIds: join(root, 'session-ids'),
    deadLetterUpdates: join(root, 'dead-letter', 'updates'),
    deadLetterWebhook: join(root, 'dead-letter', 'webhook'),
    deadLetterOutbound: join(root, 'dead-letter', 'outbound'),
    logs: {
      server: join(root, 'logs', 'server.log'),
      telegram: join(root, 'logs', 'telegram.log'),
      permissions: join(root, 'logs', 'permissions.jsonl'),
      webhook: join(root, 'logs', 'webhook.log'),
      ask_user_question: join(root, 'logs', 'ask-user-question.jsonl'),
      permission_gate: join(root, 'logs', 'permission-gate.jsonl'),
      rejected_inbound: join(root, 'logs', 'rejected-inbound.jsonl'),
      accepted_inbound: join(root, 'logs', 'accepted-inbound.jsonl'),
      sent_outbound: join(root, 'logs', 'sent-outbound.jsonl'),
    },
  }
}

function makePolicy(route?: 'master'): MultichatPolicy {
  const groupChatPolicy: ChatPolicy = {
    mode: 'public',
    streaming: 'off',
    tmux_mirror: false,
    edit_message_progress: false,
    delivery: 'final_only',
    persona_file: 'thrall.md',
    handoff_file: 'handoff.md',
    system_reminder: '',
    idle_ttl_ms: 1_800_000,
    max_queue_depth: 1,
    ...(route ? { route } : {}),
  }
  const chats: Record<string, ChatPolicy> = {
    [String(ALLOWED_GROUP_CHAT_ID)]: groupChatPolicy,
  }
  return {
    version: 1,
    allowlist: {
      chats: Object.keys(chats),
      users: [String(WARCHIEF_USER_ID)],
    },
    mention_allowlist: [String(WARCHIEF_USER_ID)],
    chats,
  }
}

function makeTelegramApi(): TelegramApi {
  const noop = async (): Promise<never> => {
    throw new Error('unexpected api call in voice-multichat test')
  }
  return {
    sendMessage: (async () => ({ message_id: 1 })) as unknown as TelegramApi['sendMessage'],
    sendRichMessage: noop as unknown as TelegramApi['sendRichMessage'],
    editMessageText: noop as unknown as TelegramApi['editMessageText'],
    setMessageReaction: async () => undefined,
    sendChatAction: async () => undefined,
    sendDocument: noop as unknown as TelegramApi['sendDocument'],
    sendPhoto: noop as unknown as TelegramApi['sendPhoto'],
    downloadFile: noop as unknown as TelegramApi['downloadFile'],
    deleteMessage: noop as unknown as TelegramApi['deleteMessage'],
    answerGuestQuery: noop as unknown as TelegramApi['answerGuestQuery'],
  }
}

function makeRouterSpy(): { router: MultichatRouter; calls: InboundMessage[] } {
  const calls: InboundMessage[] = []
  const router = {
    dispatch: async (msg: InboundMessage) => {
      calls.push(msg)
    },
    ensureGroupJoined: () => null,
  } as unknown as MultichatRouter
  return { router, calls }
}

function makeDeps(
  router: MultichatRouter,
  policy: MultichatPolicy,
  statusManager: StatusManager,
): { deps: HandlerDeps; statePaths: StatePaths } {
  const statePaths = makeStatePaths()
  const bot: BotIdentity = { id: BOT_ID, username: 'canarybot' }
  const deps: HandlerDeps = {
    server: {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      notification: async () => undefined,
    } as any,
    config: makeConfig(),
    statePaths,
    telegramApi: makeTelegramApi(),
    log: silentLog,
    bot,
    botApi: { api: {} } as unknown as HandlerDeps['botApi'],
    botToken: 'fake-token',
    env: {}, // no GROQ_API_KEY → transcription_status="missing_key", no download
    policy,
    router,
    statusManager,
  }
  return { deps, statePaths }
}


function makeStatusSpy(): { sm: StatusManager; typingOnly: string[] } {
  const typingOnly: string[] = []
  const sm = {
    start: async (chatId: string) => ({ chatId, messageId: 0, startedAt: 0, generation: 0 }),
    startTypingOnly: (chatId: string) => {
      typingOnly.push(chatId)
    },
    isActive: () => false,
  } as unknown as StatusManager
  return { sm, typingOnly }
}

// Text in the group, replying to a bot message (addressing gate passes).
function makeGroupTextCtx(): Context {
  return {
    chat: { id: ALLOWED_GROUP_CHAT_ID, type: 'supergroup' as const },
    from: { id: WARCHIEF_USER_ID, is_bot: false, username: 'dashieshiev' },
    me: { id: BOT_ID, username: 'canarybot' },
    message: {
      message_id: 1801,
      date: 1700000000,
      text: 'ну чо ты?',
      chat: { id: ALLOWED_GROUP_CHAT_ID, type: 'supergroup' as const },
      from: { id: WARCHIEF_USER_ID, is_bot: false, username: 'dashieshiev' },
      reply_to_message: {
        message_id: 1800,
        date: 1700000000,
        text: 'bot speaking',
        from: { id: BOT_ID, is_bot: true, username: 'canarybot' },
      },
    },
  } as unknown as Context
}

describe('group typing header', () => {
  test('route: master group -> typing-only header, no router dispatch', async () => {
    const { router, calls } = makeRouterSpy()
    const { sm, typingOnly } = makeStatusSpy()
    const { deps, statePaths } = makeDeps(router, makePolicy('master'), sm)
    await handleInboundText(makeGroupTextCtx(), deps)
    expect(calls.length).toBe(0)
    expect(typingOnly).toEqual([String(ALLOWED_GROUP_CHAT_ID)])
    rmSync(statePaths.root, { recursive: true, force: true })
  })

  test('router-owned group -> router handles typing, no typing-only', async () => {
    const { router, calls } = makeRouterSpy()
    const { sm, typingOnly } = makeStatusSpy()
    const { deps, statePaths } = makeDeps(router, makePolicy(), sm)
    await handleInboundText(makeGroupTextCtx(), deps)
    expect(calls.length).toBe(1)
    expect(typingOnly).toEqual([])
    rmSync(statePaths.root, { recursive: true, force: true })
  })
})
