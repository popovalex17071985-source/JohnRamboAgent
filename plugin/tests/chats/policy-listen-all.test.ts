// listen_all (06.10.2026): per-group switch — the agent takes every message in
// that group, not only @-mentions. Requested by the client's owner for their
// group. Off by default; the policy file must accept the key (schema is strict).
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { listensToAll, loadPolicy } from '../../src/chats/policy-loader'

const OWNER = '8130002715'
const GROUP_A = '-1001234567890'
const GROUP_B = '-1009876543210'

function groupYaml(id: string, extra: string): string {
  return `  "${id}":
    mode: public
    streaming: "off"
    tmux_mirror: false
    edit_message_progress: false
    delivery: final_only
    persona_file: CLAUDE.md
    handoff_file: core/hot/handoff.md
    system_reminder: ""
${extra}`
}

function fixture(groupAExtra: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'listen-all-'))
  writeFileSync(
    join(dir, 'policy.yaml'),
    `version: 1
allowlist:
  chats: ["${GROUP_A}", "${GROUP_B}"]
  users: ["${OWNER}"]
mention_allowlist: ["${OWNER}"]
chats:
${groupYaml(GROUP_A, groupAExtra)}${groupYaml(GROUP_B, '')}`,
  )
  return dir
}

describe('listen_all в policy.yaml', () => {
  test('ключ принимается схемой и включает режим только своей группе', () => {
    const policy = loadPolicy(fixture('    listen_all: true\n'))
    expect(policy.chats[GROUP_A]?.listen_all).toBe(true)
    expect(listensToAll(policy, GROUP_A)).toBe(true)
    expect(listensToAll(policy, GROUP_B)).toBe(false)
  })

  test('без ключа режим выключен', () => {
    const policy = loadPolicy(fixture(''))
    expect(listensToAll(policy, GROUP_A)).toBe(false)
  })

  test('нет политики / нет чата -- выключен', () => {
    const policy = loadPolicy(fixture('    listen_all: true\n'))
    expect(listensToAll(undefined, GROUP_A)).toBe(false)
    expect(listensToAll(policy, undefined)).toBe(false)
    expect(listensToAll(policy, '-100000')).toBe(false)
  })
})
