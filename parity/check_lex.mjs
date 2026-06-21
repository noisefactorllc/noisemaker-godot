// check_lex.mjs — LEXER parity gate. For every corpus + program DSL, compare the GDScript lexer's
// token stream (candidate, via _lex_dump.gd) against the REFERENCE lexer (oracle, via
// dump-tokens.mjs). Deep value-compare per file; report PASS / DIFF + the first divergence.
//
//   NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot node parity/check_lex.mjs [file...]
//
// One node launch (oracle) + one Godot launch (candidate) over ALL files — fast. The reference
// is the only authority; this gate has no TD dependency.
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readdirSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')
const GODOT = process.env.GODOT || '/Applications/Godot.app/Contents/MacOS/Godot'

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
if (files.length === 0) {
    files = [...gather(join(REPO, 'parity', 'programs')), ...gather(join(REPO, 'parity', 'corpus'))]
}
files = [...new Set(files.map(f => resolve(f)))].sort()
if (files.length === 0) { console.error('no DSL files found'); process.exit(2) }

const oracle = JSON.parse(execFileSync('node', [join(REPO, 'tools', 'dump-tokens.mjs'), ...files],
    { encoding: 'utf8', maxBuffer: 1 << 28 }))

const candRaw = execFileSync(GODOT, ['--headless', '--path', join(REPO, 'godot'),
    '--script', 'res://addons/noisemaker/compiler/_lex_dump.gd', '--', ...files],
    { encoding: 'utf8', maxBuffer: 1 << 28 })
const markerLine = candRaw.split('\n').find(l => l.startsWith('LEXDUMP:'))
if (!markerLine) { console.error('no LEXDUMP output from candidate. tail:\n' + candRaw.slice(-2000)); process.exit(2) }
const cand = JSON.parse(markerLine.slice('LEXDUMP:'.length))

// Key-order-INSENSITIVE deep equality — Godot's JSON.stringify sorts dict keys alphabetically,
// so a raw string compare would false-positive on order alone. (The graph gate needs this too.)
function eq(a, b) {
    if (a === b) return true
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
let pass = 0, fail = 0
const failed = []
for (const f of files) {
    const o = oracle[f], c = cand[f]
    if (eq(o, c)) { pass++; continue }
    fail++
    let where = `length ref=${o ? o.length : 'missing'} mine=${c ? c.length : 'missing'}`
    const m = Math.max(o ? o.length : 0, c ? c.length : 0)
    for (let k = 0; k < m; k++) {
        if (!eq(o && o[k], c && c[k])) {
            where = `tok#${k} ref=${JSON.stringify(o && o[k])} mine=${JSON.stringify(c && c[k])}`
            break
        }
    }
    failed.push(`${f.replace(REPO + '/', '')}: ${where}`)
}
console.log(`LEX PARITY: ${pass}/${files.length} pass`)
for (const x of failed.slice(0, 25)) console.log('  DIFF ' + x)
process.exit(fail === 0 ? 0 : 1)
