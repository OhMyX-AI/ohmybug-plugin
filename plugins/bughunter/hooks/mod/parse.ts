// Pure readers of what the OhMyBug MCP tools and status URL answer. Every
// reader returns undefined on a shape it does not know, and the caller then
// leaves the engine's own drawing alone: this mod renders, it never decides.

export const OMB_TOOL = /^mcp__.*ohmybug.*__(submit_review|get_findings|wait_review|confirm_findings)$/

export const toolKind = (tool: string): string | undefined => OMB_TOOL.exec(tool)?.[1]

/** The text an MCP result carries: a string, content blocks, or { content }. */
export function textOf(output: unknown): string | undefined {
  if (typeof output === 'string') return output
  const blocks = Array.isArray(output) ? output
    : output && typeof output === 'object' && Array.isArray((output as { content?: unknown }).content)
      ? (output as { content: unknown[] }).content : undefined
  if (!blocks) return undefined
  const text = blocks.map(b => (b && typeof b === 'object' && (b as { type?: unknown }).type === 'text'
    ? String((b as { text?: unknown }).text ?? '') : '')).join('')
  return text || undefined
}

export type Body = Record<string, unknown>

/** The JSON object an OhMyBug tool answered, or undefined. */
export function bodyOf(output: unknown): Body | undefined {
  const text = textOf(output)
  if (!text) return undefined
  try {
    const v: unknown = JSON.parse(text)
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Body) : undefined
  } catch {
    return undefined
  }
}

export const str = (v: unknown): string | undefined => (typeof v === 'string' && v ? v : undefined)
/** A hunt's label: the stage-one mode the server echoes as hunt_mode (cheap, ultrafast, fast), else the stage
 * (fast or full), else `otherwise`; a value outside those lists is never drawn. */
export const huntLabel = (body: Record<string, unknown>, otherwise: string): string => {
  const stage = str(body.mode), mode = str(body.hunt_mode)
  if (stage === 'full') return stage
  if (mode === 'cheap' || mode === 'ultrafast' || mode === 'fast') return mode
  return stage === 'fast' ? stage : otherwise
}
export const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)

/** A bug species as the card draws it: the page link is built here from the slug — no URL from the server
 *  is ever drawn — and the name is the catalogue's own, checked against its pattern; one that does not match shows the slug. */
