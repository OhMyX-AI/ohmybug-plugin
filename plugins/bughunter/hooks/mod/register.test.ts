import { tagged } from './register'
import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

type Dollar = Parameters<TestBody>[0]
type On = Parameters<TestBody>[1]

const SUBMIT = 'mcp__plugin_bughunter_ohmybug__submit_review'
const GET = 'mcp__plugin_bughunter_ohmybug__get_findings'
const WAIT = 'mcp__plugin_bughunter_ohmybug__wait_review'
const VIEW = { scroll: { top: 0, bodyRows: 10 }, view: {} }

/** The texts a component draws, as the person would read them. */
async function drawn($: Dollar, component: string, props: Record<string, unknown>, requestId = 'x') {
  const ui = await $.ui.mount({ plugin: 'bughunter', surface: 'terminal', component, requestId, props } as never)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  await ui.unmount()
  return texts
}
const BAND = { plugin: 'bughunter', surface: 'terminal', component: 'AbovePrompt', requestId: 'x',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, ...VIEW } }
const band = ($: Dollar) => drawn($, 'AbovePrompt', BAND.props)
/** The keys of the Buttons the band draws. */
async function buttons($: Dollar) {
  const ui = await $.ui.mount(BAND as never)
  const keys = (await ui.findAll({ type: 'Button' })).map(b => String(b.key))
  await ui.unmount()
  return keys
}
async function press($: Dollar, key: string) {
  const ui = await $.ui.mount(BAND as never)
  await ui.press({ key })
  await ui.unmount()
}
const pane = ($: Dollar) => drawn($, 'Pane', { title: 'OhMyBug hunts', isFocused: false, bodyColumns: 60, placement: 'dock', ...VIEW }, 'bughunter-hunts')

const submitted = JSON.stringify({ review_id: 'rev_1', status: 'running', mode: 'fast',
  status_url: 'https://status.test/r/rev_1/status', recent_median_minutes: 38 })
const done = JSON.stringify({ review_id: 'rev_1', status: 'done', mode: 'fast', next_step: 'Verify each finding.',
  findings: [
    { finding_id: 'f_2', severity: 'low', file: 'a.ts', line: 3, title: 'Log line leaks the email domain' },
    { finding_id: 'f_1', severity: 'high', file: 'billing/refund.ts', line: 88, title: 'Refund retried twice on timeout' },
  ] })

/** The world beneath the plugin: a status URL, the toasts, the status line, the prompts it queues. */
/** What every test needs beneath the plugin: a session to start in, a command table, a drawing. */
let sessionNow = 's1'
function engine(on: On) {
  sessionNow = 's1'
  on('session.id', async () => ({ value: sessionNow }) as never)
  on('session.start', async ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', async () => ({ value: '/repo' }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('turn.complete', async ($, e) => ({ text: e.answer }))
  on('turn.start', async () => ({ turnId: 't1' }) as never)
  on('ui.render', async ($, e) => { const { Text } = $.ui.resolve(e); return Text({ children: 'engine drawing' } as never) })
}

/** What a POST answers in `world` (the deep offer's buttons): a status and a body, or null for no answer at all. */
let postReply: (url: string) => { status: number; text: string } | null | 'hang' = () => ({ status: 404, text: '{}' })
function world(on: On, status: string | null | string[] | (() => Promise<string>)) {
  postReply = () => ({ status: 404, text: '{}' })
  const replies = Array.isArray(status) ? [...status] : null
  const seen = { toasts: [] as string[], status: [] as (string | undefined)[], prompts: [] as string[], urls: [] as string[],
    posts: [] as { url: string; press?: string }[] }
  engine(on)
  const statusReply = async (url: string) => (seen.urls.push(url), status === null ? { deny: 'refused by policy' }
    : { value: { status: 200, ok: true, headers: {}, text: typeof status === 'function' ? await status()
      : replies ? (replies.length > 1 ? replies.shift()! : replies[0]!) : status } }) as never
  on('http.fetch', async ($, e) => {
    const { url, init } = e as { url?: unknown; init?: { method?: string; headers?: Record<string, string> } }
    if (init?.method !== 'POST') return statusReply(String(url))
    seen.posts.push({ url: String(url), press: init.headers?.['x-ohmybug-press'] })
    const r = postReply(String(url))
    if (r === 'hang') return new Promise(() => {}) as never
    if (r === null) return { deny: 'refused by policy' } as never
    return { value: { status: r.status, ok: r.status >= 200 && r.status < 300, headers: {}, text: r.text } } as never
  })
  on('ui.toast', async ($, e) => { seen.toasts.push(e.text); return { value: undefined } as never })
  on('ui.status', async ($, e) => { seen.status.push(e.text); return { value: undefined } as never })
  on('prompt.submit', async ($, e) => { seen.prompts.push(e.text); return { text: e.text } })
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: submitted }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: done }))
  return seen
}

test('a hunt that finishes raises a toast and a band, and starts no turn by itself', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2, next_poll_after_s: 60 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT, meta: { repo: 'o/r', ref: 'abc', base_branch: 'main' } } as never)
  expect(seen.status.at(-1)).toMatch(/bughunt fast 0\/~38 min/)

  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('rev_1 is done · 2 findings')
  expect(await band($)).toContain('Hunt rev_1 is done · 2 findings.')
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
  // Without OHMYBUG_AUTO_RESUME nothing is sent, not even when a turn ends idle.
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(seen.prompts).toHaveLength(0)
})

test('every status poll the mod makes names its waiter: w=mod, appended after any query the URL already has', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 0, next_poll_after_s: 60 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT, meta: { repo: 'o/r', ref: 'abc', base_branch: 'main' } } as never)
  await clock.advance(75_000)
  expect(seen.urls.length).toBeGreaterThan(0)
  for (const u of seen.urls) expect(u).toBe('https://status.test/r/rev_1/status?w=mod')
  expect(tagged('https://status.test/r/rev_1/status?t=1')).toBe('https://status.test/r/rev_1/status?t=1&w=mod')
})

test('a hunt another chat of the same repository started is not this chat\'s: no band, no toast, no status', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  // Positive control: the submitting chat is told.
  await clock.advance(75_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  // The same store and cwd, another chat.
  sessionNow = 's2'
  seen.toasts.length = 0
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await clock.advance(300_000)
  sessionNow = 's1'
  expect(await band($)).toBe('engine drawing')
  expect(seen.toasts).toEqual([])
  expect(seen.status.at(-1)).toBeUndefined()
})

test('a hunt that finishes mid-turn raises no band until the turn ends, and none if the agent read it meanwhile', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.turn.start({ prompt: 'x' } as never)
  await clock.advance(75_000)
  expect(await band($)).toBe('engine drawing')
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(await band($)).toContain('Hunt rev_1 is done')
  // Read by the agent in the next turn: the band is gone, nothing is re-raised.
  await $.turn.start({ prompt: 'y' } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't2', reason: 'end_turn' } as never)
  expect(await band($)).toBe('engine drawing')
})

test('another chat of the same repository neither polls nor raises a band for a hunt that is still running', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2, next_poll_after_s: 30 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  // The second chat starts while the first chat's hunt is still running.
  sessionNow = 's2'
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  seen.toasts.length = 0
  await clock.advance(300_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't9', reason: 'end_turn' } as never)
  expect(seen.toasts, 'chat s2 polled and announced s1\'s hunt').toEqual([])
  expect(await band($)).toBe('engine drawing')
})

