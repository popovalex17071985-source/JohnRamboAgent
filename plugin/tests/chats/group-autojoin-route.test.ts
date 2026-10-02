// Группа на агенте из установщика (02.10.2026, живая установка Альберта):
// бота добавили в группу -- он молчал. Три дыры подряд: гейт отбрасывал
// незнакомую группу ДО роутера (автоподключение не срабатывало никогда), группа
// уходила в отдельную сессию без входа в Claude, и звать агента мог только
// владелец, а нужно -- все участники группы.
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  autojoinGroupChat,
  loadPolicy,
  mentionAllowlistFor,
  type MultichatPolicy,
} from '../../src/chats/policy-loader'
import { gateTelegramMessage } from '../../src/telegram/gate'
import type { AppConfig } from '../../src/config'

const OWNER = '8130002715'
const GROUP = '-1001234567890'
const STRANGER = '555000111'

function ownerYaml(extra: string): string {
  return `version: 1
allowlist:
  chats: ["${OWNER}"]
  users: ["${OWNER}"]
mention_allowlist: ["${OWNER}"]
chats:
  "${OWNER}":
    mode: private
    streaming: progress
    tmux_mirror: false
    edit_message_progress: true
    delivery: streamed
    persona_file: CLAUDE.md
    handoff_file: core/hot/handoff.md
    system_reminder: ""
${extra}`
}

function fixture(extra = ''): string {
  const dir = mkdtempSync(join(tmpdir(), 'group-route-'))
  writeFileSync(join(dir, 'policy.yaml'), ownerYaml(extra))
  return dir
}

const CONFIG = {} as AppConfig

function gate(policy: MultichatPolicy, senderId: string) {
  return gateTelegramMessage(
    { chatType: 'supergroup', chatId: GROUP, senderId } as Parameters<typeof gateTelegramMessage>[0],
    CONFIG,
    policy,
  )
}

describe('гейт: новая группа доходит до автоподключения', () => {
  test('незнакомая группа от владельца пропускается', () => {
    const policy = loadPolicy(fixture())
    expect(gate(policy, OWNER).kind).toBe('allow')
  })

  test('незнакомая группа от чужого -- отбой', () => {
    const policy = loadPolicy(fixture())
    expect(gate(policy, STRANGER)).toEqual({ kind: 'drop', reason: 'chat_not_allowed' })
  })
})

describe('группа наследует настройки лички владельца', () => {
  test('route: master и open_to_members переходят в новую группу', () => {
    const dir = fixture('    route: master\n    open_to_members: true\n')
    const joined = autojoinGroupChat(dir, GROUP, OWNER)
    expect(joined?.route).toBe('master')
    expect(joined?.open_to_members).toBe(true)
    const reloaded = loadPolicy(dir)
    expect(reloaded.chats[GROUP]?.route).toBe('master')
  })

  test('без настроек у владельца группа остаётся как раньше', () => {
    const joined = autojoinGroupChat(fixture(), GROUP, OWNER)
    expect(joined?.route).toBeUndefined()
    expect(joined?.open_to_members).toBeUndefined()
  })
})

describe('открытая группа: звать может любой участник', () => {
  test('в открытой группе чужой проходит гейт и фильтр упоминаний', () => {
    const dir = fixture('    route: master\n    open_to_members: true\n')
    autojoinGroupChat(dir, GROUP, OWNER)
    const policy = loadPolicy(dir)
    expect(gate(policy, STRANGER).kind).toBe('allow')
    expect(mentionAllowlistFor(policy, GROUP)).toBeUndefined()
  })

  test('в закрытой группе чужой отсекается, фильтр упоминаний на месте', () => {
    const dir = fixture()
    autojoinGroupChat(dir, GROUP, OWNER)
    const policy = loadPolicy(dir)
    expect(gate(policy, STRANGER)).toEqual({ kind: 'drop', reason: 'sender_not_allowed_in_group' })
    expect(mentionAllowlistFor(policy, GROUP)).toEqual([OWNER])
  })
})
