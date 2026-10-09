// /update with a choice: what came out, in plain words, and what to install.
//
// The logic lives in scripts/update-plan.py and is run from FETCH_HEAD (the
// version that is about to be installed), so it evolves with the update itself
// and never needs a root-owned file to change. Here: parse what the owner typed,
// fetch, pipe the fresh script into python3, parse its JSON. When the fetch fails
// or the fresh version has no planner, the caller falls back to dashi-ctl.

import { spawn } from 'node:child_process'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export type UpdateRequest =
  | { kind: 'plan' }
  | { kind: 'apply'; mode: 'all' | 'keep' | 'items'; items: number[] }
  | { kind: 'skip'; items: number[] }
  | { kind: 'skipped' }
  | { kind: 'unskip' }
  | { kind: 'invalid' }

const ALL_WORDS = new Set(['всё', 'все', 'all', 'force'])
const KEEP_WORDS = new Set(['своё', 'свое', 'keep'])
const SKIP_WORDS = new Set(['пропусти', 'skip'])
const SKIPPED_WORDS = new Set(['пропущенные', 'skipped'])
const UNSKIP_WORDS = new Set(['верни', 'unskip'])
const UNSKIP_TAIL = new Set(['', 'всё', 'все', 'all'])
const MAX_ITEM_DIGITS = 3

function parseItemNumbers(words: readonly string[]): number[] | null {
  if (words.length === 0) return null
  const nums: number[] = []
  for (const w of words) {
    if (!new RegExp(`^\\d{1,${MAX_ITEM_DIGITS}}$`).test(w)) return null
    const n = Number(w)
    if (n < 1) return null
    if (!nums.includes(n)) nums.push(n)
  }
  return nums.sort((a, b) => a - b)
}

/** What the owner typed after /update. */
export function parseUpdateArgs(args: string): UpdateRequest {
  const words = args.toLowerCase().split(/[\s,;]+/).filter(Boolean)
  if (words.length === 0) return { kind: 'plan' }
  const [first = '', ...rest] = words
  if (words.length === 1 && ALL_WORDS.has(first)) return { kind: 'apply', mode: 'all', items: [] }
  if (words.length === 1 && KEEP_WORDS.has(first)) return { kind: 'apply', mode: 'keep', items: [] }
  if (words.length === 1 && SKIPPED_WORDS.has(first)) return { kind: 'skipped' }
  if (UNSKIP_WORDS.has(first) && rest.length <= 1 && UNSKIP_TAIL.has(rest[0] ?? '')) {
    return { kind: 'unskip' }
  }
  if (SKIP_WORDS.has(first)) {
    const items = parseItemNumbers(rest)
    return items ? { kind: 'skip', items } : { kind: 'invalid' }
  }
  const items = parseItemNumbers(words)
  return items ? { kind: 'apply', mode: 'items', items } : { kind: 'invalid' }
}

/** update-plan.py subcommand for a request (never called with `invalid`). */
export function plannerArgs(req: Exclude<UpdateRequest, { kind: 'invalid' }>): string[] {
  switch (req.kind) {
    case 'plan':
      return ['plan']
    case 'apply':
      return req.mode === 'items' ? ['apply', ...req.items.map(String)] : ['apply', req.mode]
    case 'skip':
      return ['skip', ...req.items.map(String)]
    case 'skipped':
      return ['skipped']
    case 'unskip':
      return ['unskip', 'all']
  }
}

export const UPDATE_USAGE =
  '<b>update</b> — не понял. Можно так:\n'
  + '<code>/update</code> — показать, что вышло\n'
  + '<code>/update всё</code> — поставить всё\n'
  + '<code>/update своё</code> — всё, кроме пунктов с вашими правками\n'
  + '<code>/update 1 3</code> — только пункты 1 и 3\n'
  + '<code>/update пропусти 2</code> — не ставить пункт 2 и больше не предлагать\n'
  + '<code>/update пропущенные</code> — что пропущено; <code>/update верни</code> — вернуть'

export interface PlannerResult {
  status: string
  text_html: string
  restart?: boolean
}

export type PlannerOutcome =
  | { kind: 'ok'; result: PlannerResult }
  | { kind: 'unavailable'; reason: string }
  // detail: short, owner-facing; stderr: the full (bounded) stderr for the log.
  | { kind: 'error'; detail: string; stderr?: string }