test('a file request the agent read itself mid-turn raises no band at the turn end', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const files = JSON.stringify({ status: 'running', files_requested: true, next_poll_after_s: 30 })
  world(on, files)
  on('tool.call', { tool: WAIT }, async () => ({ result: { content: [] }, text: JSON.stringify({ review_id: 'rev_1', ...JSON.parse(files) }) }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.turn.start({ prompt: 'x' } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: WAIT, review_id: 'rev_1' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(await band($)).toBe('engine drawing')
})

// #2343: the agent's watch wakes it on done, failed and needs_files, so a hunt band offers no choice; only money asks.
for (const [state, says] of [['done', 'Hunt rev_1 is done'], ['failed', 'Hunt rev_1 failed'], ['needs_files', 'Reviewers of hunt rev_1 asked for files']] as const) {
  test(`a ${state} hunt band says so and offers no button`, async ($, on) => {
    const clock = mock.clock(on)
    mock.store(on)
    mock.env(on, {})
    const seen = world(on, JSON.stringify(state === 'needs_files' ? { status: 'running', awaiting_client_files: true } : { status: state, findings: 2 }))
    await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
    await $.tool.call({ tool: SUBMIT } as never)
    await clock.advance(75_000)
    expect(await band($)).toContain(says)
    expect(await buttons($)).toEqual([])
    expect(seen.prompts).toHaveLength(0)
  })
}

test('with OHMYBUG_AUTO_RESUME=1, a hunt parked behind a draft resumes when the person sends it: their turn does not take the band away', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: true, isWorking: false, hint: '' })
  await clock.advance(75_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(seen.prompts).toHaveLength(0)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: true, hint: '' })
  await $.turn.start({ prompt: 'the draft' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(seen.prompts).toEqual(['The OhMyBug hunt rev_1 is done. Read it with get_findings (review_id rev_1) and continue the bughunter flow.'])
})

test('a subagent\'s turn inside the main one leaves the hunt band; the person\'s next turn takes it', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.turn.start({ prompt: 'sub', agentId: 'a1' } as never)
  expect(await band($)).toContain('Hunt rev_1 is done')
  await $.turn.start({ prompt: 'next' } as never)
  expect(await band($)).toBe('engine drawing')
})

test('a merge refusal band goes when the next turn starts', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'running' }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: RUNNING }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
  expect(await band($)).toContain('Merge blocked')
  await $.turn.start({ prompt: 'next' } as never)
  expect(await band($)).toBe('engine drawing')
})

test('a hunt band nobody reads goes when the next turn starts', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  await $.turn.start({ prompt: 'something else' } as never)
  expect(await band($)).toBe('engine drawing')
})

test('a hunt the agent has read since loses its band', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toBe('engine drawing')
  expect(seen.prompts).toHaveLength(0)
})

test('with OHMYBUG_AUTO_RESUME=1, a finished hunt resumes an idle session with its id', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await clock.advance(75_000)
  expect(seen.prompts.join('\n')).toContain('get_findings (review_id rev_1)')
})

test('without OHMYBUG_AUTO_RESUME an idle session gets no prompt when a hunt finishes', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: false, hint: '' })
  await clock.advance(75_000)
  expect(seen.prompts).toHaveLength(0)
})

test('a submit answered already_running keeps the one record and its start time', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  engine(on)
  on('ui.status', async () => ({ value: undefined }) as never)
  on('http.fetch', async () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ status: 'running' }) } }) as never)
  const replies = [submitted, JSON.stringify({ ...JSON.parse(submitted), already_running: true })]
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: replies.shift()! }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(5 * 60_000)
  await $.tool.call({ tool: SUBMIT } as never)
  const list = await pane($)
  expect(list.match(/rev_1/g)).toHaveLength(1)
  expect(list).toContain('5 min ago')
})

test('a file request that arrives mid-turn gets its band when the turn ends', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'running', files_requested: true, next_poll_after_s: 30 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.turn.start({ prompt: 'x' } as never)
  await clock.advance(75_000)
  expect(await band($)).toBe('engine drawing')
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(await band($)).toContain('asked for files')
})

test('a submit answered already_running by another chat\'s hunt is adopted by the chat that asked', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  engine(on)
  on('ui.status', async () => ({ value: undefined }) as never)
  on('http.fetch', async () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ status: 'running' }) } }) as never)
  const replies = [submitted, JSON.stringify({ ...JSON.parse(submitted), already_running: true })]
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: replies.shift()! }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  sessionNow = 's2'
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  expect(await pane($)).not.toContain('rev_1')
  await clock.advance(1000)
  await $.tool.call({ tool: SUBMIT } as never)
  sessionNow = 's1'
  expect(await pane($)).toContain('rev_1')
})

test('files served and the hunt running again is not announced as done', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, [JSON.stringify({ status: 'running', files_requested: true, next_poll_after_s: 30 }),
    JSON.stringify({ status: 'running', files_requested: false, next_poll_after_s: 30 })])
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('asked for files')
  await clock.advance(45_000)
  expect(seen.toasts.join('\n')).not.toContain('is done')
})

test('a file request flagged only by awaiting_client_files is announced', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'running', awaiting_client_files: true }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).toContain('asked for files')
})

test('a hunt the agent read while the poll was in flight is not announced again', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, async () => {
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    return JSON.stringify({ status: 'done', findings: 2 })
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).not.toContain('is done')
  expect(await pane($)).not.toContain('not read yet')
})

test('a file request the agent read while the poll was in flight is not announced again', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const asked = JSON.stringify({ review_id: 'rev_1', status: 'running', files_requested: true })
  on('tool.call', { tool: WAIT }, async () => ({ result: { content: [] }, text: asked }))
  const seen = world(on, async () => {
    await $.tool.call({ tool: WAIT, review_id: 'rev_1' } as never)
    return asked
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.toasts.join('\n')).not.toContain('asked for files')
})

test('reading the result itself marks the hunt read', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  const list = await pane($)
  expect(list).toContain('2 found')
  expect(list).not.toContain('not read yet')
})

const RUNNING = 'OhMyBug: a hunt is RUNNING for this diff and has not returned yet. Poll get_findings until it says done, then merge.'
const UNHUNTED = 'OhMyBug: the current diff has not been hunted, or has CHANGED since the hunt (fixes count — re-hunt them).'

test('the gate\'s RUNNING refusal with a tracked open hunt says so and offers no button: the agent has the refusal (#2343)', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, JSON.stringify({ status: 'running' }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: RUNNING }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
  expect(await band($)).toContain('Merge blocked: a hunt is RUNNING for this diff')
  expect(await buttons($)).toEqual([])
  expect(seen.prompts).toHaveLength(0)
})

test('a hunt that finishes mid-turn replaces the merge refusal that was waiting for it, at the turn end', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2, next_poll_after_s: 30 }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: RUNNING }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.turn.start({ prompt: 'x' } as never)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
  await clock.advance(75_000)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
})

for (const [kind, reason] of [['RUNNING', RUNNING], ['unhunted', UNHUNTED]] as const) {
  test(`a ${kind} gate refusal without a tracked hunt shows its text and no button`, async ($, on) => {
    mock.clock(on)
    mock.store(on)
    mock.env(on, {})
    const seen = world(on, JSON.stringify({ status: 'running' }))
    on('tool.call', { tool: 'Bash' }, async () => ({ deny: reason }))
    await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
    await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12 --squash' } as never)
    expect(await band($)).toContain(`Merge blocked: ${reason.replace('OhMyBug: ', '')}`)
    expect(await buttons($)).toEqual([])
    expect(seen.prompts).toHaveLength(0)
  })
}

