// The bughunter mod: Claude Code's view of an OhMyBug hunt.
//
// It shows and offers; it never refuses. Every rule that blocks something (the
// merge gate) lives in the shell hooks, which Codex and older Claude Code run
// too — a rule only some clients enforce is a rule the others silently lack.
// If this module fails to load, the plugin behaves exactly as it did before it
// existed.
//
// Quiet: a status-line entry while a hunt runs, a toast and one band above the
// prompt when something happened; a button only where the person must decide (the
// deep offer, which spends money — #2343). No sound, no turn of its own unless
// the person sets OHMYBUG_AUTO_RESUME=1. What it adds to the system prompt: a
// read hunt whose verdicts are not sent, which the status line shows the person
// in the same words (unless a hunt that runs or waits to be read holds the
// status line; the line comes back when that one is read), and a deep hunt the
// person started from the band's button, which the agent did not submit.
//
// The rule every action obeys: a button or an auto-resume acts only on a hunt
// this mod tracks by review_id, in a state it saw that hunt move into itself.
// Nothing is derived from a refusal's wording: a gate refusal is shown as it
// reads, with no button. A text does not say which hunt or which refusal it is about, and
// a "Hunt now" offered on the RUNNING refusal once started a second paid hunt.

import type { EngineInterface as Engine, Register, RenderChildren } from 'claude-code'

import { bodyOf, catchOf, findingsOf, gateReason, halfBlocks, huntLabel, mascotOf, minutes, num, ROUTE_OVER, routeRead, speciesOf, statusState, str, toolKind } from './parse'

/** The status door journals which waiter polled (`w`): the skill's watch loop sends `loop`, the mod `mod`. */
export const tagged = (url: string): string => {
  try { const u = new URL(url); u.searchParams.append('w', 'mod'); return u.toString() } catch { return url }
}

/** One hunt the bughunter mod watches: what submit_review answered, then what the status URL says. */
type BughunterHunt = {
  id: string
  mode: string
  state: 'running' | 'needs_files' | 'done' | 'failed'
  statusUrl?: string
  cwd: string
  startedAt: number
  median?: number
  findings?: number
  /** Nothing left to tell this session: its agent read the terminal result
   *  (get_findings or wait_review), or the server said someone did (`settled`).
   *  Reset when another chat takes the hunt over (adopt). */
  seen: boolean
  /** confirm_findings for this hunt's id answered with the verdicts recorded. */
  judged?: boolean
  /** The server said someone already read or judged the result, and this session
   *  did not see it happen (another session, a result the mod could not parse):
   *  nothing is owed from here, so no nudge, no next-step line. */
  settled?: boolean
  nextAt: number
  /** The chat that owns it now (submitted it, or took it over: adopt): the store is shared by every session of this
   *  machine, and only the owner polls it, announces it and tells its agent about it. */
  session?: string
  /** Started (or found) by the person's Run deep hunt press on the offer for `parent`, not by the agent: the agent is
   *  told about it in the prompt until this chat's agent reads the result (not `seen`: the server saying another chat
   *  read it must not end the note). */
  pressed?: { parent: string }
  /** The service route: the highest rank any answer about this id named (routeRead). Undefined for an ordinary hunt
   *  and for a followed child. Never goes down; while it is below ROUTE_OVER the row is watched whatever its state. */
  route?: number
}

/** The one band above the prompt. `id` is always a tracked hunt; `state` is the
 *  state the mod saw it move into, re-checked before any action. */
type BughunterBand =
  | { kind: 'hunt'; id: string; state: BughunterHunt['state']; text: string }
  | { kind: 'deep'; id: string; text: string; strong?: boolean; price?: number; start?: string; snooze?: string }
  | { kind: 'gate'; id?: string; text: string }
  | null

// The drawing reads these and every write asks for a redraw. Module variables,
// not $.state: a state contract has to be named in plugin.json, and older
// Claude Code refuses a manifest key it does not know. The hunts outlive the
// session through $.store.
let huntList: BughunterHunt[] = []
let bandNow: BughunterBand = null
// This session's id. The saved hunts are shared by every session on the machine,
// and a band for a hunt another chat started told this chat's agent to read a
// review it never submitted (owner report, 2026-10-23). A saved hunt with no
// session (written by an older mod) is nobody's: it expires on its own.
let sessionId = ''
// The hunt whose move the poll saw mid-turn and held back (announce): the turn's
// end raises its band, and only its. Not "any unread hunt": the agent may have
// read a file request itself, and `seen` does not record that for needs_files.
let heldId: string | undefined
const ours = (h: BughunterHunt, cwd: string) => h.cwd === cwd && !!sessionId && h.session === sessionId
const rawOpen = new Set<string>()

function setHunts($: Engine, list: BughunterHunt[]) { huntList = list; $.ui.invalidate('ui.render') }
function setBand($: Engine, b: BughunterBand) { bandNow = b; $.ui.invalidate('ui.render') }
function toggleRaw($: Engine, id: string) { if (!rawOpen.delete(id)) rawOpen.add(id); $.ui.invalidate('ui.render') }

const PANE = 'bughunter-hunts'
const STALE_MS = 6 * 3600_000
const SEVERITY = ['critical', 'high', 'medium', 'low']
const COLOR: Record<string, string> = { critical: 'red', high: 'red', medium: 'yellow' }

