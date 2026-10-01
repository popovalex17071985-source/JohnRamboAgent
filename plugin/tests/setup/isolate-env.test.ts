import { describe, expect, test } from 'bun:test'

describe('test env isolation', () => {
  test('no live channel variables reach the suite', () => {
    const leaked = Object.keys(process.env).filter((k) =>
      /^(TELEGRAM_|MULTICHAT_|DASHI_|FALLBACK_REPLY_)/.test(k))
    expect(leaked).toEqual([])
  })
})
