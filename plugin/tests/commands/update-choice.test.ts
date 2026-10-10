import { describe, expect, test } from 'bun:test'

import {
  defaultPlannerExec,
  makePlanner,
  parseUpdateArgs,
  plannerArgs,
  type PlannerExec,
  type PlannerOutcome,
} from '../../src/commands/update-choice.js'
import { BOT_COMMANDS, handleOobCommand, parseOobCommand, type OobContext } from '../../src/commands/oob.js'
import type { TelegramApi } from '../../src/channel/tools.js'
import { makeConfig, makeLogger } from '../helpers/config.js'

const CTL = '/usr/local/bin/dashi-ctl-canary'

function makeCtx(restart: OobContext['restart']): OobContext {
  return {
    chatId: '164795011',
    senderId: '164795011',
    config: makeConfig(),
    telegramApi: {} as unknown as TelegramApi,
    log: makeLogger(),
    restart: { agentId: 'canary', fileExists: (p) => p === CTL, ...restart },
  }
}

describe('parseUpdateArgs', () => {
  test('bare /update shows the plan', () => {
    expect(parseUpdateArgs('')).toEqual({ kind: 'plan' })
  })
  test('everything: всё / все / all / force', () => {
    for (const a of ['всё', 'все', 'Всё', 'all', 'force', 'FORCE']) {
      expect(parseUpdateArgs(a)).toEqual({ kind: 'apply', mode: 'all', items: [] })
    }
  })
  test('everything except my own tweaks: своё / свое / keep', () => {
    for (const a of ['своё', 'свое', 'keep']) {
      expect(parseUpdateArgs(a)).toEqual({ kind: 'apply', mode: 'keep', items: [] })
    }
  })
  test('item numbers with spaces or commas', () => {
    for (const a of ['1 3', '1,3', '1, 3', ' 3 1 ']) {
      expect(parseUpdateArgs(a)).toEqual({ kind: 'apply', mode: 'items', items: [1, 3] })
    }
  })
  test('skip N', () => {
    expect(parseUpdateArgs('пропусти 2')).toEqual({ kind: 'skip', items: [2] })
    expect(parseUpdateArgs('skip 2,4')).toEqual({ kind: 'skip', items: [2, 4] })
    expect(parseUpdateArgs('пропусти').kind).toBe('invalid')
  })
  test('skipped list and unskip', () => {
    expect(parseUpdateArgs('пропущенные')).toEqual({ kind: 'skipped' })
    expect(parseUpdateArgs('skipped')).toEqual({ kind: 'skipped' })
    expect(parseUpdateArgs('верни')).toEqual({ kind: 'unskip' })
    expect(parseUpdateArgs('верни всё')).toEqual({ kind: 'unskip' })
    expect(parseUpdateArgs('unskip')).toEqual({ kind: 'unskip' })
  })
  test('anything else is invalid', () => {
    expect(parseUpdateArgs('давай').kind).toBe('invalid')
    expect(parseUpdateArgs('1 x').kind).toBe('invalid')
    expect(parseUpdateArgs('0').kind).toBe('invalid')
  })
})

describe('plannerArgs', () => {
  test('maps each request onto update-plan.py subcommands', () => {
    // bare /update: show the plan, or install it when repeated while fresh
    expect(plannerArgs({ kind: 'plan' })).toEqual(['auto'])
    expect(plannerArgs({ kind: 'apply', mode: 'all', items: [] })).toEqual(['apply', 'all'])
    expect(plannerArgs({ kind: 'apply', mode: 'keep', items: [] })).toEqual(['apply', 'keep'])
    expect(plannerArgs({ kind: 'apply', mode: 'items', items: [1, 3] })).toEqual(['apply', '1', '3'])
    expect(plannerArgs({ kind: 'skip', items: [2] })).toEqual(['skip', '2'])
    expect(plannerArgs({ kind: 'skipped' })).toEqual(['skipped'])
    expect(plannerArgs({ kind: 'unskip' })).toEqual(['unskip', 'all'])
  })
})