test('a gate refusal after the tracked hunt finished offers no button', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, JSON.stringify({ status: 'done', findings: 2 }))
  on('tool.call', { tool: 'Bash' }, async () => ({ deny: UNHUNTED }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: 'Bash', command: 'gh pr merge 12' } as never)
  expect(await buttons($)).toEqual([])
})

const findingsWith = (extra: Record<string, unknown>) => JSON.stringify({ ...JSON.parse(done), ...extra })

test('the deep hunt buttons come only with deep_offer, and Not now sends nothing', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const answers = [done, findingsWith({ deep_offer: { pitch: 'A deep hunt reads the whole repository.' } })]
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: answers.shift()! }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await buttons($)).not.toContain('deep-yes')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt offered for rev_1: A deep hunt reads the whole repository.')
  expect(await buttons($)).toEqual(['deep-yes', 'deep-no', 'deep-snooze'])
  // The offer waits for the person's answer: a new turn does not take it away (#2343).
  await $.turn.start({ prompt: 'x' } as never)
  expect(await buttons($)).toEqual(['deep-yes', 'deep-no', 'deep-snooze'])
  await press($, 'deep-no')
  expect(seen.prompts).toHaveLength(0)
  expect(await band($)).toBe('engine drawing')
})

test('a strong offer reads as a recommendation and names the quoted price; a regular one as before', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  // Strength and price are separate facts: each pair below differs in one of them.
  const answers = [findingsWith({ deep_offer: { pitch: 'Wide change.', strength: 'strong', price_usd: 12 } }), findingsWith({ deep_offer: { pitch: 'Go deep.', strength: 'regular' } }),
    findingsWith({ deep_offer: { pitch: 'Priced.', strength: 'regular', price_usd: 24 } }), findingsWith({ deep_offer: { pitch: 'Unpriced.', strength: 'strong' } })]
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: answers.shift()! }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt recommended for rev_1 (12 USD, only if a real bug is confirmed): Wide change.')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt offered for rev_1: Go deep.')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt offered for rev_1 (24 USD, only if a real bug is confirmed): Priced.')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await band($)).toContain('Deep hunt recommended for rev_1: Unpriced.')
})

test('Run deep hunt sends the consent for the offered id', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ deep_offer: { pitch: 'Go deep.' } }) }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  await press($, 'deep-yes')
  expect(seen.prompts).toEqual(['Yes, run the deep hunt for rev_1.'])
})

test('Not today asks the agent for a one-day pause of the deep offer and clears the band', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ deep_offer: { pitch: 'Go deep.' } }) }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  await press($, 'deep-snooze')
  expect(seen.prompts).toHaveLength(1)
  expect(seen.prompts[0]).toContain('set_policy')
  expect(seen.prompts[0]).toContain('{"deep": 24}')
  expect(seen.prompts[0], 'Not today must not read as consent to the deep hunt').not.toMatch(/run the deep hunt/i)
  expect(await band($)).toBe('engine drawing')
})

test('a deep_offer for a hunt the mod does not track draws no band', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ review_id: 'rev_x', deep_offer: { pitch: 'Go deep.' } }) }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_x' } as never)
  expect(await buttons($)).toEqual([])
})

// The deep offer's own buttons: one test per row of the press table (answer x the deep hunt's record x what is said).
const START = 'https://status.test/deep-offer/rev_1/' + 'a'.repeat(48) + '/start'
const SNOOZE = 'https://status.test/deep-offer/rev_1/' + 'a'.repeat(48) + '/snooze'
const withButtons = (extra: Record<string, unknown> = {}) => findingsWith({ deep_offer: { pitch: 'Go deep.', start_url: START, snooze_url: SNOOZE, ...extra } })
async function note($: Dollar) {
  const { sections } = await $.prompt.compose({ model: 'm', promptModel: 'm', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] })
  return sections.filter(x => x.id === 'bughunter:next-step').map(x => x.text).join('\n')
}
/** A store the test reads back: the mod's hunts list as it saved it. */
let stored: Record<string, unknown> = {}
function readableStore(on: On) {
  stored = {}
  on('store.get', async ($, e) => ({ value: stored[(e as { key: string }).key] }) as never)
  on('store.set', async ($, e) => { const { key, value } = e as { key: string; value: unknown }; stored[key] = value; return { value: undefined } as never })
}
/** What the stubbed tools answer next: switched by a test after it started (hooks are registered before). */
const answer = { get: '', submit: '', status: '' }
/** A session with the fast hunt rev_1 tracked and its offer, with buttons, on the band. */
async function offered($: Dollar, on: On, offer = withButtons()) {
  const clock = mock.clock(on)
  readableStore(on)
  mock.env(on, {})
  answer.get = offer; answer.submit = submitted
  on('prompt.compose', async () => ({ sections: [] }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: answer.get }))
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: answer.submit }))
  on('tool.call', { tool: CONFIRM }, async () => ({ result: { content: [] }, text: confirmed('rev_1') }))
  answer.status = JSON.stringify({ status: 'running' })
  const seen = world(on, async () => answer.status)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  return { seen, clock }
}
const started = (id: string, isNew = true) => ({ status: 200, text: JSON.stringify({ review_id: id, started: isNew, status_url: `https://status.test/r/${id}/status` }) })
const hunts = (_$?: Dollar) => (stored.hunts ?? []) as { id: string; mode: string; state: string; session?: string; cwd: string; pressed?: { parent: string }; startedAt: number }[]

