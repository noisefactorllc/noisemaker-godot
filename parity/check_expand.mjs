// check_expand.mjs — EXPANDER parity gate. For every corpus + program DSL, compare the GDScript
// expander's output (candidate, via _expand_dump.gd) against the REFERENCE expander (oracle, via
// dump-expand.mjs), both fed effects the way tools/export-graph.mjs does. Key-order-insensitive deep
// compare per file; numbers under a tight relative epsilon (see check_parse).
//
//   NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot node parity/check_expand.mjs [file...]
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readdirSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')
const GODOT = process.env.GODOT || '/Applications/Godot.app/Contents/MacOS/Godot'
const EFFECTS_DIR = join(REPO, 'godot', 'addons', 'noisemaker', 'effects')

if (!process.env.NM_REFERENCE_ROOT) { console.error('NM_REFERENCE_ROOT is not set'); process.exit(3) }

function gather(dir) {
    if (!existsSync(dir)) return []
    const out = []
    for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name)
        if (e.isDirectory()) out.push(...gather(p))
        else if (e.name.endsWith('.dsl')) out.push(p)
    }
    return out
}

let files = process.argv.slice(2)
if (files.length === 0) files = [...gather(join(REPO, 'parity', 'programs')), ...gather(join(REPO, 'parity', 'corpus'))]
files = [...new Set(files.map(f => resolve(f)))].sort()
if (files.length === 0) { console.error('no DSL files found'); process.exit(2) }

const oracle = JSON.parse(execFileSync('node', [join(REPO, 'tools', 'dump-expand.mjs'), EFFECTS_DIR, ...files],
    { encoding: 'utf8', maxBuffer: 1 << 28 }))

const candRaw = execFileSync(GODOT, ['--headless', '--path', join(REPO, 'godot'),
    '--script', 'res://addons/noisemaker/compiler/_expand_dump.gd', '--', ...files],
    { encoding: 'utf8', maxBuffer: 1 << 28 })
const markerLine = candRaw.split('\n').find(l => l.startsWith('EXPANDDUMP:'))
if (!markerLine) { console.error('no EXPANDDUMP output. tail:\n' + candRaw.slice(-2000)); process.exit(2) }
const cand = JSON.parse(markerLine.slice('EXPANDDUMP:'.length))

function numEq(a, b) {
    if (a === b) return true
    return Math.abs(a - b) <= 1e-12 * Math.max(1, Math.abs(a), Math.abs(b))
}
function eq(a, b) {
    if (a === b) return true
    if (typeof a === 'number' && typeof b === 'number') return numEq(a, b)
    if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return a === b
    if (Array.isArray(a) !== Array.isArray(b)) return false
    if (Array.isArray(a)) {
        if (a.length !== b.length) return false
        for (let i = 0; i < a.length; i++) if (!eq(a[i], b[i])) return false
        return true
    }
    const ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    for (const k of ka) { if (!(k in b) || !eq(a[k], b[k])) return false }
    return true
}
function firstDiff(a, b, path) {
    if (eq(a, b)) return null
    const ta = a === null ? 'null' : Array.isArray(a) ? 'array' : typeof a
    const tb = b === null ? 'null' : Array.isArray(b) ? 'array' : typeof b
    if (ta !== tb || (ta !== 'object' && ta !== 'array')) return `${path}: ref=${JSON.stringify(a)} mine=${JSON.stringify(b)}`
    if (Array.isArray(a)) {
        if (a.length !== b.length) return `${path}: length ref=${a.length} mine=${b.length}`
        for (let i = 0; i < a.length; i++) { const d = firstDiff(a[i], b[i], `${path}[${i}]`); if (d) return d }
        return `${path}: (array differs)`
    }
    const keys = new Set([...Object.keys(a), ...Object.keys(b)])
    for (const k of keys) {
        if (!(k in a)) return `${path}.${k}: missing in ref (mine=${JSON.stringify(b[k])})`
        if (!(k in b)) return `${path}.${k}: missing in mine (ref=${JSON.stringify(a[k])})`
        const d = firstDiff(a[k], b[k], `${path}.${k}`); if (d) return d
    }
    return `${path}: (object differs)`
}

let pass = 0, fail = 0
const failed = []
for (const f of files) {
    const o = oracle[f], c = cand[f]
    const rel = f.replace(REPO + '/', '')
    if (!o) { fail++; failed.push(`${rel}: missing from oracle`); continue }
    if (!c) { fail++; failed.push(`${rel}: missing from candidate`); continue }
    if (!o.ok) { if (!c.ok) { pass++; continue } fail++; failed.push(`${rel}: ref errored but candidate ok`); continue }
    if (!c.ok) { fail++; failed.push(`${rel}: candidate errored but ref ok`); continue }
    if (eq(o.out, c.out)) { pass++; continue }
    fail++
    failed.push(`${rel}: ${firstDiff(o.out, c.out, 'out')}`)
}
console.log(`EXPAND PARITY: ${pass}/${files.length} pass`)
for (const x of failed.slice(0, 25)) console.log('  DIFF ' + x)
process.exit(fail === 0 ? 0 : 1)
