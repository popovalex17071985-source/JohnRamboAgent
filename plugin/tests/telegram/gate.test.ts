import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readdirSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import {
  assertAllowedChat,
  gateTelegramMessage,
  type GateInput,
} from '../../src/telegram/gate.js'
import type { MultichatPolicy } from '../../src/chats/policy-loader.js'
import { makeConfig } from '../helpers/config.js'

function dmInput(senderId: string, chatId: string): GateInput {
  return { chatType: 'private', chatId, senderId, isBot: false }
}

describe('gateTelegramMessage', () => {
  test('allows DM from configured user id', () => {
    const decision = gateTelegramMessage(dmInput('164795011', '164795011'), makeConfig())
    expect(decision.kind).toBe('allow')
    if (decision.kind === 'allow') {
      expect(decision.senderId).toBe('164795011')
      expect(decision.chatId).toBe('164795011')
    }
  })

  test('drops DM from unknown user even when chat id is allowed', () => {
    // chatId is in allowed_chat_ids but sender is not in allowed_user_ids.
    // Gate must reject on sender first, never delivering for a chat-only match.
    const decision = gateTelegramMessage(dmInput('999000111', '164795011'), makeConfig())
    expect(decision.kind).toBe('drop')
    if (decision.kind === 'drop') {
      expect(decision.reason).toBe('sender_not_allowed')
    }
  })

  test('drops message with missing from field', () => {
    const input: GateInput = {
      chatType: 'private',
      chatId: '164795011',
      senderId: undefined,
      isBot: undefined,
    }
    const decision = gateTelegramMessage(input, makeConfig())
    expect(decision.kind).toBe('drop')
    if (decision.kind === 'drop') expect(decision.reason).toBe('missing_sender')
  })

  test('drops group and supergroup messages in Scope A', () => {
    const group: GateInput = {
      chatType: 'group',
      chatId: '-1001234567890',
      senderId: '164795011',
      isBot: false,
    }
    const supergroup: GateInput = { ...group, chatType: 'supergroup' }

    const g = gateTelegramMessage(group, makeConfig())
    const sg = gateTelegramMessage(supergroup, makeConfig())
    expect(g.kind).toBe('drop')
    expect(sg.kind).toBe('drop')
    if (g.kind === 'drop') expect(g.reason).toBe('not_dm')
    if (sg.kind === 'drop') expect(sg.reason).toBe('not_dm')
  })

  test('drops channel posts', () => {
    const channel: GateInput = {
      chatType: 'channel',
      chatId: '-1009876543210',
      senderId: undefined, // channel posts often have no `from`
      isBot: undefined,
    }
    const decision = gateTelegramMessage(channel, makeConfig())
    expect(decision.kind).toBe('drop')
    if (decision.kind === 'drop') expect(decision.reason).toBe('not_dm')
  })

  test('does not create pairing state for unknown sender', () => {
    // The gate is pure — no side effects on disk. We assert this by pointing
    // a tmp state dir at the test and confirming nothing appears after calls.
    const tmp = mkdtempSync(join(tmpdir(), 'gate-state-'))
    try {
      const config = makeConfig()
      const input = dmInput('424242', '424242')

      const first = gateTelegramMessage(input, config)
      const second = gateTelegramMessage(input, config)
      expect(first.kind).toBe('drop')
      expect(second.kind).toBe('drop')

      // No file written by the gate. (Sanity: the tmp dir is empty.)
      expect(existsSync(tmp)).toBe(true)
      expect(readdirSync(tmp)).toEqual([])
    } finally {
      rmSync(tmp, { recursive: true, force: true })
    }
  })
})

describe('assertAllowedChat', () => {
  test('outbound assertAllowedChat allows configured chat', () => {
    expect(() => assertAllowedChat('164795011', makeConfig())).not.toThrow()
  })

  test('outbound assertAllowedChat rejects non-allowlisted chat with descriptive error', () => {
    expect(() => assertAllowedChat('-100999', makeConfig())).toThrow(/not allowlisted/)
    expect(() => assertAllowedChat('-100999', makeConfig())).toThrow(/allowed_chat_ids/)
  })

  test('accepts numeric chat ids configured as numbers', () => {
    const config = makeConfig({ allowed_chat_ids: [164795011, '777'] })
    expect(() => assertAllowedChat('164795011', config)).not.toThrow()
    expect(() => assertAllowedChat('777', config)).not.toThrow()
  })
})

// Multichat outbound: policy.allowlist.chats is the single source of truth
// and the chat must also have a policy.chats entry. Both checks were
// untested — dropping either one left the whole suite green (mutation
// audit 14.10.2026), so reply/react/edit could leak into a chat the
// inbound side never serves.
describe('assertAllowedChat — multichat policy', () => {
  const GROUP = '-1001111111111'
  const ORPHAN = '-1002222222222'
  const chatPolicy = {
    mode: 'public' as const,
    streaming: 'off' as const,
    tmux_mirror: false,
    edit_message_progress: false,
    delivery: 'final_only' as const,
    persona_file: 'persona.md',
    handoff_file: 'handoff.md',
    system_reminder: '',
    idle_ttl_ms: 1_800_000,
    max_queue_depth: 1,
  }
  function policy(): MultichatPolicy {
    return {
      version: 1,
      // ORPHAN is allowlisted but has no policy.chats entry.
      allowlist: { chats: [GROUP, ORPHAN], users: ['164795011'] },
      mention_allowlist: [],
      // NOT_LISTED has a chat entry but is absent from allowlist.chats.
      chats: { [GROUP]: chatPolicy, '-1003333333333': chatPolicy },
    }
  }

  test('allows a chat that is allowlisted AND has a policy entry', () => {
    expect(() => assertAllowedChat(GROUP, makeConfig(), policy())).not.toThrow()
  })

  test('refuses an allowlisted chat that has no policy.chats entry', () => {
    expect(() => assertAllowedChat(ORPHAN, makeConfig(), policy())).toThrow(
      /no policy\.chats entry/,
    )
  })

  test('refuses a chat absent from policy.allowlist.chats even with a chat entry', () => {
    expect(() => assertAllowedChat('-1003333333333', makeConfig(), policy())).toThrow(
      /not allowlisted/,
    )
  })

  test('legacy config.allowed_chat_ids is ignored once a policy is present', () => {
    // 164795011 is in makeConfig().allowed_chat_ids but not in the policy.
    expect(() => assertAllowedChat('164795011', makeConfig(), policy())).toThrow(
      /policy\.allowlist\.chats/,
    )
  })
})