const isOpen = (h: BughunterHunt) => h.state === 'running' || h.state === 'needs_files'
const routeOpen = (h: BughunterHunt) => h.route !== undefined && h.route < ROUTE_OVER
/** Polled at the server's cadence: an open hunt, or a step 1 whose route is not over (its done is not the end). */
const watched = (h: BughunterHunt) => isOpen(h) || routeOpen(h)
/** Done, read by the agent, and no verdicts seen for it: the one next step left. */
const awaitsVerdicts = (h: BughunterHunt, cwd: string, now: number) =>
  ours(h, cwd) && h.state === 'done' && h.seen && !h.judged && !h.settled && now - h.startedAt < STALE_MS

/** The status URL's word that the result was already dealt with: a findings door
 *  read it told done, or a finding has a verdict. Absent on an older server, and
 *  never true of a failed hunt (the server counts only reads told done), so
 *  those keep the nudge they always had. */
const dealtWith = (body: unknown) => {
  const b = body as Record<string, unknown> | undefined
  return b?.read_after_done === true || b?.judged === true
}
/** What a hunt becomes when the server says it was dealt with. Judged is kept
 *  as judged, so a later read here does not ask for verdicts already sent. */
const settledBy = (body: unknown): Partial<BughunterHunt> =>
  ({ seen: true, settled: true, ...((body as Record<string, unknown>).judged === true ? { judged: true } : {}) })

