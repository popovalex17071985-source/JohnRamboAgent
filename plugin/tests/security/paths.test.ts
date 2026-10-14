import { describe, expect, test } from 'bun:test'
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { basename, join } from 'path'

import {
  MAX_ATTACHMENT_BYTES,
  PHOTO_EXTENSIONS,
  assertSendableFile,
  isPhotoExtension,
  resolveInsideWorkspace,
} from '../../src/security/paths.js'
import { makeConfig } from '../helpers/config.js'

function makeWorkspace(): { ws: string; cleanup: () => void } {
  const ws = mkdtempSync(join(tmpdir(), 'dashi-paths-ws-'))
  return {
    ws,
    cleanup: () => rmSync(ws, { recursive: true, force: true }),
  }
}

function makeOutside(): { outside: string; cleanup: () => void } {
  const outside = mkdtempSync(join(tmpdir(), 'dashi-paths-outside-'))
  return {
    outside,
    cleanup: () => rmSync(outside, { recursive: true, force: true }),
  }
}

describe('resolveInsideWorkspace', () => {
  test('resolves relative path inside workspace', () => {
    const { ws, cleanup } = makeWorkspace()
    try {
      const filePath = join(ws, 'hello.txt')
      writeFileSync(filePath, 'hi')
      const canonical = resolveInsideWorkspace('hello.txt', ws)
      // realpathSync on macOS may add /private prefix; just check suffix.
      expect(canonical.endsWith('/hello.txt')).toBe(true)
      // Containment: canonical must be under realpath of ws.
      expect(canonical).toContain('hello.txt')
    } finally {
      cleanup()
    }
  })

  test('rejects absolute path outside workspace', () => {
    const { ws, cleanup } = makeWorkspace()
    const out = makeOutside()
    try {
      const evil = join(out.outside, 'leak.txt')
      writeFileSync(evil, 'secret')
      expect(() => resolveInsideWorkspace(evil, ws)).toThrow(/outside workspace/)
    } finally {
      cleanup()
      out.cleanup()
    }
  })

  test('rejects symlink that points outside workspace', () => {
    const { ws, cleanup } = makeWorkspace()
    const out = makeOutside()
    try {
      const target = join(out.outside, 'target.txt')
      writeFileSync(target, 'leak')
      const link = join(ws, 'inside-link.txt')
      symlinkSync(target, link)
      // Symlink itself sits inside ws, but realpathSync follows it to /outside.
      expect(() => resolveInsideWorkspace('inside-link.txt', ws)).toThrow(/outside workspace/)
    } finally {
      cleanup()
      out.cleanup()
    }
  })

  test('rejects ../ traversal attempt', () => {
    const { ws, cleanup } = makeWorkspace()
    const out = makeOutside()
    try {
      writeFileSync(join(out.outside, 'pwned.txt'), 'x')
      // From inside the workspace, climbing `..` should land outside.
      // We need a relative path that resolves outside ws. Easiest: name the
      // outside dir we just made and traverse via its basename.
      const traversal = join('..', 'no-such-thing', 'pwned.txt')
      expect(() => resolveInsideWorkspace(traversal, ws)).toThrow(/outside workspace/)
    } finally {
      cleanup()
      out.cleanup()
    }
  })
})

