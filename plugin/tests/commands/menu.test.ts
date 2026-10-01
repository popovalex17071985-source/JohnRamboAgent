import { describe, expect, test } from 'bun:test'

import { BOT_COMMANDS, parseOobCommand, type OobCommandName } from '../../src/commands/oob.js'

// Technical commands stay typeable but are hidden from the Telegram menu
// (operator, 01.10.2026: the menu should hold only what the owner uses).
const HIDDEN: OobCommandName[] = ['mirror', 'keys', 'cc', 'lease']

describe('bot menu', () => {
  test('hides technical commands', () => {
    const shown = BOT_COMMANDS.map((c) => c.command)
    for (const name of HIDDEN) expect(shown).not.toContain(name)
    expect(shown).toEqual(['help', 'status', 'stop', 'compact', 'new', 'relogin', 'restart', 'update'])
  })

  test('hidden commands are still parsed when typed', () => {
    for (const name of HIDDEN) expect(parseOobCommand(`/${name}`)?.name).toBe(name)
  })
})