test('Run deep hunt with a start URL posts it with the press header: no chat message, the band closes, the hunt is tracked and the agent told until it reads it', async ($, on) => {
  const { seen } = await offered($, on)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  expect(seen.posts).toEqual([{ url: START, press: '1' }])
  expect(seen.prompts).toEqual([])
  expect(await buttons($)).toEqual([])
  expect(seen.toasts.at(-1)).toBe('OhMyBug: deep hunt rev_deep1 started for rev_1.')
  const h = hunts($).find(x => x.id === 'rev_deep1')
  expect(h).toMatchObject({ mode: 'full', state: 'running', session: 's1', cwd: '/repo', pressed: { parent: 'rev_1' } })
  expect(await note($)).toContain('The person started OhMyBug deep hunt rev_deep1 from the offer button for rev_1')
  // Read to its end by the agent: the note goes.
  answer.get = JSON.stringify({ review_id: 'rev_deep1', status: 'done', mode: 'full', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_deep1' } as never)
  expect(await note($)).not.toContain('rev_deep1 from the offer button')
})

test('a pressed deep hunt is polled by the mod: nobody else watches it', async ($, on) => {
  const { seen, clock } = await offered($, on)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  seen.urls.length = 0
  await clock.advance(60_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't9', reason: 'end_turn' } as never)
  expect(seen.urls.some(u => u.startsWith('https://status.test/r/rev_deep1/status'))).toBe(true)
})

test('a stored record older than 6 hours does not count as tracked: the press tracks the hunt here', async ($, on) => {
  await offered($, on)
  const now = hunts($).find(x => x.id === 'rev_1')!.startedAt
  stored.hunts = [...hunts($), { id: 'rev_old', mode: 'fast', state: 'running', statusUrl: 'https://status.test/r/rev_old/status', cwd: '/repo',
    session: 's9', startedAt: now - 7 * 3600_000, seen: false, nextAt: now }]
  postReply = () => started('rev_old', false)
  await press($, 'deep-yes')
  // Older than the window: nobody tracks it any more, so this chat does, from the press.
  expect(hunts($).filter(h => h.id === 'rev_old')).toMatchObject([{ session: 's1', pressed: { parent: 'rev_1' }, startedAt: now }])
})

// Hunts shared between chats (one per-hunt write, and an owner change): one test per row of the table
// writer x who holds the record x what the other chat sees next.
const TURN = { answer: 'ok', durationMs: 1, isAborted: false, turnId: 't9', reason: 'end_turn' } as never
const theirs = (id: string, at: number, extra: Record<string, unknown> = {}) => ({ id, mode: 'fast', state: 'running',
  statusUrl: `https://status.test/r/${id}/status`, cwd: '/repo', session: 's9', startedAt: at, seen: false, nextAt: at, ...extra })
const t0 = () => hunts().find(x => x.id === 'rev_1')!.startedAt

test('a write here never undoes another chat\'s record written since: only the one hunt is written', async ($, on) => {
  await offered($, on)
  const other = theirs('rev_6', t0())
  stored.hunts = [...hunts(), other]
  answer.get = JSON.stringify({ review_id: 'rev_1', status: 'done', mode: 'fast', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(hunts().find(x => x.id === 'rev_6')).toEqual(other)
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ findings: 0, seen: true })
})

test('a hunt another chat adopted since is no longer polled or announced here', async ($, on) => {
  const { seen, clock } = await offered($, on)
  answer.submit = JSON.stringify({ review_id: 'rev_9', status: 'running', mode: 'fast', status_url: 'https://status.test/r/rev_9/status' })
  await $.tool.call({ tool: SUBMIT } as never)
  stored.hunts = hunts().map(h => h.id === 'rev_9' ? { ...h, session: 's9' } : h)
  seen.urls.length = 0
  await clock.advance(120_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete(TURN)
  expect(seen.urls.filter(u => u.includes('rev_9'))).toEqual([])
  expect(hunts().find(x => x.id === 'rev_9')).toMatchObject({ session: 's9' })
})

test('already_escalated for a deep hunt another chat read: it stays with the chat that owes its verdicts until this agent reads it', async ($, on) => {
  await offered($, on)
  const other = theirs('rev_8', t0(), { mode: 'full', state: 'done', seen: true, findings: 0 })
  stored.hunts = [...hunts(), other]
  answer.submit = JSON.stringify({ review_id: 'rev_8', mode: 'full', already_escalated: true, status_url: 'https://status.test/r/rev_8/status' })
  await $.tool.call({ tool: SUBMIT, deep: 'rev_1' } as never)
  expect(hunts().find(x => x.id === 'rev_8')).toEqual(other)
  expect(await note($)).not.toContain('rev_8')
  // Read to its end here: now this chat owes the verdicts.
  answer.get = JSON.stringify({ review_id: 'rev_8', status: 'done', mode: 'full', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_8' } as never)
  expect(hunts().find(x => x.id === 'rev_8')).toMatchObject({ session: 's1', seen: true })
  expect(await note($)).toContain('confirm_findings for rev_8')
})

test('already_escalated for an unread deep hunt another chat tracks: adopted here, and a verdict sent stays sent', async ($, on) => {
  await offered($, on)
  stored.hunts = [...hunts(), theirs('rev_7', t0(), { mode: 'full', state: 'running', judged: true })]
  answer.submit = JSON.stringify({ review_id: 'rev_7', mode: 'full', already_escalated: true, status_url: 'https://status.test/r/rev_7/status' })
  await $.tool.call({ tool: SUBMIT, deep: 'rev_1' } as never)
  expect(hunts().find(x => x.id === 'rev_7')).toMatchObject({ session: 's1', seen: false, judged: true })
  answer.get = JSON.stringify({ review_id: 'rev_7', status: 'done', mode: 'full', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_7' } as never)
  expect(await note($)).not.toContain('rev_7')
})

test('a read that is not the end moves nothing: an error with no state, or a running answer, leaves the hunt and its press note with the chat that owns it', async ($, on) => {
  await offered($, on)
  const other = theirs('rev_4', t0(), { mode: 'full', pressed: { parent: 'rev_7' } })
  stored.hunts = [...hunts(), other]
  answer.get = JSON.stringify({ error: 'payment_required', review_id: 'rev_4' })
  await $.tool.call({ tool: GET, review_id: 'rev_4' } as never)
  expect(hunts().find(x => x.id === 'rev_4')).toEqual(other)
  answer.get = JSON.stringify({ review_id: 'rev_4', status: 'running', mode: 'full' })
  await $.tool.call({ tool: GET, review_id: 'rev_4' } as never)
  expect(hunts().find(x => x.id === 'rev_4')).toEqual(other)
})

test('a running read of this chat\'s pressed hunt keeps its note, and the note says the hunt has not ended', async ($, on) => {
  await offered($, on)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  answer.get = JSON.stringify({ review_id: 'rev_deep1', status: 'running', mode: 'full' })
  await $.tool.call({ tool: GET, review_id: 'rev_deep1' } as never)
  expect(await note($)).toContain('Read it with get_findings (review_id rev_deep1) when it ends.')
})

test('a pressed hunt this chat read under the previous version (pressed and seen, not settled) is not told again', async ($, on) => {
  await offered($, on)
  stored.hunts = [...hunts(), { ...theirs('rev_deep0', t0(), { mode: 'full', state: 'done', seen: true, pressed: { parent: 'rev_1' } }), session: 's1' }]
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  const told = await note($)
  expect(told).not.toContain('rev_deep0 from the offer button')
  // Its verdicts are still owed here: that line stays.
  expect(told).toContain('rev_deep0 is done')
})

test('a poll answer for a hunt another chat adopted during the fetch writes nothing: the new owner keeps it', async ($, on) => {
  const clock = mock.clock(on)
  readableStore(on)
  mock.env(on, {})
  on('prompt.compose', async () => ({ sections: [] }))
  answer.submit = submitted
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: answer.submit }))
  // The status read lands after another chat took the hunt over.
  world(on, async () => { stored.hunts = hunts().map(h => ({ ...h, session: 's9' })); return JSON.stringify({ status: 'done', findings: 2 }) })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(120_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete(TURN)
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ session: 's9', state: 'running' })
})

test('two writes in one chat at once both land: one write at a time per session', async ($, on) => {
  await offered($, on)
  stored.hunts = hunts().map(h => h.id === 'rev_1' ? { ...h, seen: false, judged: undefined } : h)
  await Promise.all([$.tool.call({ tool: GET, review_id: 'rev_1' } as never), $.tool.call({ tool: CONFIRM, review_id: 'rev_1' } as never)])
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ seen: true, judged: true })
})

test('the slow re-read of a done hunt another chat adopted during the fetch leaves that chat\'s schedule alone', async ($, on) => {
  const clock = mock.clock(on)
  readableStore(on)
  mock.env(on, {})
  on('prompt.compose', async () => ({ sections: [] }))
  answer.submit = submitted
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: answer.submit }))
  let reads = 0
  world(on, async () => {
    // The first read finds it done (announced, unread here); the slow re-read lands after another chat took it over.
    if (++reads > 1) stored.hunts = hunts().map(h => ({ ...h, session: 's9', nextAt: 42 }))
    return JSON.stringify({ status: 'done', findings: 2 })
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(120_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete(TURN)
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ state: 'done', seen: false })
  await clock.advance(600_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete(TURN)
  expect(reads).toBeGreaterThan(1)
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ session: 's9', nextAt: 42 })
})