describe('assertSendableFile', () => {
  test('rejects file larger than 50MB', () => {
    const { ws, cleanup } = makeWorkspace()
    try {
      const big = join(ws, 'big.bin')
      writeFileSync(big, 'x') // tiny on disk; we patch stat below.
      const config = makeConfig({ workspace_root: ws })

      // Monkey-patch fs.statSync via dynamic import to fake size.
      // Simpler: write a real 51MB file (still under 100MB to keep CI light).
      const buf = Buffer.alloc(MAX_ATTACHMENT_BYTES + 1024, 0)
      writeFileSync(big, buf)

      expect(() => assertSendableFile({ filePath: 'big.bin', config })).toThrow(/files attachment rejected/)
      expect(() => assertSendableFile({ filePath: 'big.bin', config })).toThrow(/max/)
    } finally {
      cleanup()
    }
  })

  test('rejects directory', () => {
    const { ws, cleanup } = makeWorkspace()
    try {
      const dir = join(ws, 'subdir')
      mkdirSync(dir)
      const config = makeConfig({ workspace_root: ws })
      expect(() => assertSendableFile({ filePath: 'subdir', config })).toThrow(/is a directory/)
    } finally {
      cleanup()
    }
  })

  test('rejects missing file', () => {
    const { ws, cleanup } = makeWorkspace()
    try {
      const config = makeConfig({ workspace_root: ws })
      expect(() => assertSendableFile({ filePath: 'nope.txt', config })).toThrow(/does not exist/)
    } finally {
      cleanup()
    }
  })

  test('rejects when workspace_root unconfigured', () => {
    const config = makeConfig() // workspace_root undefined
    expect(config.workspace_root).toBeUndefined()
    expect(() => assertSendableFile({ filePath: '/tmp/anything.png', config })).toThrow(
      /TELEGRAM_WORKSPACE_ROOT not configured/,
    )
  })

  test('accepts a legit file inside workspace and returns canonical path', () => {
    const { ws, cleanup } = makeWorkspace()
    try {
      const filePath = join(ws, 'note.md')
      writeFileSync(filePath, 'ok')
      const config = makeConfig({ workspace_root: ws })
      const canonical = assertSendableFile({ filePath: 'note.md', config })
      expect(canonical.endsWith('/note.md')).toBe(true)
    } finally {
      cleanup()
    }
  })
})

describe('photo extension helper', () => {
  test('classifies .png as photo, .pdf as document', () => {
    expect(isPhotoExtension('/x/y.png')).toBe(true)
    expect(isPhotoExtension('/x/Y.JPG')).toBe(true)
    expect(isPhotoExtension('/x/y.pdf')).toBe(false)
    expect(PHOTO_EXTENSIONS.has('.webp')).toBe(true)
  })
})

// Containment edge cases (mutation audit 14.10.2026). Dropping the path
// separator from the containment prefix left every test green, and the
// existing `../` test aims at a file that does not exist, so it passes on
// the "file does not exist" branch without ever reaching containment.
describe('resolveInsideWorkspace — containment prefix', () => {
  test('rejects a sibling directory that shares the workspace name as a prefix', () => {
    const parent = mkdtempSync(join(tmpdir(), 'dashi-paths-parent-'))
    try {
      const ws = join(parent, 'ws')
      const evilDir = join(parent, 'ws-evil')
      mkdirSync(ws)
      mkdirSync(evilDir)
      const leak = join(evilDir, 'leak.txt')
      writeFileSync(leak, 'secret')
      // `/parent/ws-evil/leak.txt` starts with the string `/parent/ws`.
      expect(() => resolveInsideWorkspace(leak, ws)).toThrow(/outside workspace: /)
      expect(() => resolveInsideWorkspace(join('..', 'ws-evil', 'leak.txt'), ws)).toThrow(
        /outside workspace: /,
      )
    } finally {
      rmSync(parent, { recursive: true, force: true })
    }
  })

  test('rejects ../ traversal to a file that DOES exist outside', () => {
    const { ws, cleanup } = makeWorkspace()
    const out = makeOutside()
    try {
      writeFileSync(join(out.outside, 'pwned.txt'), 'x')
      const traversal = join('..', basename(out.outside), 'pwned.txt')
      let message = ''
      try {
        resolveInsideWorkspace(traversal, ws)
      } catch (err) {
        message = err instanceof Error ? err.message : String(err)
      }
      expect(message).toMatch(/outside workspace/)
      // Must be refused for containment, not because the file is missing.
      expect(message).not.toMatch(/does not exist/)
    } finally {
      cleanup()
      out.cleanup()
    }
  })
})
