// sift-describe: in a Swift repository with `sift` on PATH, appends one paragraph to the Read, Grep and
// Glob descriptions pointing Swift lookups at sift's index. Decided once, at session.start, because
// tool.describe fires once per tool and its answer is cached for the session: a description that
// changed between requests would spend the prompt cache. No network, nothing written; any failure
// leaves the descriptions as the engine wrote them.
//
// Applies under `claude -p` as in an interactive session. A build that searches through Bash has no
// Grep or Glob tool, so there only Read's description changes.
//
// Off switch: SIFT_MOD=off, or a file named `mod-off` in sift's home ($SIFT_HOME, else ~/.sift).
//
// Opt-in experiment: SIFT_MOD_BASH=on also appends BASH_NOTE, a separate short paragraph, to Bash's
// description (does naming sift there move the grep/cat habit?). Bash is always matched below, and the
// handler returns its description unchanged unless the var is on and the mod would extend at all.
import type { EngineInterface, FsEntry, Register } from 'claude-code'

// Wording from Sift.md's routing table; every claim is something sift answers today.
export const NOTE =
  'sift indexes the Swift code here: ask it before reading or grepping a .swift file. ' +
  '`digest` a type, file or `Type.member` for its line ranges, then Read only that range; ' +
  '`where` instead of grep for definitions, callers, conformers; `search` for code by shape; ' +
  '`strings` for UI text. Via the sift MCP tools, or `sift digest ...` from Bash.'

// Wording from Sift.md's routing lines; it claims only that the tools exist, not that any hook answers.
export const BASH_NOTE =
  'For Swift sources, use the sift tools or the `sift` CLI (digest, where, search, strings) ' +
  'before grep, cat or sed on .swift files.'

// Directories never searched for Swift files at depth 2, and a cap on how many are.
const SKIP = new Set(['node_modules', 'DerivedData', 'Pods', 'build'])
const MAX_SUBDIRS = 64

// Set by session.start; undefined until then, so a describe that came first leaves the text alone.
let decided: Promise<boolean> | undefined
let bashOptIn: Promise<boolean> | undefined

async function isBashOptedIn($: EngineInterface): Promise<boolean> {
  try {
    return (await $.env.get('SIFT_MOD_BASH')) === 'on'
  } catch {
    return false
  }
}

async function list($: EngineInterface, path: string): Promise<readonly FsEntry[]> {
  try {
    return await $.fs.list(path)
  } catch {
    return []
  }
}

function parentOf(dir: string): string {
  const cut = dir.replace(/\/+$/, '').lastIndexOf('/')
  return cut <= 0 ? '/' : dir.slice(0, cut)
}

const isProject = (entry: FsEntry) => entry.name === 'Package.swift' || entry.name.endsWith('.xcodeproj')
const isSwiftFile = (entry: FsEntry) => entry.kind !== 'dir' && entry.name.endsWith('.swift')

// The working directory or an ancestor holds Package.swift or an .xcodeproj, or a .swift file stands
// at depth 1 or 2 beneath the working directory.
async function isSwiftRepo($: EngineInterface, cwd: string): Promise<boolean> {
  const top = await list($, cwd)
  if (top.some(isProject) || top.some(isSwiftFile)) return true
  for (let dir = parentOf(cwd); ; dir = parentOf(dir)) {
    if ((await list($, dir)).some(isProject)) return true
    if (dir === '/') break
  }
  const subdirs = top.filter(e => e.kind === 'dir' && !e.name.startsWith('.') && !SKIP.has(e.name))
  for (const sub of subdirs.slice(0, MAX_SUBDIRS)) {
    if ((await list($, `${cwd}/${sub.name}`)).some(isSwiftFile)) return true
  }
  return false
}

async function isSwitchedOff($: EngineInterface): Promise<boolean> {
  if ((await $.env.get('SIFT_MOD')) === 'off') return true
  const siftHome = await $.env.get('SIFT_HOME')
  const home = await $.env.get('HOME')
  const dir = siftHome?.startsWith('/') ? siftHome : home?.startsWith('/') ? `${home}/.sift` : undefined
  return dir !== undefined && (await $.fs.exists(`${dir}/mod-off`))
}

async function isSiftOnPath($: EngineInterface): Promise<boolean> {
  const found = await $.process.run(['which', 'sift'], { timeoutMs: 5000 })
  return found.exitCode === 0
}

async function decide($: EngineInterface, cwd: string): Promise<boolean> {
  try {
    if (await isSwitchedOff($)) return false
    return (await isSwiftRepo($, cwd)) && (await isSiftOnPath($))
  } catch {
    return false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    decided = decide($, e.cwd)
    bashOptIn = isBashOptedIn($)
    await decided
    return next(e)
  })

  on('tool.describe', { tool: ['Read', 'Grep', 'Glob', 'Bash'] }, async ($, e, next) => {
    const described = await next(e)
    const extend = decided === undefined ? false : await decided
    const note = e.tool === 'Bash' ? ((await bashOptIn) === true ? BASH_NOTE : undefined) : NOTE
    if (!extend || note === undefined || described.description.includes(note)) return described
    return { ...described, description: `${described.description}\n\n${note}` }
  })
}