test('started:false for a deep hunt another chat tracks: adopted by this chat that pressed, unread here, and its agent told', async ($, on) => {
  const { seen } = await offered($, on)
  // Pressed in that chat from another offer: this press is the one this agent is told about.
  const other = theirs('rev_deep2', t0(), { mode: 'full', cwd: '/other', pressed: { parent: 'rev_7' } })
  stored.hunts = [...hunts(), other]
  postReply = () => started('rev_deep2', false)
  await press($, 'deep-yes')
  expect(hunts().find(x => x.id === 'rev_deep2')).toEqual({ ...other, session: 's1', cwd: '/repo', seen: false, pressed: { parent: 'rev_1' } })
  expect(seen.toasts.at(-1)).toBe('OhMyBug: deep hunt rev_deep2 already exists for rev_1.')
  expect(await note($)).toContain('rev_deep2 from the offer button')
})

test('a press for a deep hunt another chat already read: adopted unread, told to read it, and no verdicts owed yet', async ($, on) => {
  await offered($, on)
  stored.hunts = [...hunts(), theirs('rev_deep6', t0(), { mode: 'full', state: 'done', seen: true, findings: 0 })]
  postReply = () => started('rev_deep6', false)
  await press($, 'deep-yes')
  expect(hunts().find(x => x.id === 'rev_deep6')).toMatchObject({ session: 's1', seen: false, pressed: { parent: 'rev_1' } })
  const told = await note($)
  expect(told).toContain('rev_deep6 from the offer button')
  expect(told).not.toContain('confirm_findings for rev_deep6')
})

