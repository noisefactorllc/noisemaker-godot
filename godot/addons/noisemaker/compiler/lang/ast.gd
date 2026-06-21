# ast.gd — DSL AST node kinds + shape helpers. Port of TD compiler/lang/ast.py
# (port of hlsl Ast.cs). The reference parser emits plain objects discriminated by a `type`
# string (reference/01 §6); the faithful GDScript equivalent is plain **Dictionaries** with
# exactly the reference field set, so a parsed tree diffs directly against reference parse().
#
# The constants below hold the `type` strings (matching the reference). Helpers build the
# recurring shapes; the parser builds the rest inline. PARITY notes (reference/01 §6):
#   - Number.value is a double carrying the parse-time constant fold (§4.4).
#   - Color.value is a 4-double array in 0..1 (§5); no colorspace in the front-end.
#   - String.value is RAW (escapes not decoded; §1.4 rules 15/16).
#   - the chain-statement wrapper has NO `type` — identified by the `chain` key (§6.2).
#   - Member.path has >= 2 segments; a single segment is an Ident (§4.5).
extends RefCounted

const Program := "Program"
const VarAssign := "VarAssign"
const IfStmt := "IfStmt"
const Break := "Break"
const Continue := "Continue"
const Return := "Return"
const Call := "Call"
const Write := "Write"
const Write3D := "Write3D"
const Subchain := "Subchain"
const Read := "Read"
const Read3D := "Read3D"
const Number := "Number"
const String_ := "String"  # `String` is a built-in type name; node kind string is still "String"
const Boolean := "Boolean"
const Color_ := "Color"  # `Color` is a builtin type name; node kind string is still "Color"
const ArrayLiteral := "ArrayLiteral"
const Func := "Func"
const Ident := "Ident"
const Member := "Member"
const Chain := "Chain"
const OutputRef := "OutputRef"
const SourceRef := "SourceRef"
const VolRef := "VolRef"
const GeoRef := "GeoRef"
const XyzRef := "XyzRef"
const VelRef := "VelRef"
const RgbaRef := "RgbaRef"
const MeshRef := "MeshRef"
const Oscillator := "Oscillator"
const Midi := "Midi"
const Audio := "Audio"

# {type:'Number', value:double} — the parse-time constant-folded literal.
static func number(value) -> Dictionary:
	return {"type": Number, "value": value}

# A 2-segment Member, used for special-form defaults (oscKind.sine, midiMode.velocity).
static func member_of(a, b) -> Dictionary:
	return {"type": Member, "path": [a, b]}

# The {line,col} source location the reference attaches to Write/Subchain/etc.
static func loc(line: int, col: int) -> Dictionary:
	return {"line": line, "col": col}