export type Species = { slug: string; name: string; url: string }
const SLUG = /^[a-z0-9-]{1,64}$/
const NAME = /^[A-Za-z0-9 ',-]{1,60}$/
export const BUGS = 'https://mcp.ohmybug.ai/bugs/'
export function speciesOf(v: unknown): Species | undefined {
  const o = v && typeof v === 'object' ? (v as Body) : undefined
  const slug = typeof o?.slug === 'string' && SLUG.test(o.slug) ? o.slug : undefined
  if (!slug) return undefined
  const name = typeof o?.name === 'string' && NAME.test(o.name) ? o.name : slug
  return { slug, name, url: BUGS + slug }
}

export type Finding = { id: string; severity: string; where: string; title: string; species?: Species }

export function findingsOf(body: Body): Finding[] {
  const list = Array.isArray(body.findings) ? body.findings : []
  return list.flatMap(f => {
    if (!f || typeof f !== 'object') return []
    const o = f as Body
    const id = str(o.finding_id) ?? str(o.id)
    if (!id) return []
    const line = num(o.line)
    // The bug species the server filed against it.
    const species = speciesOf(o.species)
    return [{ id, severity: (str(o.severity) ?? '?').toLowerCase(), title: str(o.title) ?? '',
      where: str(o.file) ? `${o.file}${line ? `:${line}` : ''}` : '',
      ...(species ? { species } : {}) }]
  })
}

/** The status a poll of the status URL reports, in the mod's own words. */
export function pollState(body: Body): 'running' | 'needs_files' | 'done' | 'failed' | undefined {
  const s = str(body.status)
  if (s === 'done' || s === 'failed') return s
  // Either flag means reviewers wait on files; the status word stays 'running'.
  if (body.files_requested === true || body.awaiting_client_files === true || s === 'needs_files') return 'needs_files'
  return s ? 'running' : undefined
}

/** The merge gate's own words, when it refused a Bash call. Shown, never acted on. */
export function gateReason(text: string | undefined): string | undefined {
  const line = text?.split('\n').map(l => l.trim()).find(l => /^OhMyBug(?: gate)?: /.test(l))
  return line?.replace(/^OhMyBug(?: gate)?: /, '')
}

export const minutes = (ms: number): number => Math.max(0, Math.round(ms / 60000))

/** The confirm's catch: one line per species the answer carries, counted, in first-seen order. */
export function catchOf(body: Body): { species: Species; count: number }[] {
  const out = new Map<string, { species: Species; count: number }>()
  for (const s of Array.isArray(body.species) ? body.species : []) {
    const sp = speciesOf(s)
    if (sp) { const c = out.get(sp.slug); if (c) c.count++; else out.set(sp.slug, { species: sp, count: 1 }) }
  }
  return [...out.values()]
}

/** A pixel mascot: rows of '.' (clear), '#' (body, in `color`) and 'o' (eye). */
export type Sprite = { color: string; rows: string[] }
/** The hunt's one mascot, exactly as the server picked it: the plugin picks nothing itself. */
export type Mascot = Species & { isNew: boolean; caught: number; total: number; sprite: Sprite }

const HEX = /^#[0-9a-f]{6}$/i
const SPRITE_MAX = 24
/** A sprite the card can draw, or undefined: an even number of equal rows, at most 24 by 24, of the three cell kinds. */
export function spriteOf(v: unknown): Sprite | undefined {
  const o = v && typeof v === 'object' ? (v as Body) : undefined
  const color = str(o?.color)
  const rows = Array.isArray(o?.rows) ? (o!.rows as unknown[]) : undefined
  if (!color || !HEX.test(color) || !rows?.length || rows.length > SPRITE_MAX || rows.length % 2) return undefined
  const w = typeof rows[0] === 'string' ? rows[0].length : 0
  if (!w || w > SPRITE_MAX || !rows.every(r => typeof r === 'string' && r.length === w && /^[.#o]+$/.test(r))) return undefined
  return { color, rows: rows as string[] }
}

const whole = (v: unknown): number | undefined => (Number.isInteger(v) && (v as number) >= 0 ? (v as number) : undefined)
/** The server's `mascot` field, or undefined: the slug, `new`, the counts and the sprite must all read, or nothing is
 *  drawn; a name outside the pattern shows the slug, as everywhere else, and a `url` from the server is never used. */
export function mascotOf(body: Body): Mascot | undefined {
  const o = body.mascot && typeof body.mascot === 'object' ? (body.mascot as Body) : undefined
  const sp = speciesOf(o)
  const caught = whole(o?.caught), total = whole(o?.total)
  const sprite = spriteOf(o?.sprite)
  if (!o || !sp || caught === undefined || total === undefined || caught > total || typeof o.new !== 'boolean' || !sprite) return undefined
  return { ...sp, isNew: o.new, caught, total, sprite }
}

/** The terminal rows of a sprite, one per pair of its rows: per column, the upper and lower pixel's colour, or undefined when clear. */
export function halfBlocks(s: Sprite, eye = '#fafafa'): { top?: string; bottom?: string }[][] {
  const paint = (c: string | undefined) => (c === '#' ? s.color : c === 'o' ? eye : undefined)
  const out: { top?: string; bottom?: string }[][] = []
  for (let y = 0; y < s.rows.length; y += 2) out.push([...s.rows[y]].map((c, x) => ({ top: paint(c), bottom: paint(s.rows[y + 1][x]) })))
  return out
}