test('a press takeover of a hunt another chat read keeps its note through the server saying it was read, until this agent reads it', async ($, on) => {
  const { clock } = await offered($, on)
  stored.hunts = [...hunts(), theirs('rev_deep6', t0(), { mode: 'full', state: 'done', seen: true, findings: 0 })]
  postReply = () => started('rev_deep6', false)
  await press($, 'deep-yes')
  expect(await note($)).toContain('Read it with get_findings (review_id rev_deep6) now: it has ended.')
  // The slow re-read: the server says the result was read (by the other chat).
  answer.status = JSON.stringify({ status: 'done', findings: 0, read_after_done: true })
  await clock.advance(600_000)
  await $.turn.start({ prompt: 'x' } as never)
  await $.turn.complete(TURN)
  expect(hunts().find(x => x.id === 'rev_deep6')).toMatchObject({ settled: true })
  expect(await note($)).toContain('rev_deep6 from the offer button')
  answer.get = JSON.stringify({ review_id: 'rev_deep6', status: 'done', mode: 'full', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_deep6' } as never)
  expect(await note($)).not.toContain('rev_deep6 from the offer button')
})

test('reading another chat\'s hunt here makes it this chat\'s: the verdicts are owed here, not by the chat whose agent never read it', async ($, on) => {
  await offered($, on)
  stored.hunts = [...hunts(), theirs('rev_5', t0(), { state: 'done', seen: false, findings: 0 })]
  answer.get = JSON.stringify({ review_id: 'rev_5', status: 'done', mode: 'fast', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_5' } as never)
  expect(hunts().find(x => x.id === 'rev_5')).toMatchObject({ session: 's1', cwd: '/repo', seen: true })
  expect(await note($)).toContain('confirm_findings for rev_5')
})

test('already_running for this chat\'s own read hunt seen from another directory moves it here and keeps it read', async ($, on) => {
  await offered($, on)
  stored.hunts = hunts().map(h => h.id === 'rev_1' ? { ...h, cwd: '/elsewhere' } : h)
  answer.submit = JSON.stringify({ ...JSON.parse(submitted), already_running: true })
  await $.tool.call({ tool: SUBMIT } as never)
  expect(hunts().find(x => x.id === 'rev_1')).toMatchObject({ cwd: '/repo', seen: true })
})

test('the press note is told to the agent with the status line off too', async ($, on) => {
  mock.clock(on)
  readableStore(on)
  mock.env(on, { OHMYBUG_STATUS: '0' })
  on('prompt.compose', async () => ({ sections: [] }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: withButtons() }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  expect(await note($)).toContain('rev_deep1 from the offer button')
})

test('started:false for a deep hunt this session tracks keeps the record exactly as it was, read state and all', async ($, on) => {
  const { seen, clock } = await offered($, on)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  await clock.advance(60_000)
  answer.get = JSON.stringify({ review_id: 'rev_deep1', status: 'done', mode: 'full', findings: [] })
  await $.tool.call({ tool: GET, review_id: 'rev_deep1' } as never)
  const before = hunts($).find(x => x.id === 'rev_deep1')
  expect(before).toMatchObject({ state: 'done', seen: true })
  answer.get = withButtons()
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  postReply = () => started('rev_deep1', false)
  await press($, 'deep-yes')
  expect(hunts($).filter(x => x.id === 'rev_deep1')).toEqual([before])
  expect(seen.toasts.at(-1)).toBe('OhMyBug: deep hunt rev_deep1 already exists for rev_1.')
})

test('started:false for the deep hunt the agent itself started here keeps its record: not marked pressed, so the agent is not told it is someone else\'s', async ($, on) => {
  await offered($, on)
  answer.submit = JSON.stringify({ review_id: 'rev_deep5', status: 'running', mode: 'full', status_url: 'https://status.test/r/rev_deep5/status' })
  await $.tool.call({ tool: SUBMIT, deep: 'rev_1' } as never)
  const before = hunts($).find(x => x.id === 'rev_deep5')
  expect(before?.pressed).toBeUndefined()
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  postReply = () => started('rev_deep5', false)
  await press($, 'deep-yes')
  expect(hunts($).find(x => x.id === 'rev_deep5')).toEqual(before)
  expect(await note($)).not.toContain('rev_deep5')
})

test('a pressed deep hunt of another session or checkout is never told to this agent', async ($, on) => {
  await offered($, on)
  const base = { mode: 'full', state: 'running', statusUrl: 'https://status.test/r/x/status', startedAt: Date.now(), seen: false, nextAt: 1, pressed: { parent: 'rev_7' } }
  stored.hunts = [...hunts($), { ...base, id: 'rev_deep8', cwd: '/repo', session: 's9' }, { ...base, id: 'rev_deep9', cwd: '/other', session: 's1' }]
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  const told = await note($)
  expect(told).not.toContain('rev_deep8')
  expect(told).not.toContain('rev_deep9')
})

test('started:false for a deep hunt nobody here tracks is tracked as pressed, and the agent told', async ($, on) => {
  const { seen } = await offered($, on)
  postReply = () => started('rev_deep3', false)
  await press($, 'deep-yes')
  expect(hunts($).find(x => x.id === 'rev_deep3')).toMatchObject({ state: 'running', pressed: { parent: 'rev_1' } })
  expect(seen.toasts.at(-1)).toBe('OhMyBug: deep hunt rev_deep3 already exists for rev_1.')
  expect(await note($)).toContain('rev_deep3 from the offer button')
})

test('a 4xx is "not started" in the status\'s own words, and nothing is tracked or told', async ($, on) => {
  const { seen } = await offered($, on)
  const words: [number, string][] = [[400, 'the button is out of date, update the plugin'], [402, 'no credit for a deep hunt'],
    [403, 'the key that ran this review is revoked or expired'], [404, 'this offer is no longer valid'], [409, 'ask in the chat to see why'],
    [429, 'a limit is reached, try later']]
  for (const [status, said] of words) {
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    postReply = () => ({ status, text: '{"error":"x"}' })
    await press($, 'deep-yes')
    expect(seen.toasts.at(-1)).toBe(`OhMyBug: deep hunt not started: ${said}.`)
  }
  expect(hunts($).map(h => h.id)).toEqual(['rev_1'])
  expect(seen.prompts).toEqual([])
  expect(await note($)).not.toContain('offer button')
})

test('no answer, a timeout, a 5xx (503 included), another 4xx (408), an unreadable 2xx, or one without a review id or a status URL on the door\'s own server is unknown: never "not started", and the press falls back to the chat', async ($, on) => {
  const { seen, clock } = await offered($, on)
  const replies: (ReturnType<typeof postReply>)[] = [null, 'hang', { status: 500, text: '{}' }, { status: 503, text: '{}' }, { status: 408, text: '{}' },
    { status: 200, text: 'not json' }, { status: 200, text: '{"started":true}' }, { status: 200, text: '{"review_id":"rev_x","started":true}' },
    { status: 200, text: JSON.stringify({ review_id: 'rev_x', started: true, status_url: 'http://status.test/r/rev_x/status' }) },
    { status: 200, text: JSON.stringify({ review_id: 'rev_x', started: true, status_url: 'https://other.test/r/rev_x/status' }) }]
  for (const r of replies) {
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    postReply = () => r
    seen.prompts.length = 0
    const posted = seen.posts.length
    const pressed = press($, 'deep-yes')
    if (r === 'hang') {
      // The wait starts with the request: move the clock on once the POST is out.
      while (seen.posts.length === posted) await new Promise(res => setTimeout(res, 1))
      await new Promise(res => setTimeout(res, 1))
      await clock.advance(30_000)
    }
    await pressed
    expect(seen.toasts.at(-1), JSON.stringify(r)).toBe('OhMyBug: no answer from the server: asking in the chat instead.')
    expect(seen.prompts, JSON.stringify(r)).toEqual(['Yes, run the deep hunt for rev_1.'])
  }
  expect(hunts($).map(h => h.id)).toEqual(['rev_1'])
})

test('Not today with a snooze URL posts it: the pause said with its end, refusals and lost answers said apart, nothing stored', async ($, on) => {
  const { seen } = await offered($, on)
  const until = '2026-11-12T10:00:00.000Z'
  postReply = () => ({ status: 200, text: JSON.stringify({ snoozed_until: until }) })
  await press($, 'deep-snooze')
  expect(seen.posts).toEqual([{ url: SNOOZE, press: '1' }])
  expect(seen.prompts).toEqual([])
  expect(seen.toasts.at(-1)).toBe(`OhMyBug: deep offers paused until ${new Date(until).toLocaleString()}.`)
  expect(await buttons($)).toEqual([])
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  postReply = () => ({ status: 404, text: '{}' })
  await press($, 'deep-snooze')
  expect(seen.toasts.at(-1)).toBe('OhMyBug: deep offers not paused: this offer is no longer valid.')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  for (const r of [null, { status: 200, text: JSON.stringify({ snoozed_until: 'soon' }) }]) {
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    postReply = () => r
    seen.prompts.length = 0
    await press($, 'deep-snooze')
    expect(seen.toasts.at(-1)).toBe('OhMyBug: no answer from the server: asking in the chat instead.')
    expect(seen.prompts[0]).toContain('{"deep": 24}')
  }
  expect(await buttons($)).toEqual([])
  expect(hunts($).map(h => h.id)).toEqual(['rev_1'])
})

test('button URLs off the hunt\'s own server, not https, with a query or off the door\'s path keep the chat buttons: nothing is posted', async ($, on) => {
  const offers = [
    { start_url: 'https://evil.test/deep-offer/rev_1/x/start', snooze_url: 'https://evil.test/deep-offer/rev_1/x/snooze' },
    { start_url: 'http://status.test/deep-offer/rev_1/x/start', snooze_url: 'http://status.test/deep-offer/rev_1/x/snooze' },
    { start_url: `${START}?force=1`, snooze_url: `${SNOOZE}#x` },
    { start_url: 'https://status.test/live/x/start', snooze_url: 'https://status.test/live/x/snooze' },
    { start_url: 'https://u:p@status.test/deep-offer/rev_1/x/start', snooze_url: `${SNOOZE}?` },
  ]
  let offer = withButtons(offers[0])
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: offer }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  for (const o of offers) {
    offer = withButtons(o); seen.prompts.length = 0
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    await press($, 'deep-yes')
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    await press($, 'deep-snooze')
    expect(seen.posts).toEqual([])
    expect(seen.toasts.filter(t => t.includes('no answer')), 'the chat button itself, not a fallback').toEqual([])
    expect(seen.prompts[0]).toBe('Yes, run the deep hunt for rev_1.')
    expect(seen.prompts[1]).toContain('{"deep": 24}')
  }
})

test('the agent\'s own escalation answered already_escalated keeps the pressed record as it is', async ($, on) => {
  await offered($, on)
  postReply = () => started('rev_deep1')
  await press($, 'deep-yes')
  const before = hunts($).find(x => x.id === 'rev_deep1')
  answer.submit = JSON.stringify({ review_id: 'rev_deep1', already_escalated: true, mode: 'full', status_url: 'https://status.test/r/rev_deep1/status' })
  await $.tool.call({ tool: SUBMIT, deep: 'rev_1' } as never)
  expect(hunts($).find(x => x.id === 'rev_deep1')).toEqual(before)
})

test('a status URL the network refuses is said in the status line, not hidden', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, null)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(seen.status.at(-1)).toContain('status unreachable here')
})

const CONFIRM = 'mcp__plugin_bughunter_ohmybug__confirm_findings'
const confirmCard = async ($: Dollar, species: unknown[]) => drawn($, 'ToolResult', { tool_use_id: 'c1', tool: CONFIRM,
  output: JSON.stringify({ confirmed: 1, species }), isErrored: false }, 'c1')

test('the confirm card shows each species with its page and field notes', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice',
    url: 'https://bugs.test/retry-twice', lessons: ['Make the retry idempotent.', 'Key the write by request id.'] }])
  expect(texts).toContain('Retry twice')
  expect(texts, 'the page link is built from the slug, not drawn from the server').toContain('https://mcp.ohmybug.ai/bugs/retry-twice')
  expect(texts).not.toContain('bugs.test')
  expect(texts).toContain('+1 Retry twice')
  expect(texts).toContain('    · Make the retry idempotent.')
  expect(texts).toContain('2 field notes from other hunters are in the agent\'s context')
})

test('a medium-confidence species is drawn like any other, with no "likely" marker', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice', confidence: 'medium',
    url: 'https://bugs.test/retry-twice' }])
  expect(texts).toContain('Retry twice')
  expect(texts).not.toMatch(/likely|probably/i)
})

test('the catch counts each species once per finding, and a bad slug or name never reaches the card', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [
    { finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice' },
    { finding_id: 'f_2', slug: 'retry-twice', name: 'Retry twice' },
    { finding_id: 'f_3', slug: 'helpers-tested', name: 'Helpers Tested, Entry Point Untested' },
    { finding_id: 'f_4', slug: 'odd-name', name: 'Odd\u202Ename' },
    { finding_id: 'f_5', slug: 'Bad Slug', name: 'Bad slug' },
    { finding_id: 'f_6', slug: 'evil', name: 'https://evil.test' },
  ])
  expect(texts).toContain('+2 Retry twice')
  expect(texts, 'a catalogue name with a comma is drawn as is').toContain('+1 Helpers Tested, Entry Point Untested')
  expect(texts, 'a name outside the pattern falls back to the slug').toContain('+1 odd-name')
  expect(texts).not.toContain('\u202E')
  expect(texts, 'a slug outside the pattern is no species').not.toContain('Bad slug')
  expect(texts, 'a URL-shaped name is not drawn').not.toContain('evil.test')
  expect(texts).toContain('+1 evil')
})

