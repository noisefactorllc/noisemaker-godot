// dump-tokens.mjs — ORACLE for the lexer parity gate. Dumps the REFERENCE lexer's token stream
// (shaders/src/lang/lexer.js) as JSON { absPath: [tokens] } for the given DSL files.
//
// Reference-based: imports the upstream noisemaker lexer via NM_REFERENCE_ROOT (no sibling/TD
// assumption — this repo is a PORT, the reference stays external). The token shape is exactly the
// reference's {type, lexeme, line, col}; the GDScript candidate (_lex_dump.gd) emits the same.
import { resolve } from 'node:path'
import { readFileSync } from 'node:fs'

if (!process.env.NM_REFERENCE_ROOT) {
    console.error('NM_REFERENCE_ROOT is not set (point it at a noisemaker reference checkout).')
    process.exit(3)
}
const REFERENCE_ROOT = resolve(process.env.NM_REFERENCE_ROOT)
const { lex } = await import(resolve(REFERENCE_ROOT, 'shaders/src/lang/lexer.js'))

const files = process.argv.slice(2)
const out = {}
for (const f of files) {
    out[f] = lex(readFileSync(f, 'utf8'))
}
process.stdout.write(JSON.stringify(out))