export type PlannerExec = (
  cmd: string,
  args: readonly string[],
  opts?: { input?: string; timeoutMs?: number },
) => Promise<{ code: number; stdout: string; stderr?: string }>

export interface PlannerOptions {
  repoDir: string
  claudeDir: string
  workspace: string
  agent: string
  chatId: string
  branch: string
  tz?: string
  exec?: PlannerExec
}

export const PLANNER_PATH = 'scripts/update-plan.py'
const FETCH_DEPTH = '50'
const FETCH_TIMEOUT_MS = 60_000
const SHOW_TIMEOUT_MS = 15_000
// apply runs bun install and install-kit: minutes, not seconds.
const PLANNER_TIMEOUT_MS = 600_000
const DETAIL_CHARS = 300
// A python traceback is a few KB at most; keep the tail if something floods.
const STDERR_KEEP_CHARS = 8000

export const defaultPlannerExec: PlannerExec = (cmd, args, opts) =>
  new Promise((resolveExec) => {
    let stdout = ''
    let stderr = ''
    let settled = false
    const done = (code: number): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolveExec({ code, stdout, stderr })
    }
    const child = spawn(cmd, args as string[], { stdio: ['pipe', 'pipe', 'pipe'] })
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      done(124)
    }, opts?.timeoutMs ?? FETCH_TIMEOUT_MS)
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => { stdout += chunk })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => {
      stderr = (stderr + chunk).slice(-STDERR_KEEP_CHARS)
    })
    child.on('error', () => done(127))
    child.on('close', (code) => done(code ?? 1))
    child.stdin.on('error', () => {})
    child.stdin.end(opts?.input ?? '')
  })

/** Runs FETCH_HEAD:scripts/update-plan.py with the given subcommand. */
export function makePlanner(o: PlannerOptions): (args: readonly string[]) => Promise<PlannerOutcome> {
  const exec = o.exec ?? defaultPlannerExec
  return async (args) => {
    const fetch = await exec(
      'git', ['-C', o.repoDir, 'fetch', '-q', '--depth', FETCH_DEPTH, 'origin', o.branch],
      { timeoutMs: FETCH_TIMEOUT_MS },
    )
    if (fetch.code !== 0) return { kind: 'unavailable', reason: `git fetch exit ${fetch.code}` }
    const show = await exec('git', ['-C', o.repoDir, 'show', `FETCH_HEAD:${PLANNER_PATH}`],
      { timeoutMs: SHOW_TIMEOUT_MS })
    if (show.code !== 0 || show.stdout.length === 0) {
      return { kind: 'unavailable', reason: 'no planner in FETCH_HEAD' }
    }
    const py = await exec('python3', [
      '-',
      '--repo', o.repoDir,
      '--claude-dir', o.claudeDir,
      '--workspace', o.workspace,
      '--agent', o.agent,
      '--chat-id', o.chatId,
      ...(o.tz ? ['--tz', o.tz] : []),
      ...args,
    ], { input: show.stdout, timeoutMs: PLANNER_TIMEOUT_MS })
    const last = py.stdout.trim().split('\n').pop() ?? ''
    try {
      const parsed = JSON.parse(last) as Partial<PlannerResult>
      if (typeof parsed.status === 'string' && typeof parsed.text_html === 'string') {
        return {
          kind: 'ok',
          result: {
            status: parsed.status,
            text_html: parsed.text_html,
            ...(parsed.restart === true ? { restart: true } : parsed.restart === false ? { restart: false } : {}),
          },
        }
      }
    } catch {
      // fall through to the error below
    }
    // The owner gets the tail (a traceback ends with the actual error line);
    // the whole stderr goes to the plugin log via the caller.
    const stderr = py.stderr ?? ''
    const tail = (stderr.trim() || py.stdout.trim()).slice(-DETAIL_CHARS) || 'пусто'
    return { kind: 'error', detail: `код ${py.code}: ${tail}`, ...(stderr ? { stderr } : {}) }
  }
}

/** The repo this plugin runs from: <repo>/plugin/src/commands/update-choice.ts. */
export function ownRepoDir(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
}
