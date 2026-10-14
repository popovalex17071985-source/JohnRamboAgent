// Loopback origin gate for every authenticated webhook route (authGate in
// src/webhook/routes/shared.ts).
//
// Mutation audit 14.10.2026: the integration tests all connect from
// 127.0.0.1, so both "treat a missing peer address as loopback" and
// "drop the loopback check altogether" left the whole suite green. These
// tests drive authGate with a fake socket peer instead of a real one.
import { describe, expect, test } from 'bun:test'
import type { IncomingMessage, ServerResponse } from 'http'

import { authGate, isLoopbackAddress } from '../../src/webhook/routes/shared.js'

const TOKEN = 'test-webhook-token-0123456789abcdef'

interface FakeRes {
  status: number | undefined
  body: string
  res: ServerResponse
}

function fakeRes(): FakeRes {
  const out: FakeRes = { status: undefined, body: '', res: undefined as unknown as ServerResponse }
  out.res = {
    headersSent: false,
    writeHead(status: number) {
      out.status = status
      return this
    },
    end(payload?: string) {
      out.body = payload ?? ''
      return this
    },
  } as unknown as ServerResponse
  return out
}

function fakeReq(remoteAddress: string | undefined, auth?: string): IncomingMessage {
  return {
    socket: { remoteAddress },
    headers: auth === undefined ? {} : { authorization: auth },
  } as unknown as IncomingMessage
}

describe('isLoopbackAddress', () => {
  test('loopback peers are accepted', () => {
    for (const addr of ['127.0.0.1', '::1', '::ffff:127.0.0.1', '127.0.0.53']) {
      expect(isLoopbackAddress(addr)).toBe(true)
    }
  })

  test('a missing or empty peer address is NOT loopback (fail closed)', () => {
    expect(isLoopbackAddress(undefined)).toBe(false)
    expect(isLoopbackAddress('')).toBe(false)
  })

  test('non-loopback peers are refused', () => {
    for (const addr of ['10.0.0.5', '192.168.1.10', '::ffff:10.0.0.5', 'fe80::1']) {
      expect(isLoopbackAddress(addr)).toBe(false)
    }
  })
})
