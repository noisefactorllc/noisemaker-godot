// dump-graph.mjs — ORACLE for the graph parity gate. Registers effects from the SAME JSONs the
// candidate loads (mirroring tools/export-graph.mjs, incl. the defineMap), then dumps the REFERENCE
// normalizeGraph(compileGraph(dsl), defineMap) — the backend-consumed render graph — as JSON
// { absPath: {ok, out} } per DSL.
//
//   NM_REFERENCE_ROOT=/path/to/noisemaker node tools/dump-graph.mjs <effectsDir> <file...>
import { resolve, join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readFileSync, readdirSync } from 'node:fs'

if (!process.env.NM_REFERENCE_ROOT) { console.error('NM_REFERENCE_ROOT is not set'); process.exit(3) }
const HERE = dirname(fileURLToPath(import.meta.url))
const REF = resolve(process.env.NM_REFERENCE_ROOT)
const idx = await import(resolve(REF, 'shaders/src/index.js'))
const { compileGraph, registerEffect, registerOp, registerStarterOps, mergeIntoEnums, stdEnums, sanitizeEnumName } = idx
// normalizeGraph (reference-graph -> backend schema) is defined in this repo's export-graph.mjs.
const { normalizeGraph } = await import(join(HERE, 'export-graph.mjs'))

if (mergeIntoEnums && stdEnums) await mergeIntoEnums(stdEnums)
if (registerStarterOps) registerStarterOps()

const SENT = ['inputTex', 'inputTex3d', 'src', 'o0', 'o1']
const isStarterDef = (inst) => !((inst.passes || []).some(p => p.inputs && Object.values(p.inputs).some(v => SENT.includes(v))))

const effectsDir = resolve(process.argv[2])
const files = process.argv.slice(3)

const rels = []
for (const ns of readdirSync(effectsDir, { withFileTypes: true })) {
    if (!ns.isDirectory()) continue
    for (const f of readdirSync(join(effectsDir, ns.name))) if (f.endsWith('.json')) rels.push(`${ns.name}/${f}`)
}
rels.sort()
const allChoices = {}
const defineMap = {}
for (const rel of rels) {
    const inst = JSON.parse(readFileSync(join(effectsDir, rel), 'utf8'))
    const namespace = inst.namespace, func = inst.func
    registerEffect(inst.func, inst)
    registerEffect(`${namespace}.${func}`, inst)
    registerEffect(`${namespace}/${func}`, inst)
    registerEffect(`${namespace}.${func}`, inst)
    const args = Object.entries(inst.globals || {}).map(([key, spec]) => {
        let enumPath = spec.enum || spec.enumPath
        if (spec.choices && !enumPath) {
            enumPath = `${namespace}.${func}.${key}`
            allChoices[namespace] = allChoices[namespace] || {}
            allChoices[namespace][func] = allChoices[namespace][func] || {}
            allChoices[namespace][func][key] = allChoices[namespace][func][key] || {}
            for (const [n, v] of Object.entries(spec.choices)) {
                if (n.endsWith(':')) continue
                allChoices[namespace][func][key][n] = { type: 'Number', value: v }
                const s = sanitizeEnumName ? sanitizeEnumName(n) : n; if (s && s !== n) allChoices[namespace][func][key][s] = { type: 'Number', value: v }
            }
        }
        return { name: key, type: spec.type === 'vec4' ? 'color' : spec.type, default: spec.default, enum: enumPath, enumPath, min: spec.min, max: spec.max, uniform: spec.uniform, choices: spec.choices }
    })
    registerOp(`${namespace}.${func}`, { name: func, args })
    if (isStarterDef(inst)) registerStarterOps([`${namespace}.${func}`])
    const defs = {}
    for (const [key, spec] of Object.entries(inst.globals || {})) if (spec && spec.define) defs[key] = spec.define
    if (Object.keys(defs).length) defineMap[`${namespace}.${func}`] = defs
}
if (Object.keys(allChoices).length) await mergeIntoEnums(allChoices)

const out = {}
for (const f of files) {
    try {
        out[f] = { ok: true, out: normalizeGraph(compileGraph(readFileSync(f, 'utf8')), defineMap) }
    } catch (e) {
        out[f] = { ok: false, error: String(e && e.message || e) }
    }
}
process.stdout.write(JSON.stringify(out))
