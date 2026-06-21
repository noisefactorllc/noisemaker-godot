# lexer.gd — DSL tokenizer. Port of the REFERENCE shaders/src/lang/lexer.js (reference/01 §1),
# cross-checked against noisemaker-hlsl Compiler/Lang/Lexer.cs. Sources: upstream noisemaker +
# noisemaker-hlsl ONLY.
#
# PARITY-CRITICAL (reference/01 §1.4): 1-based line/col; col counts code units; tabs=1; '\n'
# resets col=1/line++. Rule order is load-bearing: comments, o/s refs, vol BEFORE vel (3rd char
# disambiguates), geo, xyz, rgba/mesh (4 prefix chars + digit), hex {3,6,8 digits} only, arrow
# FUNC, leading-dot number, single-char punctuation, triple-quote string, single/double string
# (escapes NOT decoded — raw inter-delimiter text), number, identifier/keyword, else error.
#
# GDScript adaptations: `j` is hoisted (GDScript may not block-scope a re-`var`'d name); lookahead
# goes through _at() (out-of-range String indexing ERRORS in GDScript, unlike JS `undefined`);
# errors push_error + return partials (no exceptions — the valid corpus never hits these paths,
# so full diagnostic-text parity is out of scope for graph-parity).
extends RefCounted

const Token = preload("res://addons/noisemaker/compiler/lang/token.gd")

# RESERVED_KEYWORDS (reference/01 §1.3 — lexer.js, frozen). keyword text -> token-type string.
const KEYWORDS := {
	"let": "LET", "render": "RENDER", "write": "WRITE", "write3d": "WRITE3D",
	"true": "TRUE", "false": "FALSE", "if": "IF", "elif": "ELIF", "else": "ELSE",
	"break": "BREAK", "continue": "CONTINUE", "return": "RETURN",
	"search": "SEARCH", "subchain": "SUBCHAIN",
}

# single-char punctuation char -> token-type string (reference lexer's punctuation if-chain).
const _SINGLE := {
	".": "DOT", "(": "LPAREN", ")": "RPAREN", "{": "LBRACE", "}": "RBRACE",
	"[": "LBRACKET", "]": "RBRACKET", ",": "COMMA", ":": "COLON", "=": "EQUAL",
	";": "SEMICOLON", "+": "PLUS", "-": "MINUS", "*": "STAR", "/": "SLASH",
}

const _NUL := ""  # out-of-range sentinel (JS reads undefined; "" never matches a real char test)

static func _is_digit(c: String) -> bool:
	return c >= "0" and c <= "9"

