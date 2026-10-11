// Launch-model detection — the ONLY place the `--model` flag of the hosting
// Claude Code process is read.
//
// Why this exists: the transcript's per-turn `model` is the id the API served,
// and for some 1M-window variants it comes back BARE — a session launched as
// `claude --model claude-opus-5[1m]` writes `"model":"claude-opus-5"` into the
// transcript. The family table then honestly resolves 200k and the pinned HUD
// under-reports a 1M window by 5x. The marker survives in exactly one place:
// the argv of the process that launched us. This module recovers it.
//
// The channel server runs as a child of that Claude Code process, so the parent
// chain is walked (a few hops, in case a shell/wrapper sits in between). Linux
// /proc only; every failure path returns undefined and the caller falls back to
// the model table, so a missing /proc never breaks the HUD.
//
// The same walk also recovers the `--effort` flag (readLaunchEffort): the HUD
// shows it beside the model when the transcript turn carries no effort of its own.

import { readFileSync } from 'node:fs'

import { parseLaunchModelFlag } from '../config.js'

// How many ancestors to inspect. The direct parent is normally the Claude Code
// process; the extra hops cover a wrapper/shell without walking to PID 1.
const MAX_ANCESTORS = 8

// Only a Claude Code process's `--model` counts. A wrapper further down the
// chain may carry a `--model` of its own (a launcher, a different CLI), and
// taking it would mask the real harness above it (codex MEDIUM, 2026-08-18).
// The walk therefore SKIPS non-Claude candidates and keeps climbing.
function isClaudeProcess(argv: readonly string[]): boolean {
  const exe = argv[0]
  if (exe === undefined) return false
  // Basename of argv[0]: `claude`, `/usr/local/bin/claude`, `node .../claude.js`.
  const base = exe.split('/').pop()?.toLowerCase() ?? ''
  if (base === 'claude' || base.startsWith('claude.')) return true
  // Runtime-launched forms: `node|bun <path>/claude(.js|.mjs)` AND the official
  // npm entrypoint `node <prefix>/@anthropic-ai/claude-code/cli.js`, where the
  // script basename is a generic `cli.js` and only the PATH identifies it
  // (codex MEDIUM, 2026-08-18). Matching a `claude*` path SEGMENT covers both
  // without loosening the filter to any `cli.js`.
  if (base === 'node' || base === 'bun') {
    const script = argv[1]?.toLowerCase()
    if (script === undefined || script.startsWith('-')) return false
    return script
      .split('/')
      .some((seg) => seg === 'claude' || seg.startsWith('claude.') || seg.startsWith('claude-'))
  }
  return false
}

function readCmdline(pid: number): readonly string[] | undefined {
  try {
    const raw = readFileSync(`/proc/${pid}/cmdline`, 'utf8')
    if (raw.length === 0) return undefined
    // /proc cmdline is NUL-separated with a trailing NUL.
    return raw.split('\0').filter((a) => a.length > 0)
  } catch {
    return undefined
  }
}

function readParentPid(pid: number): number | undefined {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
    // Fields: pid (comm) state ppid ... — comm is parenthesized and may itself
    // contain spaces/parens, so split AFTER the last ')'.
    const close = stat.lastIndexOf(')')
    if (close === -1) return undefined
    const rest = stat.slice(close + 1).trim().split(/\s+/)
    // rest[0] = state, rest[1] = ppid
    const ppid = Number(rest[1])
    return Number.isInteger(ppid) && ppid > 1 ? ppid : undefined
  } catch {
    return undefined
  }
}

export interface ReadLaunchModelOptions {
  // Where to start walking. Defaults to this process's parent.
  startPid?: number | undefined
  // Injectable readers — tests drive a fake process tree without /proc.
  readCmdlineFn?: (pid: number) => readonly string[] | undefined
  readParentPidFn?: (pid: number) => number | undefined
  maxAncestors?: number | undefined
}

// Walk the ancestor chain and return the first non-undefined `parse(argv)` of a
// Claude Code process. Never throws; every failure path yields undefined.
function findInClaudeAncestors(
  parse: (argv: readonly string[]) => string | undefined,
  opts?: ReadLaunchModelOptions,
): string | undefined {
  const readCmd = opts?.readCmdlineFn ?? readCmdline
  const readParent = opts?.readParentPidFn ?? readParentPid
  const limit = opts?.maxAncestors ?? MAX_ANCESTORS
  let pid = opts?.startPid ?? process.ppid
  const seen = new Set<number>()
  for (let hop = 0; hop < limit; hop += 1) {
    if (!Number.isInteger(pid) || pid <= 1 || seen.has(pid)) return undefined
    seen.add(pid)
    // The built-in readers already swallow their own errors; the try wraps the
    // INJECTED readers too, so the never-throws contract holds for every caller.
    let parent: number | undefined
    try {
      const argv = readCmd(pid)
      if (argv !== undefined && isClaudeProcess(argv)) {
        const value = parse(argv)
        if (value !== undefined) return value
      }
      parent = readParent(pid)
    } catch {
      return undefined
    }
    if (parent === undefined) return undefined
    pid = parent
  }
  return undefined
}

/**
 * The model id the hosting Claude Code process was launched with, or undefined
 * when no ancestor carries a `--model` flag (or /proc is unavailable).
 *
 * Never throws. Read ONCE at boot — the launch flag cannot change without a
 * restart, and a per-render /proc walk would be pointless work.
 */
export function readLaunchModelId(opts?: ReadLaunchModelOptions): string | undefined {
  return findInClaudeAncestors(parseLaunchModelFlag, opts)
}

/**
 * Parse the `--effort` value out of an argv: `--effort high` or `--effort=high`.
 * Same semantics as parseLaunchModelFlag — the last occurrence wins, a bare or
 * flag-followed `--effort` has no value, and `--` ends option parsing. Pure.
 */
export function parseLaunchEffortFlag(argv: readonly string[]): string | undefined {
  let found: string | undefined
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === undefined) continue
    if (arg === '--') break
    if (arg === '--effort') {
      found = undefined
      const next = argv[i + 1]
      if (next !== undefined && next.length > 0 && !next.startsWith('-')) found = next
      continue
    }
    if (arg.startsWith('--effort=')) {
      const value = arg.slice('--effort='.length)
      found = value.length > 0 ? value : undefined
    }
  }
  return found
}

/**
 * The reasoning effort the hosting Claude Code process was launched with
 * (`--effort`), or undefined when no Claude ancestor carries the flag. The HUD
 * uses it only as a fallback behind the transcript's per-turn effort. Never
 * throws; read ONCE at boot like readLaunchModelId.
 */
export function readLaunchEffort(opts?: ReadLaunchModelOptions): string | undefined {
  return findInClaudeAncestors(parseLaunchEffortFlag, opts)
}