test('the confirm card draws the server mascot above the catch, and none without the field', async ($, on) => {
  mock.store(on)
  engine(on)
  const mascot = { slug: 'retry-twice', name: 'Retry twice', new: true, caught: 1, total: 120, sprite: { color: '#22e36a', rows: ['.#', '#.'] } }
  const card = async (rid: string, extra: object) => drawn($, 'ToolResult', { tool_use_id: rid, tool: CONFIRM,
    output: JSON.stringify({ confirmed: 1, species: [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice' }], ...extra }), isErrored: false }, rid)
  const withIt = await card('c2', { mascot })
  expect(withIt).toContain('Retry twice — new!')
  expect(withIt.indexOf('Retry twice — new!')).toBeLessThan(withIt.indexOf('+1 Retry twice'))
  expect(await card('c3', {})).not.toContain('— new!')
})

test('a species without lessons draws no field-note lines', async ($, on) => {
  mock.store(on)
  engine(on)
  const texts = await confirmCard($, [{ finding_id: 'f_1', slug: 'retry-twice', name: 'Retry twice' }])
  expect(texts).toContain('Retry twice')
  expect(texts).not.toContain('field note')
  expect(texts).not.toContain('    · ')
})

/** The prompt text the mod adds, as the model would read it. */
async function nextStep($: Dollar) {
  const { sections } = await $.prompt.compose({ model: 'm', promptModel: 'm', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] })
  return sections.filter(x => x.id === 'bughunter:next-step').map(x => x.text).join('\n')
}
const composeBeneath = (on: On) =>
  on('prompt.compose', async () => ({ sections: [{ id: 'intro', text: 'engine', scope: 'shared' as const }] }))
const confirmed = (id: string) => JSON.stringify({ review_id: id, confirmed: 1 })

test('a read hunt without verdicts is named in the prompt and the status line until confirm', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  on('tool.call', { tool: CONFIRM }, async () => ({ result: { content: [] }, text: confirmed('rev_1') }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  expect(await nextStep($)).toBe('')
  await clock.advance(75_000)
  expect(await nextStep($)).toBe('')
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('OhMyBug hunt rev_1 is done and its verdicts are not sent. Next: verify each finding, then confirm_findings for rev_1.')
  expect(seen.status.at(-1)).toBe('bughunt rev_1 · verdicts not sent')
  await $.tool.call({ tool: CONFIRM, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('')
  expect(seen.status.at(-1)).toBeUndefined()
})

test('a read hunt with 0 findings is told to confirm with an empty verdict list', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: JSON.stringify({ review_id: 'rev_1', status: 'done', findings: [] }) }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('OhMyBug hunt rev_1 is done with 0 findings and is not confirmed yet. Next: confirm_findings for rev_1 with verdicts: [].')
})

test('a running hunt wins the status line over an earlier one without verdicts', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const ids = ['rev_a', 'rev_b']
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: JSON.stringify({ ...JSON.parse(submitted), review_id: ids.shift() }) }))
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: findingsWith({ review_id: 'rev_a' }) }))
  const seen = world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_a' } as never)
  expect(seen.status.at(-1)).toBe('bughunt rev_a · verdicts not sent')
  await $.tool.call({ tool: SUBMIT } as never)
  expect(seen.status.at(-1)).toMatch(/^bughunt fast 0/)
})

test('of two read hunts only the one without verdicts is named', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  engine(on)
  const answer = (id: string) => JSON.stringify({ review_id: id, status: 'done', mode: 'fast',
    status_url: `https://status.test/r/${id}/status` })
  const ids = ['rev_a', 'rev_b']
  on('tool.call', { tool: SUBMIT }, async () => ({ result: { content: [] }, text: answer(ids.shift()!) }))
  on('tool.call', { tool: CONFIRM }, async () => ({ result: { content: [] }, text: confirmed('rev_a') }))
  on('ui.status', async () => ({ value: undefined }) as never)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: CONFIRM, review_id: 'rev_a' } as never)
  const text = await nextStep($)
  expect(text).toContain('hunt rev_b is done')
  expect(text).not.toContain('rev_a')
})

test('OHMYBUG_STATUS=0 keeps the status line clear and the prompt line out', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_STATUS: '0' })
  composeBeneath(on)
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(seen.status).toHaveLength(0)
  expect(await nextStep($)).toBe('')
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the findings card lists findings by severity on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: 't1',
      props: { tool_use_id: 't1', tool: GET, output: done, isErrored: false } } as never)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    expect(texts).toContain('fast hunt rev_1 · done · 2 findings')
    expect(texts.indexOf('Refund retried twice')).toBeLessThan(texts.indexOf('Log line leaks'))
  })

  test(`a finding with a filed species shows its name and links to its page on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    const withSpecies = JSON.stringify({ ...JSON.parse(done), findings: [
      { finding_id: 'f_1', severity: 'high', file: 'billing/refund.ts', line: 88, title: 'Refund retried twice on timeout',
        species: { slug: 'lost-update', name: 'Lost update', url: 'https://mcp.ohmybug.ai/bugs/lost-update' } },
      { finding_id: 'f_2', severity: 'low', file: 'a.ts', line: 3, title: 'Log line leaks the email domain' },
      { finding_id: 'f_3', severity: 'low', file: 'b.ts', line: 4, title: 'A third',
        species: { slug: 'x', name: 'Not a web page', url: 'javascript:alert(1)' } },
    ] })
    const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: 't3',
      props: { tool_use_id: 't3', tool: GET, output: withSpecies, isErrored: false } } as never)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    expect(texts).toContain('Lost update')
    expect(texts, 'the species rides on the finding line').toMatch(/Refund retried twice on timeout\s+· /)
    const links = await ui.findAll({ type: 'Link' })
    expect(links.map(l => (l as unknown as { props?: { href?: string } }).props?.href),
      'links are built from the slug; the server URL is never drawn').toEqual(['https://mcp.ohmybug.ai/bugs/lost-update', 'https://mcp.ohmybug.ai/bugs/x'])
  })

  test(`the mascot is drawn only from the server's field, pixels on the terminal only, on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    // A hostile `url` rides along: the link must still be the one built from the slug.
    const mascot = { slug: 'silent-fallback', name: 'Silent Fallback', new: true, caught: 7, total: 120, url: 'javascript:alert(1)',
      sprite: { color: '#22e36a', rows: ['.##.', '#oo#', '#..#', '.##.'] } }
    const mount = async (rid: string, m: unknown) => {
      const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: rid,
        props: { tool_use_id: rid, tool: GET, output: JSON.stringify({ ...JSON.parse(done), ...(m === undefined ? {} : { mascot: m }) }), isErrored: false } } as never)
      const hrefs = (await ui.findAll({ type: 'Link' })).map(l => (l as unknown as { props?: { href?: string } }).props?.href)
      return Object.assign((await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n'), { hrefs })
    }
    const drawn = await mount('m1', mascot)
    expect(drawn.hrefs, 'the mascot link is built from the slug; the server url is never drawn').toEqual(['https://mcp.ohmybug.ai/bugs/silent-fallback'])
    expect(String(drawn)).not.toContain('javascript')
    expect(String(await mount('m0', { ...mascot, new: false }))).toContain('in your Bugarium · 7 of 120 caught')
    expect(String(drawn)).toContain('Silent Fallback — new!')
    expect(String(drawn)).toContain('new to your Bugarium · 7 of 120 caught')
    expect(String(drawn).includes('▀') || String(drawn).includes('▄'), 'pixels on the terminal, none elsewhere').toBe(surface === 'terminal')
    // No field, or any part that does not read, draws no mascot at all: the plugin never picks one itself.
    for (const [rid, m] of [['m2', undefined], ['m3', { ...mascot, caught: 121 }], ['m4', { ...mascot, new: 'yes' }],
      ['m5', { ...mascot, slug: 'Silent Fallback' }], ['m6', { ...mascot, sprite: { color: '#22e36a', rows: ['.##', '#o#', '#..'] } }],
      ['m7', { ...mascot, sprite: { color: 'red', rows: ['.##.', '#oo#'] } }], ['m8', { ...mascot, caught: 1.5 }],
      ['m9', { ...mascot, sprite: { color: '#22e36a', rows: ['.##.', '#o#'] } }], ['ma', { ...mascot, sprite: { color: '#22e36a', rows: ['.#x.', '#oo#'] } }],
      ['mb', { ...mascot, sprite: { color: '#22e36a', rows: ['#'.repeat(25), '#'.repeat(25)] } }],
      ['mc', { ...mascot, sprite: { color: '#22e36a', rows: Array(26).fill('##') } }]] as const) {
      const t = String(await mount(rid, m))
      expect(t, `${rid}: no mascot`).not.toContain('Silent Fallback')
      expect(t, `${rid}: the head line stays`).toContain('fast hunt rev_1 · done · 2 findings')
    }
  })

  test(`an answer the card cannot read is drawn by the engine on ${surface}`, async ($, on) => {
    mock.store(on)
    engine(on)
    const ui = await $.ui.mount({ plugin: 'bughunter', surface, component: 'ToolResult', requestId: 't2',
      props: { tool_use_id: 't2', tool: GET, output: 'not json', isErrored: false } } as never)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    expect(texts).not.toContain('hunt')
  })
}

