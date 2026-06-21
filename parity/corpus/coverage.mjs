#!/usr/bin/env node
// parity/corpus/coverage.mjs — corpus-driven coverage report.
//
// Compiles every fetched composition (parity/corpus/raw/<code>.json) through the
// AUTHORITATIVE reference compiler (tools/export-graph.mjs), then classifies each
// by whether all the shader programs its graph needs are already ported to Godot.
// Output is a prioritized worklist: which missing programs unblock the most real
// compositions, and which whole capabilities (points/render/3D) gate the corpus.
//
//   node parity/corpus/coverage.mjs
import { readFileSync, readdirSync, existsSync, writeFileSync, mkdtempSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const RAW = join(HERE, 'raw')
const SHADERS = join(ROOT, 'godot/addons/noisemaker/shaders/effects')
const EXPORT = join(ROOT, 'tools/export-graph.mjs')

// engine-builtin passes that need no per-effect shader port
const BUILTIN = new Set(['blit', 'copy', 'passthrough'])

// Shaders are func-qualified: effects/<ns>/<func>/<prog>.glsl (mirrors the reference layout).
const shaderExists = (ns, func, prog) => existsSync(join(SHADERS, ns, func, `${prog}.glsl`))

const files = readdirSync(RAW).filter(f => f.endsWith('.json')).sort()
const tmp = mkdtempSync(join(tmpdir(), 'nmcov-'))

const rows = []
const missFreq = new Map()  // "ns/prog" -> # of compositions needing it
const nsFreq = new Map()    // namespace -> # of (composition,missing-shader) hits

for (const f of files) {
  const comp = JSON.parse(readFileSync(join(RAW, f), 'utf8'))
  const dsl = comp.dsl || ''
  const dslPath = join(tmp, f.replace('.json', '.dsl'))
  const outPath = join(tmp, f.replace('.json', '.graph.json'))
  writeFileSync(dslPath, dsl)

  let graph = null, err = null
  try {
    execFileSync('node', [EXPORT, '--file', dslPath, outPath], { stdio: ['ignore', 'ignore', 'pipe'] })
    graph = JSON.parse(readFileSync(outPath, 'utf8'))
  } catch (e) {
    err = (e.stderr ? e.stderr.toString() : e.message).trim().split('\n').filter(Boolean).pop() || 'compile failed'
  }
  if (err) {
    rows.push({ code: comp.code, title: comp.title, status: 'COMPILE_FAIL', missing: [], detail: err })
    continue
  }

  const need = new Map()  // "ns/func/prog" -> {ns, func, prog}
  for (const p of graph.passes || []) {
    const prog = p.progName || p.program
    const ns = p.namespace || ''
    const func = p.func || ''
    if (!prog || BUILTIN.has(prog)) continue
    need.set(`${ns}/${func}/${prog}`, { ns, func, prog })
  }
  // Report leverage per EFFECT (ns/func) — that's the unit of porting; an effect counts as
  // missing for a composition if ANY of its programs is unported.
  const missingEffects = new Set()
  for (const { ns, func, prog } of need.values()) {
    if (!shaderExists(ns, func, prog)) missingEffects.add(`${ns}/${func}`)
  }
  const missing = [...missingEffects]
  const seenNs = new Set()
  for (const m of missing) {
    missFreq.set(m, (missFreq.get(m) || 0) + 1)
    const ns = m.split('/')[0]
    if (!seenNs.has(ns)) { nsFreq.set(ns, (nsFreq.get(ns) || 0) + 1); seenNs.add(ns) }
  }
  rows.push({
    code: comp.code, title: comp.title,
    status: missing.length ? 'BLOCKED' : 'RENDERABLE',
    missing, detail: missing.length ? `${missing.length} missing` : `${need.size} programs`,
  })
}

// ---- report ----
const tally = s => rows.filter(r => r.status === s).length
const pad = (s, n) => String(s).slice(0, n).padEnd(n)

console.log('\n=== CORPUS COVERAGE (NoiseBLASTER!) ===')
console.log(`${rows.length} compositions  |  RENDERABLE ${tally('RENDERABLE')}  BLOCKED ${tally('BLOCKED')}  COMPILE_FAIL ${tally('COMPILE_FAIL')}\n`)

for (const r of rows.sort((a, b) => (a.missing.length - b.missing.length) || a.status.localeCompare(b.status))) {
  const mark = r.status === 'RENDERABLE' ? '  OK ' : r.status === 'BLOCKED' ? 'MISS ' : 'FAIL '
  console.log(`${mark} ${pad(r.title, 26)} ${pad(r.code, 7)} ${r.status === 'COMPILE_FAIL' ? r.detail : r.detail}`)
  if (r.missing.length) console.log(`      └─ ${r.missing.join(', ')}`)
}

console.log('\n=== MISSING-PROGRAM LEVERAGE (unblocks N compositions) ===')
for (const [k, v] of [...missFreq.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(`  ${String(v).padStart(2)}×  ${k}`)
}

console.log('\n=== BLOCKING NAMESPACE/CAPABILITY (compositions touched) ===')
for (const [k, v] of [...nsFreq.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(`  ${String(v).padStart(2)}×  ${k}`)
}
console.log()
