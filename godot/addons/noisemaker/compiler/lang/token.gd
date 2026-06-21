# token.gd — DSL token kinds + the token record. Port of TD compiler/lang/token.py
# (1:1 with hlsl Token.cs). reference/01 §1.1: every token is {type, lexeme, line, col}.
#   - type   : the token kind (the constants below; uppercase strings exactly as the reference
#              lexer emits, reference/01 §1.4 — kept as strings so a dumped token stream diffs
#              directly against the reference's JSON).
#   - lexeme : the matched source substring; for STRING/FUNC it is the *content* without
#              delimiters / arrow head (the lexer strips those).
#   - line   : 1-based line at token start.
#   - col    : 1-based column at token start (per-code-unit; tabs = 1).
#
# The TokenType constants are bundled onto this class (GDScript = one class per file): consumers
# `const Token = preload(".../token.gd")` then use `Token.NUMBER` and `Token.new(...)`.
extends RefCounted

# --- token kinds -------------------------------------------------------------
# literals / identifiers
const NUMBER := "NUMBER"
const STRING := "STRING"
const HEX := "HEX"
const FUNC := "FUNC"
const IDENT := "IDENT"
# surface refs
const OUTPUT_REF := "OUTPUT_REF"
const SOURCE_REF := "SOURCE_REF"
const VOL_REF := "VOL_REF"
const GEO_REF := "GEO_REF"
const XYZ_REF := "XYZ_REF"
const VEL_REF := "VEL_REF"
const RGBA_REF := "RGBA_REF"
const MESH_REF := "MESH_REF"
# punctuation
const DOT := "DOT"
const LPAREN := "LPAREN"
const RPAREN := "RPAREN"
const LBRACE := "LBRACE"
const RBRACE := "RBRACE"
const LBRACKET := "LBRACKET"
const RBRACKET := "RBRACKET"
const COMMA := "COMMA"
const COLON := "COLON"
const EQUAL := "EQUAL"
const SEMICOLON := "SEMICOLON"
const PLUS := "PLUS"
const MINUS := "MINUS"
const STAR := "STAR"
const SLASH := "SLASH"
# keywords (RESERVED_KEYWORDS — reference/01 §1.3)
const LET := "LET"
const RENDER := "RENDER"
const WRITE := "WRITE"
const WRITE3D := "WRITE3D"
const TRUE := "TRUE"
const FALSE := "FALSE"
const IF := "IF"
const ELIF := "ELIF"
const ELSE := "ELSE"
const BREAK := "BREAK"
const CONTINUE := "CONTINUE"
const RETURN := "RETURN"
const SEARCH := "SEARCH"
const SUBCHAIN := "SUBCHAIN"
# trivia / end
const COMMENT := "COMMENT"
const EOF := "EOF"

# --- the token record --------------------------------------------------------
var type: String
var lexeme: String
var line: int
var col: int

func _init(t: String, lx: String, ln: int, c: int) -> void:
	type = t
	lexeme = lx
	line = ln
	col = c

func _to_string() -> String:
	return "%s('%s' @%d:%d)" % [type, lexeme, line, col]

# Token stream as plain dicts (for the check_lex parity gate — diffs against reference JSON).
func to_dict() -> Dictionary:
	return {"type": type, "lexeme": lexeme, "line": line, "col": col}