const card = ($: Dollar, output: string) => drawn($, 'ToolResult', { tool_use_id: 'g1', tool: GET, output, isErrored: false }, 'g1')

test('the card points above the prompt only when the deep band is drawn for that hunt', async ($, on) => {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const offered = findingsWith({ deep_offer: { pitch: 'Go deep.' } })
  on('tool.call', { tool: GET }, async () => ({ result: { content: [] }, text: offered }))
  world(on, JSON.stringify({ status: 'running' }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  // Untracked: no band, so nothing to point at.
  expect(await card($, offered)).toContain('a deep hunt is on offer')
  expect(await card($, offered)).not.toContain('see above the prompt')
  await $.tool.call({ tool: SUBMIT } as never)
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await card($, offered)).toContain('a deep hunt is on offer (see above the prompt)')
})

test('with OHMYBUG_AUTO_RESUME=1, a hunt that finishes during a turn resumes when the turn ends', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: false, isWorking: true, hint: '' })
  await clock.advance(75_000)
  expect(seen.prompts).toHaveLength(0)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(seen.prompts).toEqual(['The OhMyBug hunt rev_1 is done. Read it with get_findings (review_id rev_1) and continue the bughunter flow.'])
  expect(await band($)).toBe('engine drawing')
})

test('with OHMYBUG_AUTO_RESUME=1, a draft in the prompt is never overrun', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  const seen = world(on, JSON.stringify({ status: 'done', findings: 2 }))
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await drawn($, 'PromptHint', { isDraft: true, isWorking: false, hint: '' })
  await clock.advance(75_000)
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)
  expect(seen.prompts).toHaveLength(0)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
})

// The server's read journal is the fact; this session's `seen` is a guess.
const readElsewhere = JSON.stringify({ status: 'done', findings: 2, read_after_done: true, judged: false })
const judgedOnly = JSON.stringify({ status: 'done', findings: 2, read_after_done: false, judged: true })
const unreadDone = JSON.stringify({ status: 'done', findings: 2, read_after_done: false, judged: false })
const idle = ($: Dollar, working = false) => drawn($, 'PromptHint', { isDraft: false, isWorking: working, hint: '' })
const endTurn = ($: Dollar) => $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', reason: 'end_turn' } as never)

test('a hunt the server says was already read raises nothing here and owes nothing here', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  composeBeneath(on)
  const seen = world(on, readElsewhere)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await idle($)
  await clock.advance(75_000)
  expect(seen.toasts).toEqual([])
  expect(seen.prompts).toEqual([])
  expect(await band($)).toBe('engine drawing')
  // Read, not judged, by someone else: this session is not told to verify findings it never read.
  expect(await nextStep($)).toBe('')
  expect(seen.status.at(-1)).toBeUndefined()
  // ...until it reads them itself: then the verdicts are its own to send.
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toContain('confirm_findings for rev_1')
})

test('a hunt judged elsewhere stays judged when this session reads it later', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  const seen = world(on, judgedOnly)
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(await buttons($)).toEqual([])
  await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
  expect(await nextStep($)).toBe('')
  expect(seen.prompts).toEqual([])
})

test('a done hunt read elsewhere after its band went up loses the band and its unread status on the next slow poll', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, [unreadDone, readElsewhere])
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
  expect(seen.status.at(-1)).toContain('rev_1 done')
  await clock.advance(240_000)
  expect(await buttons($)).toEqual([])
  expect(await band($)).toBe('engine drawing')
  expect(seen.status.at(-1)).toBeUndefined()
  expect(seen.prompts).toEqual([])
})

test('with OHMYBUG_AUTO_RESUME=1, a hunt read elsewhere before the turn ends is not resumed, and the turn end makes no network call', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, { OHMYBUG_AUTO_RESUME: '1' })
  let fetches = 0
  const seen = world(on, async () => { fetches++; return fetches === 1 ? unreadDone : readElsewhere })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await idle($, true)
  await clock.advance(75_000)
  await clock.advance(240_000)
  const before = fetches
  await endTurn($)
  expect(fetches).toBe(before)
  expect(seen.prompts).toEqual([])
})

test('without auto-resume, a hunt held through a turn and read elsewhere meanwhile gets no band at its end', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  world(on, [unreadDone, readElsewhere])
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await idle($, true)
  await clock.advance(75_000)
  await clock.advance(240_000)
  await endTurn($)
  expect(await band($)).toBe('engine drawing')
})

test('a status URL that fails on the slow poll leaves the nudge as it was', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  const seen = world(on, [unreadDone, 'not json'])
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await clock.advance(240_000)
  expect(await band($)).toContain('Hunt rev_1 is done')
  expect(await buttons($)).toEqual([])
  expect(seen.prompts).toHaveLength(0)
})

test('a read here while the slow poll is in flight wins over the server saying it was read', async ($, on) => {
  const clock = mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  composeBeneath(on)
  let fetches = 0
  world(on, async () => {
    fetches++
    if (fetches === 1) return unreadDone
    // This session's own read lands during the fetch; the server then counts it.
    await $.tool.call({ tool: GET, review_id: 'rev_1' } as never)
    return readElsewhere
  })
  await $.session.start({ cwd: '/repo', surface: 'terminal' } as never)
  await $.tool.call({ tool: SUBMIT } as never)
  await clock.advance(75_000)
  await clock.advance(240_000)
  expect(fetches).toBe(2)
  expect(await nextStep($)).toContain('confirm_findings for rev_1')
})
