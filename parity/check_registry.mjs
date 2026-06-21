// check_registry.mjs — EFFECTREGISTRY parity gate. Compares the GDScript registry (candidate, via
// _registry_dump.gd) against the reference registration logic (oracle, via dump-registry.mjs), both
// fed the SAME effect JSONs under godot/addons/noisemaker/effects. Deep value-compare per surface
// (ops / enums / paramAliases / effectAliases / effectKeys); report PASS or the first divergence.
//
//   NM_REFERENCE_ROOT=/path/to/noisemaker GODOT=/path/to/Godot node parity/check_registry.mjs
//
// One node launch (oracle) + one Godot launch (candidate). The reference is the only authority.
import { resolve, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')
const GODOT = process.env.GODOT || '/Applications/Godot.app/Contents/MacOS/Godot'
const EFFECTS_DIR = join(REPO, 'godot', 'addons', 'noisemaker', 'effects')

if (!process.env.NM_REFERENCE_ROOT) { console.error('NM_REFERENCE_ROOT is not set'); process.exit(3) }

const oracle = JSON.parse(execFileSync('node', [join(REPO, 'tools', 'dump-registry.mjs'), EFFECTS_DIR],
    { encoding: 'utf8', maxBuffer: 1 << 28 }))

const candRaw = execFileSync(GODOT, ['--headless', '--path', join(REPO, 'godot'),
    '--script', 'res://addons/noisemaker/compiler/_registry_dump.gd'],
    { encoding: 'utf8', maxBuffer: 1 << 28 })
const markerLine = candRaw.split('\n').find(l => l.startsWith('REGDUMP:'))
if (!markerLine) { console.error('no REGDUMP output from candidate. tail:\n' + candRaw.slice(-2000)); process.exit(2) }
const cand = JSON.parse(markerLine.slice('REGDUMP:'.length))

// Key-order-INSENSITIVE deep equality (Godot's JSON.stringify sorts dict keys; arrays stay ordered).
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

// First differing path (for diagnostics).
function firstDiff(a, b, path) {
    if (eq(a, b)) return null
    const ta = a === null ? 'null' : Array.isArray(a) ? 'array' : typeof a
    const tb = b === null ? 'null' : Array.isArray(b) ? 'array' : typeof b
    if (ta !== tb || ta !== 'object' && ta !== 'array') {
        return `${path}: ref=${JSON.stringify(a)} mine=${JSON.stringify(b)}`
    }
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

const sections = ['ops', 'enums', 'paramAliases', 'effectAliases', 'effectKeys']
let allPass = true
console.log('REGISTRY PARITY:')
for (const s of sections) {
    const ok = eq(oracle[s], cand[s])
    const refN = oracle[s] ? Object.keys(oracle[s]).length : 0
    const myN = cand[s] ? Object.keys(cand[s]).length : 0
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${s.padEnd(14)} (ref ${refN} / mine ${myN} keys)`)
    if (!ok) { allPass = false; console.log('        DIFF ' + firstDiff(oracle[s], cand[s], s)) }
}
process.exit(allPass ? 0 : 1)