describe('makePlanner (FETCH_HEAD copy of scripts/update-plan.py)', () => {
  const opts = {
    repoDir: '/a/.claude/dashi-plugin-claude-code',
    claudeDir: '/a/.claude',
    workspace: '/a',
    agent: 'canary',
    chatId: '42',
    branch: 'main',
  }

  function fakeExec(answers: Record<string, { code: number; stdout: string; stderr?: string }>): {
    exec: PlannerExec
    calls: Array<{ cmd: string; args: readonly string[]; input?: string }>
  } {
    const calls: Array<{ cmd: string; args: readonly string[]; input?: string }> = []
    const exec: PlannerExec = async (cmd, args, o) => {
      calls.push({ cmd, args, ...(o?.input !== undefined ? { input: o.input } : {}) })
      const key = cmd === 'git' ? String(args[2]) : cmd
      return answers[key] ?? { code: 0, stdout: '' }
    }
    return { exec, calls }
  }

  test('fetches, runs the FETCH_HEAD script through python3 stdin, parses JSON', async () => {
    const { exec, calls } = fakeExec({
      show: { code: 0, stdout: 'print("script")\n' },
      python3: { code: 0, stdout: '{"status":"PLAN","text_html":"план"}\n' },
    })
    const out = await makePlanner({ ...opts, exec })(['auto'])
    expect(out).toEqual({ kind: 'ok', result: { status: 'PLAN', text_html: 'план' } })
    expect(calls[0]!.args).toEqual(['-C', opts.repoDir, 'fetch', '-q', '--depth', '50', 'origin', 'main'])
    expect(calls[1]!.args).toEqual(['-C', opts.repoDir, 'show', 'FETCH_HEAD:scripts/update-plan.py'])
    const py = calls[2]!
    expect(py.cmd).toBe('python3')
    expect(py.input).toBe('print("script")\n')
    expect(py.args).toEqual([
      '-', '--repo', opts.repoDir, '--claude-dir', opts.claudeDir, '--workspace', opts.workspace,
      '--agent', 'canary', '--chat-id', '42', '--branch', 'main', 'auto',
    ])
  })

  test('the fetched branch reaches the planner, not a FETCH_HEAD guess', async () => {
    const { exec, calls } = fakeExec({
      show: { code: 0, stdout: 'x' },
      python3: { code: 0, stdout: '{"status":"PLAN","text_html":"план"}\n' },
    })
    await makePlanner({ ...opts, branch: 'feature/canary', tz: 'Asia/Yekaterinburg', exec })(['plan'])
    expect(calls[0]!.args.at(-1)).toBe('feature/canary')
    const py = calls[2]!.args
    expect(py.slice(py.indexOf('--branch'), py.indexOf('--branch') + 2))
      .toEqual(['--branch', 'feature/canary'])
    expect(py.at(-1)).toBe('plan')
  })

  test('buttons and the plan version pass through; junk in them is dropped', async () => {
    const fh = 'a'.repeat(40)
    const { exec } = fakeExec({
      show: { code: 0, stdout: 'x' },
      python3: { code: 0, stdout: JSON.stringify({
        status: 'PLAN', text_html: 'план', fetch_head: fh,
        buttons: [['keep', 'Обновить, своё не трогать'], ['no', 'Не сейчас'], [1, 2], 'x'],
      }) + '\n' },
    })
    const out = await makePlanner({ ...opts, exec })(['auto'])
    expect(out).toEqual({ kind: 'ok', result: {
      status: 'PLAN', text_html: 'план', fetch_head: fh,
      buttons: [['keep', 'Обновить, своё не трогать'], ['no', 'Не сейчас']],
    } })
  })

  test('fetch failure → unavailable (old ctl flow takes over)', async () => {
    const { exec, calls } = fakeExec({ fetch: { code: 128, stdout: '' } })
    const out = await makePlanner({ ...opts, exec })(['plan'])
    expect(out.kind).toBe('unavailable')
    expect(calls).toHaveLength(1)
  })

  test('no script in FETCH_HEAD → unavailable', async () => {
    const { exec } = fakeExec({ show: { code: 128, stdout: '' } })
    expect((await makePlanner({ ...opts, exec })(['plan'])).kind).toBe('unavailable')
  })

  test('python traceback (stderr) reaches the error detail, last line first-class', async () => {
    const tb = 'Traceback (most recent call last):\n  File "<stdin>", line 9, in <module>\nValueError: boom\n'
    const { exec } = fakeExec({
      show: { code: 0, stdout: 'x' },
      python3: { code: 1, stdout: '', stderr: tb },
    })
    const out = await makePlanner({ ...opts, exec })(['plan'])
    expect(out.kind).toBe('error')
    if (out.kind !== 'error') return
    expect(out.detail).toContain('ValueError: boom')
    expect(out.detail).not.toContain('пусто')
    expect(out.stderr).toBe(tb)
  })

  test('default exec captures stdout, stderr and the exit code', async () => {
    const r = await defaultPlannerExec('sh', ['-c', 'cat; echo err >&2; exit 3'], { input: 'in\n' })
    expect(r).toEqual({ code: 3, stdout: 'in\n', stderr: 'err\n' })
  })

  test('script answered garbage → error, not a fallback', async () => {
    const { exec } = fakeExec({
      show: { code: 0, stdout: 'x' },
      python3: { code: 1, stdout: 'Traceback' },
    })
    expect((await makePlanner({ ...opts, exec })(['apply', 'all'])).kind).toBe('error')
  })
})