static func _is_letter(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")

static func _is_hex(c: String) -> bool:
	return (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")

static func _at(s: String, k: int, n: int) -> String:
	return s[k] if (k >= 0 and k < n) else _NUL

# Tokenize `src` into an Array of Token, ending in one EOF token (reference/01 §1).
static func lex(src) -> Array:
	var tokens: Array = []
	if src == null:
		src = ""
	var s: String = src
	var n := s.length()
	var i := 0
	var line := 1
	var col := 1

	while i < n:
		var ch := s[i]

		if ch == " " or ch == "\t" or ch == "\r":
			i += 1; col += 1; continue
		if ch == "\n":
			i += 1; line += 1; col = 1; continue

		var start_line := line
		var start_col := col
		var j := 0

		# line comment //...
		if ch == "/" and _at(s, i + 1, n) == "/":
			j = i + 2
			while j < n and s[j] != "\n":
				j += 1
			tokens.append(Token.new("COMMENT", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# block comment /* ... */
		if ch == "/" and _at(s, i + 1, n) == "*":
			j = i + 2
			var end_line := line
			var end_col := col + 2
			while j < n and not (s[j] == "*" and _at(s, j + 1, n) == "/"):
				if s[j] == "\n":
					end_line += 1; end_col = 1
				else:
					end_col += 1
				j += 1
			if j >= n:
				push_error("Unterminated comment at line %d col %d" % [start_line, start_col]); return tokens
			j += 2
			tokens.append(Token.new("COMMENT", s.substr(i, j - i), start_line, start_col))
			line = end_line; col = end_col + 2; i = j; continue

		# output or source reference (o/s + digit)
		if (ch == "o" or ch == "s") and _is_digit(_at(s, i + 1, n)):
			j = i + 1
			while j < n and _is_digit(s[j]):
				j += 1
			var tt := "OUTPUT_REF" if ch == "o" else "SOURCE_REF"
			tokens.append(Token.new(tt, s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# vol reference (vol + digit) — tested BEFORE vel
		if ch == "v" and _at(s, i + 1, n) == "o" and _at(s, i + 2, n) == "l" and _is_digit(_at(s, i + 3, n)):
			j = i + 3
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("VOL_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# geo reference (geo + digit)
		if ch == "g" and _at(s, i + 1, n) == "e" and _at(s, i + 2, n) == "o" and _is_digit(_at(s, i + 3, n)):
			j = i + 3
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("GEO_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# xyz reference (xyz + digit)
		if ch == "x" and _at(s, i + 1, n) == "y" and _at(s, i + 2, n) == "z" and _is_digit(_at(s, i + 3, n)):
			j = i + 3
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("XYZ_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# vel reference (vel + digit) — v disambiguated from vol by 3rd char
		if ch == "v" and _at(s, i + 1, n) == "e" and _at(s, i + 2, n) == "l" and _is_digit(_at(s, i + 3, n)):
			j = i + 3
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("VEL_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# rgba reference (rgba + digit)
		if ch == "r" and _at(s, i + 1, n) == "g" and _at(s, i + 2, n) == "b" and _at(s, i + 3, n) == "a" and _is_digit(_at(s, i + 4, n)):
			j = i + 4
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("RGBA_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# mesh reference (mesh + digit)
		if ch == "m" and _at(s, i + 1, n) == "e" and _at(s, i + 2, n) == "s" and _at(s, i + 3, n) == "h" and _is_digit(_at(s, i + 4, n)):
			j = i + 4
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("MESH_REF", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# hex color literal (#) — only emit for total length 4/7/9
		if ch == "#":
			j = i + 1
			while j < n and _is_hex(s[j]):
				j += 1
			var hex_len := j - i
			if hex_len == 4 or hex_len == 7 or hex_len == 9:
				tokens.append(Token.new("HEX", s.substr(i, hex_len), start_line, start_col))
				col += hex_len; i = j; continue
			# else fall through ('#' matches no later rule -> final error)

		# arrow function () => expr
		if ch == "(" and _at(s, i + 1, n) == ")":
			j = i + 2
			while j < n and (s[j] == " " or s[j] == "\t"):
				j += 1
			if _at(s, j, n) == "=" and _at(s, j + 1, n) == ">":
				j += 2
				while j < n and (s[j] == " " or s[j] == "\t"):
					j += 1
				var depth := 0
				var expr_start := j
				while j < n:
					var c := s[j]
					if c == "(":
						depth += 1
					elif c == ")":
						if depth == 0:
							break
						depth -= 1
					elif depth == 0:
						if c == "," or c == ";" or c == "\n" or c == "}":
							break
					j += 1
				var expr := s.substr(expr_start, j - expr_start).strip_edges()
				tokens.append(Token.new("FUNC", expr, start_line, start_col))
				col += j - i; i = j; continue
			# else fall through: '(' handled by single-char punctuation below

		# leading-dot number .D
		if ch == "." and _is_digit(_at(s, i + 1, n)):
			j = i + 1
			while j < n and _is_digit(s[j]):
				j += 1
			tokens.append(Token.new("NUMBER", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# single-char punctuation
		var punct: String = _SINGLE.get(ch, "")
		if punct != "":
			tokens.append(Token.new(punct, ch, start_line, start_col))
			i += 1; col += 1; continue

		# triple-quoted string """ ... """ (checked before single quotes)
		if ch == '"' and _at(s, i + 1, n) == '"' and _at(s, i + 2, n) == '"':
			j = i + 3
			while j < n - 2:
				if s[j] == '"' and s[j + 1] == '"' and s[j + 2] == '"':
					break
				if s[j] == "\n":
					line += 1; col = 0
				j += 1
			if j >= n - 2 or not (_at(s, j, n) == '"' and _at(s, j + 1, n) == '"' and _at(s, j + 2, n) == '"'):
				push_error("Unterminated triple-quoted string at line %d col %d" % [start_line, start_col]); return tokens
			var tri_content := s.substr(i + 3, j - (i + 3))
			tokens.append(Token.new("STRING", tri_content, start_line, start_col))
			var clines := tri_content.split("\n")
			if clines.size() > 1:
				col = clines[clines.size() - 1].length() + 4  # +3 closing """ +1 next char
			else:
				col += j - i + 3
			i = j + 3; continue

		# single/double quoted string (escapes consume 2 chars, NOT decoded)
		if ch == '"' or ch == "'":
			var quote := ch
			j = i + 1
			while j < n and s[j] != quote and s[j] != "\n":
				if s[j] == "\\" and j + 1 < n:
					j += 2
				else:
					j += 1
			if j >= n or s[j] == "\n":
				push_error("Unterminated string literal at line %d col %d" % [line, col]); return tokens
			var str_content := s.substr(i + 1, j - (i + 1))
			tokens.append(Token.new("STRING", str_content, start_line, start_col))
			col += j - i + 1; i = j + 1; continue

		# number D...
		if _is_digit(ch):
			j = i
			while j < n and _is_digit(s[j]):
				j += 1
			if _at(s, j, n) == "." and _is_digit(_at(s, j + 1, n)):
				j += 1
				while j < n and _is_digit(s[j]):
					j += 1
			tokens.append(Token.new("NUMBER", s.substr(i, j - i), start_line, start_col))
			col += j - i; i = j; continue

		# identifier / keyword
		if _is_letter(ch) or ch == "_":
			j = i
			while j < n and (_is_letter(s[j]) or _is_digit(s[j]) or s[j] == "_"):
				j += 1
			var lexeme := s.substr(i, j - i)
			var kw: String = KEYWORDS.get(lexeme, "")
			tokens.append(Token.new(kw if kw != "" else "IDENT", lexeme, start_line, start_col))
			col += j - i; i = j; continue

		# anything else
		push_error("Unexpected character '%s' at line %d col %d" % [ch, line, col]); return tokens

	tokens.append(Token.new("EOF", "", line, col))
	return tokens