function news(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of hunt ${h.id} asked for files.`
  if (h.state === 'failed') return `Hunt ${h.id} failed.`
  const n = h.findings
  const count = n === undefined ? '' : ` · ${n} finding${n === 1 ? '' : 's'}`
  // A routed step 1 done is not the hunt's end: a fast hunt may follow once its findings are judged.
  return routeOpen(h) ? `Hunt ${h.id} waits for your verdicts${count}.` : `Hunt ${h.id} is done${count}.`
}

/** What auto-resume sends (OHMYBUG_AUTO_RESUME=1): the hunt's id, and the step its seen state calls for. */
function resumeText(h: BughunterHunt): string {
  if (h.state === 'needs_files') return `Reviewers of the OhMyBug hunt ${h.id} asked for files. Call get_findings with review_id ${h.id} and serve them.`
  if (h.state === 'failed') return `The OhMyBug hunt ${h.id} failed. Call get_findings with review_id ${h.id} to see why.`
  if (routeOpen(h)) return `The OhMyBug hunt ${h.id} waits for your verdicts. Read it with get_findings (review_id ${h.id}), judge its findings with confirm_findings and continue the bughunter flow.`
  return `The OhMyBug hunt ${h.id} is done. Read it with get_findings (review_id ${h.id}) and continue the bughunter flow.`
}

/** The tracked hunt a 'hunt' band may still act on: same id, same state the mod
 *  saw it move into, not read by the agent since. Anything else acts on nothing. */
function actionable(b: BughunterBand): BughunterHunt | undefined {
  if (b?.kind !== 'hunt') return undefined
  const h = huntList.find(x => x.id === b.id)
  return h && h.session === sessionId && h.state === b.state && !h.seen ? h : undefined
}

/** The open tracked hunt of this repository a gate refusal is about: the band keeps its id, and the turn end
 *  replaces the refusal with that hunt's news once it finished. */
const openHunt = (cwd: string) => huntList.find(h => ours(h, cwd) && isOpen(h))

// What the person chose (environment), what the last drawing said about the
// session and what the network allowed. Module state on purpose: a reload
// starts it over, and nothing in it outlives the session. `ticking` keeps a
// slow poll from overlapping the next.
const ctx = { autoResume: false, showStatus: true, working: true, draft: false, blocked: false, ticking: false }

const MERGE = /\b(gh\s+pr\s+merge|glab\s+mr\s+merge)\b/

/** A merge the gate refused: its own words, and the id of an open tracked hunt
 *  here. Which hunt comes from the mod's list, never from the refusal's text. */
async function observeGate($: Engine, command: string, text: string | undefined, failed: boolean) {
  if (!MERGE.test(command)) return
  const reason = failed ? gateReason(text) : undefined
  if (!reason) { if (bandNow?.kind === 'gate') setBand($, null); return }
  setBand($, { kind: 'gate', id: openHunt(await $.session.cwd())?.id, text: reason })
}

/** The service route: step 1 went on as `next`, the answer from now on. The row follows it, one hunt to the person:
 *  the child's own status page, polled at once, its own clock, nothing of step 1's result kept. Undefined when it
 *  cannot be followed (the same id, or a status URL with no `/r/<id>/` to rewrite): the row then polls step 1 at its
 *  cadence. A child another row already tracks closes step 1's row instead, so no id is tracked twice. */
const follow = (h: BughunterHunt, next: string, now: number): BughunterHunt | undefined => {
  const statusUrl = h.statusUrl?.replace(`/r/${h.id}/`, `/r/${next}/`)
  if (next === h.id || !statusUrl || statusUrl === h.statusUrl) return undefined
  if (huntList.some(x => x.id === next)) return { ...h, state: 'done', seen: true, settled: true, route: ROUTE_OVER }
  return { ...h, id: next, statusUrl, state: 'running', seen: false, findings: undefined, judged: undefined,
    settled: false, pressed: undefined, nextAt: now, startedAt: now, median: undefined, route: undefined }
}

async function observe($: Engine, kind: string, input: Record<string, unknown>, text: string | undefined, failed: boolean) {
  const body = failed ? undefined : bodyOf(text)
  if (!body) return
  const id = str(body.review_id) ?? str(input.review_id)
  if (!id) return
  const now = await $.clock.now()
  const cwd = await $.session.cwd()

  if (kind === 'submit_review') {
    const statusUrl = str(body.status_url)
    if (!statusUrl) return
    if (bandNow?.kind === 'deep' || bandNow?.kind === 'gate') setBand($, null)
    const done = str(body.status) === 'done'
    const h: BughunterHunt = { id, mode: huntLabel(body, 'fast'), state: done ? 'done' : 'running', statusUrl,
      cwd, session: sessionId, startedAt: now, median: num(body.recent_median_minutes), seen: done,
      nextAt: now + 60_000 }
    // The server answered with the hunt already queued or running for this input (or, for a second escalation, the
    // review's first deep hunt): nothing started, nothing charged. The hunt belongs to the chat that asked for it just
    // now: kept when it is this chat's, adopted when another chat tracks it, or the chat told "already running" would
    // track nothing. Not when another chat's agent has read it: the verdicts are owed there, and this agent can still
    // read it, which moves it here.
    const again = body.already_running === true || body.already_escalated === true
    await put($, id, cur => !cur ? h : !again ? h
      : ours(cur, cwd) || (cur.session !== sessionId && cur.seen) ? undefined : adopt(cur, cwd))
  } else if (kind === 'get_findings' || kind === 'wait_review') {
    const own = statusState(body)
    const terminal = own === 'done' || own === 'failed'
    // Read to its end here (the review's own status, whatever the route): the hunt is this chat's now, and whatever
    // the server said before, this chat owes the verdicts; a press note has done its job. A read that is not the end
    // (running, or an error with no state) moves nothing: the owning chat keeps polling it and keeps its note. An
    // answer older than the route the row holds moves nothing at all.
    const next = await put($, id, cur => {
      if (!cur) return undefined
      const r = routeRead(body, cur.route)
      if (!r) return undefined
      // Followed, not adopted: the child is a new hunt the owning chat keeps.
      const followed = r.next && follow(cur, r.next, now)
      if (followed) return followed
      const h = terminal ? adopt(cur, cwd) : cur
      return { ...h, route: r.route, state: r.state ?? h.state, seen: terminal || h.seen, settled: terminal ? false : h.settled,
        findings: own === 'done' ? findingsOf(body).length : h.findings, pressed: terminal ? undefined : h.pressed }
    })
    if (!next) return
    if (bandNow?.kind === 'hunt' && bandNow.id === id) setBand($, null)
    if (heldId === id) heldId = undefined
    // The deep offer comes in the answer for this tracked hunt, and only there.
    const offer = body.deep_offer as Record<string, unknown> | undefined
    if (kind === 'get_findings' && next.state === 'done' && !routeOpen(next) && offer && typeof offer === 'object' && str(offer.pitch)) {
      // A strong offer is the server's recommendation, with its reasons in the pitch; the price is the server's quote.
      // Its own buttons when the server sends their addresses; an older server's offer keeps the chat buttons.
      setBand($, { kind: 'deep', id, text: str(offer.pitch)!.slice(0, 280), strong: offer.strength === 'strong', price: num(offer.price_usd),
        start: buttonUrl(offer.start_url, next.statusUrl), snooze: buttonUrl(offer.snooze_url, next.statusUrl) })
    }
  } else if (kind === 'confirm_findings' && num(body.confirmed) !== undefined) {
    // The verdicts are in. On a routed step 1 the answer names where the route went: the child, or the rank the row
    // takes (polled at once while still open: the service decides on the verdicts). A confirm exists only for a done
    // review, so it reads as one. It never changes `seen`: that is the agent's read.
    const next = await put($, id, cur => {
      if (!cur) return undefined
      const r = routeRead({ ...body, status: 'done' }, cur.route)
      if (!r || r.route === undefined) return { ...cur, judged: true }
      const followed = r.next && follow(cur, r.next, now)
      if (followed) return followed
      const h: BughunterHunt = { ...cur, judged: true, route: r.route, state: r.state ?? cur.state }
      return r.route < ROUTE_OVER ? { ...h, nextAt: now } : h
    })
    if (!next) return
    if (bandNow?.id === id && bandNow.kind === 'hunt') setBand($, null)
  } else {
    return
  }
  await refreshStatus($)
}

/** The stored hunts, pruned to STALE_MS: the one list every session shares. */
async function loadHunts($: Engine, now: number): Promise<BughunterHunt[]> {
  const saved = (await $.store.get('hunts')) as BughunterHunt[] | undefined
  return Array.isArray(saved) ? saved.filter(h => now - h.startedAt < STALE_MS) : []
}

/** A hunt claimed by this chat in `cwd`. Taken from another chat, what that chat's agent did is not this agent's:
 *  unread here until this agent reads it, so it is told to read before it owes verdicts (a verdict sent stays sent:
 *  `judged` is the server's), and the other chat's press is not this one's. This chat's own hunt only moves to `cwd`. */
const adopt = (h: BughunterHunt, cwd: string): BughunterHunt => h.session === sessionId
  ? { ...h, cwd }
  : { ...h, session: sessionId, cwd, seen: false, pressed: undefined }

/** The one way a hunt is written: the store is read again, this one record changed as it stands there NOW, and the
 *  store written back and taken as this session's view. Another session's records are never written from this
 *  session's copy of them. `change` gets the stored record (undefined when none) and returns the new one, or undefined
 *  to write nothing. One write at a time per session: an await inside must not interleave two of them.
 *  shortcut: get-then-set is not atomic across sessions; two chats writing within the same few ms can still lose one
 *  write (the store has no compare-and-set). */
let writing: Promise<unknown> = Promise.resolve()
/** The store taken as this session's view, in the write queue: a read outside it could land after a write and undo it. */
const reload = ($: Engine) => put($, '', () => undefined)
function put($: Engine, id: string, change: (cur: BughunterHunt | undefined) => BughunterHunt | undefined) {
  const run = writing.then(async () => {
    const list = await loadHunts($, await $.clock.now())
    const at = list.findIndex(h => h.id === id)
    const next = change(at >= 0 ? list[at] : undefined)
    if (next) {
      if (at >= 0) list[at] = next; else list.push(next)
      await $.store.set('hunts', list)
    }
    setHunts($, list)
    return next
  })
  writing = run.catch(() => undefined)
  return run
}

async function refreshStatus($: Engine) {
  if (!ctx.showStatus) return
  const cwd = await $.session.cwd()
  const now = await $.clock.now()
  const mine = huntList.filter(h => ours(h, cwd))
  const unread = mine.find(h => !h.seen && !isOpen(h))
  const unjudged = mine.find(h => awaitsVerdicts(h, cwd, now))
  const running = mine.filter(isOpen)
  let text: string | undefined
  if (ctx.blocked && running.length) text = 'bughunt: status unreachable here, the agent polls instead'
  else if (unread) text = `bughunt ${unread.id} ${unread.state}${unread.findings === undefined ? '' : ` · ${unread.findings} found`}`
  else if (running.length === 1) {
    const h = running[0]!
    text = `bughunt ${h.mode} ${minutes(now - h.startedAt)}${h.median ? `/~${h.median}` : ''} min${h.state === 'needs_files' ? ' · files asked' : ''}`
  } else if (running.length > 1) text = `bughunt: ${running.length} running`
  else if (unjudged) text = `bughunt ${unjudged.id} · verdicts not sent`
  $.ui.status(text)
}

/** Called only on a state change the poll itself saw. */
async function announce($: Engine, h: BughunterHunt) {
  if (h.seen) return
  await $.ui.toast(`OhMyBug: ${news(h)}`)
  if (ctx.autoResume && !ctx.working && !ctx.draft) {
    await $.prompt.submit({ text: resumeText(h) })
    return
  }
  // While the agent is mid-turn it is likely to read the result itself in a
  // moment, and a band that vanishes by then is noise (owner report, 2026-10-23).
  // The toast already said it; the turn's end shows the band if it is still unread.
  if (ctx.working && !ctx.autoResume) { heldId = h.id; return }
  setBand($, { kind: 'hunt', id: h.id, state: h.state, text: news(h) })
}

async function tick($: Engine) {
  if (ctx.ticking) return
  ctx.ticking = true
  try {
    await pollDue($)
  } finally {
    ctx.ticking = false
  }
}

async function pollDue($: Engine) {
  const cwd = await $.session.cwd()
  const now = await $.clock.now()
  // Another chat may have taken a hunt over, read or judged it since: poll only what the store says is this chat's.
  // An unreadable store keeps the view this session has.
  try { await reload($) } catch { /* kept */ }
  // A done hunt nobody here has read yet is asked again on the slow clock: the
  // server knows when another session read or judged it, and the nudges (band,
  // auto-resume) then read that here with no network call of their own.
  for (const h of huntList.filter(x => ours(x, cwd) && x.state === 'done' && !x.seen && !routeOpen(x) && x.statusUrl && now >= x.nextAt)) {
    let body
    try {
      const res = await $.http.fetch(tagged(h.statusUrl!))
      body = res.ok ? JSON.parse(res.text) : undefined
    } catch {
      body = undefined
    }
    // Judged against the hunt as it stands now: a read here during the fetch wins.
    const cur = huntList.find(x => x.id === h.id)
    if (!cur || cur.seen) continue
    const settle = dealtWith(body)
    const next = await put($, h.id, x => x && ours(x, cwd) && !x.seen ? { ...x, nextAt: now + 240_000, ...(settle ? settledBy(body) : {}) } : undefined)
    if (!next) continue
    if (settle && bandNow?.kind === 'hunt' && bandNow.id === h.id) setBand($, null)
    if (settle && heldId === h.id) heldId = undefined
  }
  const due = huntList.filter(h => ours(h, cwd) && watched(h) && h.statusUrl && now >= h.nextAt)
  for (const h of due) {
    let res
    try {
      res = await $.http.fetch(tagged(h.statusUrl!))
    } catch {
      // A policy (sec-default, a proxy allowlist) refused the request. Say so
      // once in the status line rather than look like a hunt that never ends.
      ctx.blocked = true
      await apply($, h.id, () => ({ nextAt: now + 240_000 }))
      continue
    }
    ctx.blocked = false
    if (res.status === 404) { await apply($, h.id, cur => ({ state: 'failed', seen: true, ...(cur.route !== undefined ? { route: ROUTE_OVER } : {}) })); continue }
    let body
    try { body = res.ok ? JSON.parse(res.text) : undefined } catch { body = undefined }
    const wait = Math.min(240, Math.max(30, num(body?.next_poll_after_s) ?? 60))
    // Judged against the hunt as apply() finds it, not the copy taken before the
    // fetch: a tool result read meanwhile may already have moved it there, and a
    // body older than the route it holds moves nothing (routeRead).
    let moved = false
    let left = false
    const next = await apply($, h.id, cur => {
      const r = body && typeof body === 'object' ? routeRead(body, cur.route) : undefined
      if (!r) return { nextAt: now + wait * 1000 }
      const followed = r.next && follow(cur, r.next, now)
      if (followed) { left = true; return followed }
      const state = r.state
      moved = !!state && state !== cur.state
      // An ordinary hunt settles on its move to done; a routed one whenever it is done and this agent has not read it.
      const settled = state === 'done' && dealtWith(body) && (cur.route === undefined && r.route === undefined ? moved : !cur.seen)
      if (settled) left = true
      return { nextAt: now + wait * 1000, route: r.route, ...(moved ? { state, findings: num(body.findings) ?? cur.findings } : {}),
        ...(settled ? settledBy(body) : {}) }
    })
    // Followed or settled: nothing of the old row is left to show.
    if (left && bandNow?.kind === 'hunt' && bandNow.id === h.id) setBand($, null)
    if (left && heldId === h.id) heldId = undefined
    // Back to running (files served) is news to nobody.
    if (next && moved && next.state !== 'running') await announce($, next)
  }
  await refreshStatus($)
}

/** Change one open hunt of this chat as it stands NOW: the fetch awaited above may have let the agent read it, or
 *  another chat take it over, and a stale copy would undo either. */
async function apply($: Engine, id: string, change: (cur: BughunterHunt) => Partial<BughunterHunt>) {
  const cwd = await $.session.cwd()
  return put($, id, cur => cur && watched(cur) && ours(cur, cwd) ? { ...cur, ...change(cur) } : undefined)
}

const httpsUrl = (v: unknown): string | undefined => { const s = str(v); return s && /^https:\/\//.test(s) ? s : undefined }
/** `s` on the same https origin as `base`, with no userinfo, query or fragment (an empty `?` or `#` included), and,
 *  with `path`, under that path; undefined for anything else. */
function sameServer(v: unknown, base: string | undefined, path?: string): string | undefined {
  const s = httpsUrl(v)
  if (!s || !base || /[?#@]/.test(s)) return undefined
  try {
    const u = new URL(s)
    return u.origin === new URL(base).origin && (!path || u.pathname.startsWith(path)) ? s : undefined
  } catch { return undefined }
}
/** A button's address, only under the hunt's own server's offer door: anything else keeps the chat buttons, so a press
 *  never posts somewhere the hunt does not live. */
const buttonUrl = (v: unknown, statusUrl: string | undefined) => sameServer(v, statusUrl, '/deep-offer/')

/** One press of an offer button, sorted one way. Only the offer door's own refusals say "not started": 400 (an old
 *  button), 402 (no credit), 403 (the review's key is gone), 404 (the offer is gone), 409 (refused, the chat says why),
 *  429 (a limit). Anything else, a 408 or 503 a proxy may answer included, no answer within PRESS_WAIT_MS, or a 2xx that
 *  cannot be read, is unknown: the hunt may have started. */
type Pressed = { kind: 'ok'; body: Record<string, unknown> } | { kind: 'refused'; status: number } | { kind: 'unknown' }
const PRESS_WAIT_MS = 30_000
const REFUSED: Record<number, string> = {
  400: 'the button is out of date, update the plugin',
  402: 'no credit for a deep hunt',
  403: 'the key that ran this review is revoked or expired',
  404: 'this offer is no longer valid',
  409: 'ask in the chat to see why',
  429: 'a limit is reached, try later',
}
async function pressUrl($: Engine, url: string): Promise<Pressed> {
  let res
  try {
    const answer = $.http.fetch(url, { method: 'POST', headers: { 'x-ohmybug-press': '1' } })
    res = await Promise.race([answer, $.clock.sleep(PRESS_WAIT_MS).then(() => undefined)])
  } catch { return { kind: 'unknown' } }
  if (!res) return { kind: 'unknown' }
  if (REFUSED[res.status]) return { kind: 'refused', status: res.status }
  if (!res.ok) return { kind: 'unknown' }
  try {
    const body = JSON.parse(res.text) as unknown
    return body && typeof body === 'object' ? { kind: 'ok', body: body as Record<string, unknown> } : { kind: 'unknown' }
  } catch { return { kind: 'unknown' } }
}

const START_IN_CHAT = (parent: string) => `Yes, run the deep hunt for ${parent}.`
const SNOOZE_IN_CHAT = 'Not today: do not offer me the deep hunt for the next 24 hours. Call set_policy with snooze {"deep": 24}, and say when it ends.'

/** Run deep hunt, pressed. A refusal is said and nothing changes. An unknown answer falls back to the chat button: a
 *  second escalation of the same review starts nothing on the server, so asking the agent cannot start a second hunt.
 *  A deep hunt the server answered with is said first, then tracked through put(): added when no chat tracks it,
 *  kept as it is when this chat does, and adopted from another chat (unread here, so this agent is told to read it). */
async function pressStart($: Engine, parent: string, url: string) {
  const r = await pressUrl($, url)
  if (r.kind === 'refused') { await $.ui.toast(`OhMyBug: deep hunt not started: ${REFUSED[r.status]}.`); return }
  const id = r.kind === 'ok' ? str(r.body.review_id) : undefined
  const statusUrl = r.kind === 'ok' ? sameServer(r.body.status_url, url) : undefined
  if (r.kind !== 'ok' || !id || !statusUrl) {
    await $.ui.toast('OhMyBug: no answer from the server: asking in the chat instead.')
    await $.prompt.submit({ text: START_IN_CHAT(parent) })
    return
  }
  await $.ui.toast(r.body.started === true ? `OhMyBug: deep hunt ${id} started for ${parent}.` : `OhMyBug: deep hunt ${id} already exists for ${parent}.`)
  try {
    const cwd = await $.session.cwd()
    const now = await $.clock.now()
    await put($, id, cur => !cur
      ? { id, mode: huntLabel(r.body, 'full'), state: 'running', statusUrl, cwd, session: sessionId, startedAt: now, seen: false,
          nextAt: now + 15_000, pressed: { parent } }
      : ours(cur, cwd) ? undefined : { ...adopt(cur, cwd), pressed: { parent } })
    await refreshStatus($)
  } catch {
    // Said already; a bookkeeping slip must not hide that the hunt exists.
  }
}

/** Not today, pressed: the server's pause, said as the server answered it; an unknown answer falls back to the chat. */
async function pressSnooze($: Engine, url: string) {
  const r = await pressUrl($, url)
  if (r.kind === 'refused') { await $.ui.toast(`OhMyBug: deep offers not paused: ${REFUSED[r.status]}.`); return }
  const until = r.kind === 'ok' ? str(r.body.snoozed_until) : undefined
  const at = until ? new Date(until) : undefined
  if (at && !Number.isNaN(at.getTime())) { await $.ui.toast(`OhMyBug: deep offers paused until ${at.toLocaleString()}.`); return }
  await $.ui.toast('OhMyBug: no answer from the server: asking in the chat instead.')
  await $.prompt.submit({ text: SNOOZE_IN_CHAT })
}

/** What the agent is told about a deep hunt the person started from the band: it did not call submit_review for it. */
const pressedNote = (h: BughunterHunt) =>
  `The person started OhMyBug deep hunt ${h.id} from the offer button for ${h.pressed!.parent}; it is tracked. Do not call submit_review for it. Read it with get_findings (review_id ${h.id}) ${h.state === 'done' || h.state === 'failed' ? 'now: it has ended' : 'when it ends'}.`

export const register: Register = on => {
  // Read from the environment, not the manifest's userConfig: older Claude Code
  // validates plugin.json strictly and refuses keys it does not know, and a
  // refused manifest would take the shell gate down with it. The environment is
  // also where managed settings put a team's choice.
  on('session.start', async ($, e, next) => {
    ctx.showStatus = (await $.env.get('OHMYBUG_STATUS')) !== '0'
    ctx.autoResume = (await $.env.get('OHMYBUG_AUTO_RESUME')) === '1'
    sessionId = String((await $.session.id()) ?? '')
    bandNow = null
    heldId = undefined
    ctx.working = false
    const now = await $.clock.now()
    setHunts($, await loadHunts($, now))
    await $.command.register({ name: 'hunts', description: 'OhMyBug: the hunts of this repository, in a pane' })
    $.clock.every(15_000, () => { void tick($) })
    await refreshStatus($)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const tool = String(e.tool)
    const kind = toolKind(tool)
    if (!kind && tool !== 'Bash') return next(e)
    const ran = await next(e)
    const failed = ran.deny !== undefined || ran.isError === true
    try {
      if (kind) await observe($, kind, e as unknown as Record<string, unknown>, ran.deny ?? ran.text, failed)
      else await observeGate($, String((e as unknown as Record<string, unknown>).command ?? ''), ran.deny ?? ran.text, failed)
    } catch {
      // The call already happened; a bookkeeping slip must not touch its result.
    }
    return ran
  })

  // What the mod tells the agent. A hunt it read whose verdicts it has not sent, which the status line tells the person
  // too unless another hunt that runs or waits to be read holds it: gone once confirm_findings for that id is seen or
  // the hunt is 6 hours old. And a deep hunt the person started from the band, until the agent reads it.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    try {
      const cwd = await $.session.cwd()
      const now = await $.clock.now()
      const lines = [
        // A deep hunt the person started from the band, until the agent reads it: the agent did not submit it.
        ...huntList.filter(h => ours(h, cwd) && h.pressed && (!h.seen || h.settled) && now - h.startedAt < STALE_MS).map(pressedNote),
        // Shown to the person or not told to the agent: OHMYBUG_STATUS=0 drops the verdicts line (the press note is not
        // a status-line line: the person pressed, and the agent must know the hunt is not its own).
        ...huntList.filter(h => ctx.showStatus && awaitsVerdicts(h, cwd, now)).map(h => h.findings === 0
          ? `OhMyBug hunt ${h.id} is done with 0 findings and is not confirmed yet. Next: confirm_findings for ${h.id} with verdicts: [].`
          : `OhMyBug hunt ${h.id} is done and its verdicts are not sent. Next: verify each finding, then confirm_findings for ${h.id}.`),
      ]
      if (!lines.length) return composed
      return { sections: [...composed.sections, { id: 'bughunter:next-step', text: lines.join('\n'), scope: 'session' as const }] }
    } catch {
      return composed
    }
  })

  // Auto-resume, opt-in only: a band for a hunt whose move the poll saw while a
  // turn ran is taken up when the turn ends, if that hunt is still in that state.
  on('turn.complete', async ($, e, next) => {
    const out = await next(e)
    if (e.agentId) return out
    ctx.working = false
    const h = ctx.autoResume && !ctx.draft ? actionable(bandNow) : undefined
    if (h) {
      setBand($, null)
      await $.prompt.submit({ text: resumeText(h) })
    }
    // An empty band, or the gate refusal for this very hunt: the hunt finished, so the refusal is obsolete.
    else if (!ctx.autoResume && (!bandNow || (bandNow.kind === 'gate' && bandNow.id === heldId))) {
      const u = huntList.find(x => x.id === heldId && x.session === sessionId && !x.seen && x.state !== 'running')
      heldId = undefined
      if (u) setBand($, { kind: 'hunt', id: u.id, state: u.state, text: news(u) })
    }
    return out
  })

  on('turn.start', ($, e, next) => {
    ctx.working = true
    // A gate refusal is news for the turn it happened in; the band does not linger.
    if (bandNow?.kind === 'gate') setBand($, null)
    // A hunt's news has no Later to close it (#2343), so the person's next turn takes it away. Not under
    // auto-resume: that band is what the turn end resumes (a draft parked it), and not on a subagent's turn,
    // which runs inside the main one. The deep offer waits for the person's answer.
    else if (bandNow?.kind === 'hunt' && !ctx.autoResume && !e.agentId) setBand($, null)
    return next(e)
  })

  on('ui.render', { component: 'PromptHint' }, ($, e, next) => {
    ctx.draft = e.props.isDraft
    ctx.working = e.props.isWorking
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = bandNow
    if (!b || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const close = () => setBand($, null)
    let actions: RenderChildren[] = []
    let lead = ''
    if (b.kind === 'deep') {
      // Pressing Run is the person's consent; Not now sends nothing; Not today pauses the offer for a day. With the
      // offer's own addresses a press goes to the server; without them (an older server) it is a chat message.
      lead = `Deep hunt ${b.strong ? 'recommended' : 'offered'} for ${b.id}${b.price !== undefined ? ` (${b.price} USD, only if a real bug is confirmed)` : ''}: `
      actions = [
        <Button key="deep-yes" label="Run deep hunt" hotkey="1" variant="primary" onPress={async () => {
          // Closed before the request: a second press cannot happen while the first is in flight.
          close()
          if (b.start) await pressStart($, b.id, b.start)
          else await $.prompt.submit({ text: START_IN_CHAT(b.id) })
        }} />,
        <Button key="deep-no" label="Not now" hotkey="2" role="dismiss" onPress={close} />,
        // The person's own word: the offer stays quiet for a day, kept by the server for every session (pressed to it
        // directly, or written by the agent with set_policy on an older server); asking for a deep hunt still works.
        <Button key="deep-snooze" label="Not today" hotkey="3" onPress={async () => {
          close()
          if (b.snooze) await pressSnooze($, b.snooze)
          else await $.prompt.submit({ text: SNOOZE_IN_CHAT })
        }} />,
      ]
    } else if (b.kind === 'gate') {
      // The refusal is the agent's own tool result, and its watch polls the hunt: nothing for the person to press (#2343).
      lead = 'Merge blocked: '
    } else if (!actionable(b)) {
      // A hunt band whose hunt was read or moved on: nothing to draw.
      return next(e)
    }
    // A hunt band that is drawn says what happened and offers nothing (#2343): the agent's watch wakes it on done,
    // failed and needs_files, so a Continue only added a duplicate turn. Buttons stay where only the person decides.
    return (
      <Box flexDirection="column">
        <Text><Text color="red">OhMyBug</Text> {lead}{b.text}</Text>
        {actions.length ? <Box>{actions}</Box> : null}
      </Box>
    )
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const kind = toolKind(e.props.tool)
    if (!kind || kind === 'submit_review' || e.props.isErrored) return next(e)
    const body = bodyOf(e.props.output)
    if (!body || body.error) return next(e)
    const { Box, Button, Link, Text } = $.ui.resolve(e)
    const toggle = (
      <Button key="raw" plain dimColor label={rawOpen.has(e.requestId) ? 'show the card' : 'show the raw answer'}
        onPress={() => toggleRaw($, e.requestId)} />
    )
    if (rawOpen.has(e.requestId)) return <Box flexDirection="column">{await next(e)}{toggle}</Box>

    // The hunt's one mascot, only as the server sends it; with none, the head line alone.
    // The pixels go only to the terminal, where a cell is square enough for half blocks.
    const withMascot = (head: RenderChildren) => {
      const m = mascotOf(body)
      if (!m) return head
      const side = [
        head,
        <Text bold>{m.name}{m.isNew ? ' — new!' : ''}</Text>,
        <Text dimColor>{m.isNew ? 'new to your Bugarium' : 'in your Bugarium'} · {m.caught} of {m.total} caught</Text>,
        <Text dimColor><Link href={m.url} /></Text>,
      ]
      if (e.surface !== 'terminal') return <Box flexDirection="column">{side}</Box>
      const pixels = halfBlocks(m.sprite).map(row => (
        <Text>{row.map(({ top, bottom }) => top && bottom ? <Text color={top} backgroundColor={bottom}>▀</Text>
          : top ? <Text color={top}>▀</Text> : bottom ? <Text color={bottom}>▄</Text> : ' ')}</Text>
      ))
      return (
        <Box flexDirection="row">
          <Box flexDirection="column">{pixels}</Box>
          <Box flexDirection="column" marginLeft={3}>{side}</Box>
        </Box>
      )
    }
    let rows
    if (kind === 'confirm_findings') {
      const species = Array.isArray(body.species) ? (body.species as Record<string, unknown>[]) : []
      const pending = num(body.species_pending) ?? 0
      const confirmed = num(body.confirmed)
      if (confirmed === undefined) return next(e)
      // Field notes: other hunters' lessons about the species, already in the
      // agent's context through the answer itself. Shown, never sent anywhere.
      const lessonsOf = (s: Record<string, unknown>) =>
        Array.isArray(s.lessons) ? s.lessons.flatMap(l => str(l) ?? []) : []
      const notes = species.reduce((n, s) => n + lessonsOf(s).length, 0)
      rows = [
        withMascot(<Text>verdicts recorded · {confirmed} confirmed{num(body.minor_confirmed) ? ` · ${body.minor_confirmed} minor` : ''}</Text>),
        // The catch: what this confirm matched to a species, one line each.
        ...catchOf(body).map(c => <Text>+{c.count} {c.species.name}</Text>),
        ...species.map(s => (
          <Box flexDirection="column">
            <Text>
              <Text dimColor>{str(s.finding_id) ?? '?'} →</Text> {speciesOf(s)?.name ?? '?'}
            </Text>
            {speciesOf(s) ? <Text dimColor>{'    '}<Link href={speciesOf(s)!.url} /></Text> : null}
            {lessonsOf(s).map(l => <Text dimColor>{'    '}· {l.slice(0, 240)}</Text>)}
          </Box>
        )),
        pending ? <Text dimColor>{pending} still being matched to a bug species</Text> : null,
        notes ? <Text dimColor>{notes} field note{notes === 1 ? '' : 's'} from other hunters {notes === 1 ? 'is' : 'are'} in the agent's context</Text> : null,
      ]
    } else {
      // The card draws what the review says; the route only decides whether the watch goes on.
      const state = statusState(body)
      const id = str(body.review_id) ?? '?'
      if (state !== 'done') {
        rows = [<Text dimColor>hunt {id} · {state === 'needs_files' ? 'reviewers asked for files' : state ?? 'running'}{body.timed_out ? ' · still running' : ''}</Text>]
      } else {
        const found = findingsOf(body).sort((a, b) => SEVERITY.indexOf(a.severity) - SEVERITY.indexOf(b.severity))
        rows = [
          withMascot(<Text>{huntLabel(body, 'fast')} hunt {id} · done · {found.length} finding{found.length === 1 ? '' : 's'}</Text>),
          ...found.map(f => (
            <Box flexDirection="column">
              <Text>
                <Text color={COLOR[f.severity]} dimColor={!COLOR[f.severity]}>● {f.severity.padEnd(8)}</Text>
                {f.id}  {f.title}
                {/* The finding's bug species, a grey label at the line's end. */}
                {f.species ? <Text dimColor>  · <Link href={f.species.url} label={f.species.name} /></Text> : null}
              </Text>
              {f.where ? <Text dimColor>{'           '}{f.where}</Text> : null}
            </Box>
          )),
          found.length === 0 && str(body.summary) ? <Text>{str(body.summary)}</Text> : null,
          str(body.next_step) ? <Text dimColor>next: {str(body.next_step)!.slice(0, 240)}</Text> : null,
          // The band exists only for a tracked hunt's get_findings; point at it only then.
          body.deep_offer ? <Text dimColor>a deep hunt is on offer{bandNow?.kind === 'deep' && bandNow.id === id ? ' (see above the prompt)' : ''}</Text> : null,
        ]
      }
    }
    return <Box flexDirection="column">{rows}{toggle}</Box>
  })

  on('command.run', { command: 'hunts' }, async $ => {
    await $.ui.open({ id: PANE, title: 'OhMyBug hunts' })
    return { text: 'OhMyBug hunts pane opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const cwd = await $.session.cwd()
    const now = await $.clock.now()
    const mine = huntList.filter(h => ours(h, cwd)).reverse()
    if (!mine.length) return <Text dimColor>No hunts in this repository in the last 6 hours.</Text>
    return (
      <Box flexDirection="column">
        {mine.map(hunt => (
          <Box flexDirection="column">
            <Text>
              <Text color={isOpen(hunt) ? 'yellow' : hunt.state === 'failed' ? 'red' : 'green'}>{isOpen(hunt) ? '●' : hunt.state === 'failed' ? '✗' : '✓'}</Text>
              {' '}{hunt.id} {hunt.mode} · {hunt.state === 'needs_files' ? 'files asked' : hunt.state}
            </Text>
            <Text dimColor>
              {'  '}{minutes(now - hunt.startedAt)} min ago{hunt.median && isOpen(hunt) ? ` · runs take ~${hunt.median} min` : ''}
              {hunt.findings !== undefined ? ` · ${hunt.findings} found` : ''}{!hunt.seen && !isOpen(hunt) ? ' · not read yet' : ''}
            </Text>
          </Box>
        ))}
      </Box>
    )
  })
}
