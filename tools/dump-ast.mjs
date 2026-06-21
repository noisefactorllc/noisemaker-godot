// dump-ast.mjs — ORACLE for the parser parity gate. Dumps the REFERENCE parser's Program AST
// (parse(lex(src))) as JSON { absPath: ast } for the given DSL files.
//
// Reference-based: imports the upstream lexer + parser via NM_REFERENCE_ROOT (this repo is a PORT;
// the reference stays external). The GDScript candidate (_parse_dump.gd) emits the same AST shape.
import { resolve } from 'node:path'
import { readFileSync } from 'node:fs'

if (!process.env.NM_REFERENCE_ROOT) {
    console.error('NM_REFERENCE_ROOT is not set (point it at a noisemaker reference checkout).')
    process.exit(3)
}
const REF = resolve(process.env.NM_REFERENCE_ROOT)
const { lex } = await import(resolve(REF, 'shaders/src/lang/lexer.js'))
const { parse } = await import(resolve(REF, 'shaders/src/lang/parser.js'))

const files = process.argv.slice(2)
const out = {}
for (const f of files) {
    try {
        out[f] = { ok: true, ast: parse(lex(readFileSync(f, 'utf8'))) }
    } catch (e) {
        // Syntax error — record it so the candidate can be checked for the same (valid corpus
        // should never land here).
        out[f] = { ok: false, error: String(e && e.message || e) }
    }
}
process.stdout.write(JSON.stringify(out))