describe('/update through the planner', () => {
  function setup(outcome: PlannerOutcome) {
    const plannerCalls: string[][] = []
    const ctlCalls: string[][] = []
    const spawned: Array<readonly string[]> = []
    const ctx = makeCtx({
      runPlanner: async (args) => { plannerCalls.push([...args]); return outcome },
      runCtl: async (_c, args) => { ctlCalls.push([...args]); return { code: 0, out: 'UPTODATE' } },
      spawnDetached: (_cmd, args) => { spawned.push(args) },
    })
    return { ctx, plannerCalls, ctlCalls, spawned }
  }

  test('/update → plan text as the reply, nothing installed, no restart', async () => {
    const s = setup({ kind: 'ok', result: { status: 'PLAN', text_html: '<b>Вышло обновление</b>' } })
    const res = await handleOobCommand(parseOobCommand('/update')!, s.ctx)
    expect(res.replyToTelegram).toEqual({ text: '<b>Вышло обновление</b>', parseMode: 'HTML' })
    expect(s.plannerCalls).toEqual([['auto']])
    expect(s.ctlCalls).toHaveLength(0)
    expect(s.spawned).toHaveLength(0)
  })

  test('/update with the owner\'s own changes → plan with the buttons, nothing to the model', async () => {
    const fh = 'b'.repeat(40)
    const s = setup({ kind: 'ok', result: {
      status: 'PLAN', text_html: 'Вышло обновление. Оно заденет…', fetch_head: fh,
      buttons: [['keep', 'Обновить, своё не трогать'], ['all', 'Обновить всё, даже своё (копию сохраню)'], ['no', 'Не сейчас']],
    } })
    const res = await handleOobCommand(parseOobCommand('/update')!, s.ctx)
    expect(res.notifyChannel).toBeUndefined()
    expect(res.replyToTelegram!.inlineKeyboard!.inline_keyboard.map((r) => r[0]!.callback_data)).toEqual([
      `upd:keep:${fh.slice(0, 12)}`, `upd:all:${fh.slice(0, 12)}`, `upd:no:${fh.slice(0, 12)}`,
    ])
  })

  test('/update with nothing of the owner\'s → installed at once, no keyboard', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'Обновил. Что нового:', buttons: [] } })
    const res = await handleOobCommand(parseOobCommand('/update')!, s.ctx)
    expect(res.replyToTelegram!.inlineKeyboard).toBeUndefined()
    expect(s.spawned).toHaveLength(1)
  })

  test('/update 1,3 with restart=true → detached ctl restart', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'поставил' } })
    await handleOobCommand(parseOobCommand('/update 1,3')!, s.ctx)
    expect(s.plannerCalls).toEqual([['apply', '1', '3']])
    expect(s.spawned).toHaveLength(1)
    expect(s.spawned[0]![s.spawned[0]!.length - 1]).toBe(CTL)
  })

  test('/update своё with restart=false → no restart', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: false, text_html: 'поставил' } })
    await handleOobCommand(parseOobCommand('/update своё')!, s.ctx)
    expect(s.plannerCalls).toEqual([['apply', 'keep']])
    expect(s.spawned).toHaveLength(0)
  })

  test('/update пропусти 2, /update пропущенные, /update верни', async () => {
    const s = setup({ kind: 'ok', result: { status: 'SKIPPED', text_html: 'ok' } })
    await handleOobCommand(parseOobCommand('/update пропусти 2')!, s.ctx)
    await handleOobCommand(parseOobCommand('/update пропущенные')!, s.ctx)
    await handleOobCommand(parseOobCommand('/update верни')!, s.ctx)
    expect(s.plannerCalls).toEqual([['skip', '2'], ['skipped'], ['unskip', 'all']])
  })

  test('unknown words → short help, planner not run', async () => {
    const s = setup({ kind: 'ok', result: { status: 'PLAN', text_html: 'x' } })
    const res = await handleOobCommand(parseOobCommand('/update давай')!, s.ctx)
    expect(s.plannerCalls).toHaveLength(0)
    expect(res.replyToTelegram!.text).toContain('/update всё')
    expect(res.replyToTelegram!.text).not.toContain('своё')
  })

  test('repeated /update that installs → restart like any apply', async () => {
    const s = setup({ kind: 'ok', result: { status: 'UPDATED', restart: true, text_html: 'поставил' } })
    await handleOobCommand(parseOobCommand('/update')!, s.ctx)
    expect(s.plannerCalls).toEqual([['auto']])
    expect(s.spawned).toHaveLength(1)
  })

  test('planner error → the full stderr goes to the plugin log', async () => {
    const warned: Array<Record<string, unknown> | undefined> = []
    const ctx = makeCtx({
      runPlanner: async () => ({ kind: 'error', detail: 'код 1: ValueError: boom', stderr: 'Traceback\nValueError: boom' }),
    })
    ctx.log = { ...ctx.log, warn: (_m, c) => { warned.push(c) } }
    const res = await handleOobCommand(parseOobCommand('/update')!, ctx)
    expect(res.replyToTelegram!.text).toContain('ValueError: boom')
    expect(warned.some((c) => c?.stderr === 'Traceback\nValueError: boom')).toBe(true)
  })

  test('planner error → reported, no ctl fallback, no restart', async () => {
    const s = setup({ kind: 'error', detail: 'Traceback' })
    const res = await handleOobCommand(parseOobCommand('/update всё')!, s.ctx)
    expect(res.replyToTelegram!.text).toContain('Traceback')
    expect(s.ctlCalls).toHaveLength(0)
    expect(s.spawned).toHaveLength(0)
  })

  test('planner unavailable → old ctl flow: /update and /update всё = force', async () => {
    const s = setup({ kind: 'unavailable', reason: 'fetch failed' })
    await handleOobCommand(parseOobCommand('/update')!, s.ctx)
    await handleOobCommand(parseOobCommand('/update всё')!, s.ctx)
    expect(s.ctlCalls).toEqual([['update'], ['update', 'force']])
  })

  test('planner unavailable + item choice → explains, ctl not run', async () => {
    const s = setup({ kind: 'unavailable', reason: 'fetch failed' })
    const res = await handleOobCommand(parseOobCommand('/update 2')!, s.ctx)
    expect(s.ctlCalls).toHaveLength(0)
    expect(res.replyToTelegram!.text).toContain('/update всё')
  })

  test('/help explains /update plainly, typed power-user commands not advertised', async () => {
    const res = await handleOobCommand(parseOobCommand('/help')!, makeCtx({}))
    const text = res.replyToTelegram!.text
    expect(text).toContain('обновить агента; если где-то у вас своё, сначала объясню и спрошу')
    for (const raw of ['/update всё', '/update пропусти', '/update 1 3', '/update пропущенные']) {
      expect(text).not.toContain(raw)
    }
  })

  test('menu description is plain', () => {
    expect(BOT_COMMANDS.find((c) => c.command === 'update')!.description).toBe('обновить агента')
  })
})
