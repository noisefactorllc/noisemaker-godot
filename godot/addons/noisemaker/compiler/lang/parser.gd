# parser.gd — recursive-descent parser for the Polymorphic DSL. Port of the REFERENCE
# shaders/src/lang/parser.js (cross-checked vs noisemaker-hlsl Parser.cs). Sources: upstream
# noisemaker + noisemaker-hlsl ONLY.
#
# Consumes the lexer's token stream (Token instances) and returns the Program AST as nested
# Dictionaries (heterogeneous, JSON-diffable). Constant arithmetic is folded at parse time; osc /
# midi / audio / from / read / read3d calls are transformed into dedicated nodes.
#
# GDScript adaptations vs the JS:
#   - No exceptions. The reference throws SyntaxError to abort; here _fail() push_errors and sets the
#     _err flag, and the recursive functions short-circuit on it. The VALID corpus never hits an
#     error path (those are syntax errors), so the AST is only ever produced for well-formed input —
#     error-text parity is out of scope for graph-parity, exactly as for the lexer.
#   - Token lookahead goes through _type_at()/_tok() (out-of-range Array indexing ERRORS in GDScript,
#     unlike JS `undefined`); _peek() clamps to the trailing EOF token.
#   - `?.` -> .get()/guards; object spreads -> Dictionary.duplicate(); structuredClone -> duplicate(true).
#   - Number values are GDScript floats; the parity gate re-parses both sides' JSON into JS numbers,
#     so 5 and 5.0 compare equal (only true precision differences would surface).
extends RefCounted

const Token := preload("res://addons/noisemaker/compiler/lang/token.gd")
const Tags := preload("res://addons/noisemaker/compiler/lang/tags.gd")

# Token types that can begin an expression (reference exprStartTokens).
const EXPR_START := [
	"PLUS", "MINUS", "NUMBER", "HEX", "FUNC", "STRING",
	"IDENT", "OUTPUT_REF", "SOURCE_REF", "VOL_REF", "GEO_REF", "MESH_REF",
	"XYZ_REF", "VEL_REF", "RGBA_REF", "LPAREN", "LBRACKET",
	"TRUE", "FALSE",
]

# Token types allowed as segments inside a dotted member/enum path (reference memberTokenTypes).
const MEMBER_TOKENS := [
	"IDENT", "SOURCE_REF", "OUTPUT_REF", "VOL_REF", "GEO_REF", "MESH_REF",
	"XYZ_REF", "VEL_REF", "RGBA_REF",
	"LET", "RENDER", "TRUE", "FALSE", "IF", "ELIF", "ELSE",
	"BREAK", "CONTINUE", "RETURN", "WRITE", "WRITE3D", "SUBCHAIN",
]

# Token types usable as a namespace identifier in a search directive (reference namespaceTokenTypes).
const NAMESPACE_TOKENS := [
	"IDENT", "RENDER", "WRITE", "WRITE3D", "TRUE", "FALSE",
	"IF", "ELIF", "ELSE", "BREAK", "CONTINUE", "RETURN",
]

var tokens: Array
var current: int
var _err: bool
var programSearchOrder            # null until a search directive is parsed
var programNamespace: Dictionary  # {imports:[], default:null}

# ---------------------------------------------------------------- entry

func parse_tokens(toks: Array) -> Dictionary:
	tokens = toks
	current = 0
	_err = false
	programSearchOrder = null
	programNamespace = {"imports": [], "default": null}
	return _parse_program()

# ---------------------------------------------------------------- token cursor

func _peek():
	return tokens[current] if current < tokens.size() else tokens[tokens.size() - 1]

func _advance():
	var t = tokens[current]
	current += 1
	return t

func _type_at(i: int) -> String:
	return tokens[i].type if (i >= 0 and i < tokens.size()) else ""

func _tok(i: int):
	return tokens[i] if (i >= 0 and i < tokens.size()) else null

func _expect(type: String, msg: String):
	var token = _peek()
	if token.type == type:
		return _advance()
	_fail("%s at line %d col %d" % [msg, token.line, token.col])
	return token

func _fail(msg: String) -> void:
	if not _err:
		push_error("ParseError: " + msg)
	_err = true

# Collect and consume any pending COMMENT tokens; returns their lexemes.
func _collect_comments() -> Array:
	var comments: Array = []
	while _peek().type == "COMMENT":
		comments.append(_advance().lexeme)
	return comments

# ---------------------------------------------------------------- value-call transforms

# osc(type, min?, max?, speed?, offset?, seed?) -> Oscillator node.
func _transform_osc(call: Dictionary, name_token) -> Dictionary:
	var args: Array = call.get("args", []) if call.get("args") is Array else []
	var kwargs: Dictionary = call.get("kwargs", {})
	var param_order := ["type", "min", "max", "speed", "offset", "seed"]
	var valid_params := param_order
	var defaults := {
		"type": {"type": "Member", "path": ["oscKind", "sine"]},
		"min": {"type": "Number", "value": 0},
		"max": {"type": "Number", "value": 1},
		"speed": {"type": "Number", "value": 1},
		"offset": {"type": "Number", "value": 0},
		"seed": {"type": "Number", "value": 1},
	}
	for key in kwargs.keys():
		if not valid_params.has(key):
			_fail("osc() unknown parameter '%s' at line %d col %d. Valid: %s" % [key, name_token.line, name_token.col, ", ".join(param_order)])
	var resolved := {}
	for i in range(param_order.size()):
		var pname: String = param_order[i]
		if kwargs.has(pname):
			resolved[pname] = kwargs[pname]
		elif i < args.size():
			resolved[pname] = args[i]
		elif defaults.has(pname):
			resolved[pname] = defaults[pname]
	return {
		"type": "Oscillator",
		"oscType": resolved.get("type"),
		"min": resolved.get("min"),
		"max": resolved.get("max"),
		"speed": resolved.get("speed"),
		"offset": resolved.get("offset"),
		"seed": resolved.get("seed"),
		"loc": {"line": name_token.line, "col": name_token.col},
	}

# midi(channel, mode?, min?, max?, sensitivity?) -> Midi node.
func _transform_midi(call: Dictionary, name_token) -> Dictionary:
	var args: Array = call.get("args", []) if call.get("args") is Array else []
	var kwargs: Dictionary = call.get("kwargs", {})
	var param_order := ["channel", "mode", "min", "max", "sensitivity"]
	var defaults := {
		"mode": {"type": "Member", "path": ["midiMode", "velocity"]},
		"min": {"type": "Number", "value": 0},
		"max": {"type": "Number", "value": 1},
		"sensitivity": {"type": "Number", "value": 1},
	}
	var resolved := {}
	for i in range(param_order.size()):
		var pname: String = param_order[i]
		if kwargs.has(pname):
			resolved[pname] = kwargs[pname]
		elif i < args.size():
			resolved[pname] = args[i]
		elif defaults.has(pname):
			resolved[pname] = defaults[pname]
	if not resolved.has("channel") or resolved.get("channel") == null:
		_fail("midi() requires 'channel' argument at line %d col %d" % [name_token.line, name_token.col])
	return {
		"type": "Midi",
		"channel": resolved.get("channel"),
		"mode": resolved.get("mode"),
		"min": resolved.get("min"),
		"max": resolved.get("max"),
		"sensitivity": resolved.get("sensitivity"),
		"loc": {"line": name_token.line, "col": name_token.col},
	}

# audio(band, min?, max?) -> Audio node.
func _transform_audio(call: Dictionary, name_token) -> Dictionary:
	var args: Array = call.get("args", []) if call.get("args") is Array else []
	var kwargs: Dictionary = call.get("kwargs", {})
	var param_order := ["band", "min", "max"]
	var defaults := {
		"min": {"type": "Number", "value": 0},
		"max": {"type": "Number", "value": 1},
	}
	var resolved := {}
	for i in range(param_order.size()):
		var pname: String = param_order[i]
		if kwargs.has(pname):
			resolved[pname] = kwargs[pname]
		elif i < args.size():
			resolved[pname] = args[i]
		elif defaults.has(pname):
			resolved[pname] = defaults[pname]
	if not resolved.has("band") or resolved.get("band") == null:
		_fail("audio() requires 'band' argument at line %d col %d" % [name_token.line, name_token.col])
	return {
		"type": "Audio",
		"band": resolved.get("band"),
		"min": resolved.get("min"),
		"max": resolved.get("max"),
		"loc": {"line": name_token.line, "col": name_token.col},
	}

# from(namespace, call) -> the inner call with a namespace override.
func _transform_from(call: Dictionary, name_token):
	var kwargs: Dictionary = call.get("kwargs", {})
	if not kwargs.is_empty():
		_fail("'from' does not support named arguments at line %d col %d" % [name_token.line, name_token.col])
		return call
	var args: Array = call.get("args", []) if call.get("args") is Array else []
	if args.size() != 2:
		_fail("'from' requires exactly two arguments (namespace, call) at line %d col %d" % [name_token.line, name_token.col])
		return call
	var namespace_arg = args[0]
	var target_arg = args[1]
	if namespace_arg == null or (namespace_arg.get("type") != "Ident" and namespace_arg.get("type") != "Member"):
		_fail("'from' namespace argument must be an identifier at line %d col %d" % [name_token.line, name_token.col])
		return call
	var namespace_name = ".".join(namespace_arg.get("path")) if namespace_arg.get("type") == "Member" else namespace_arg.get("name")
	if namespace_name == null or namespace_name == "":
		_fail("'from' namespace argument must be non-empty at line %d col %d" % [name_token.line, name_token.col])
		return call
	var target_call = null
	if target_arg != null and target_arg.get("type") == "Call":
		target_call = target_arg
	elif target_arg != null and target_arg.get("type") == "Chain" and target_arg.get("chain") is Array and target_arg.get("chain").size() == 1:
		var head = target_arg.get("chain")[0]
		if head != null and head.get("type") == "Call":
			target_call = head
	if target_call == null:
		_fail("'from' second argument must be a call expression at line %d col %d" % [name_token.line, name_token.col])
		return call
	var replacement: Dictionary = target_call.duplicate()
	replacement["args"] = (target_call.get("args").duplicate() if target_call.get("args") is Array else [])
	if target_call.has("kwargs"):
		replacement["kwargs"] = target_call.get("kwargs").duplicate()
	replacement["namespace"] = {
		"name": namespace_name,
		"path": [namespace_name],
		"explicit": true,
		"source": "from",
		"resolved": namespace_name,
		"searchOrder": [namespace_name],
		"fromOverride": true,
	}
	return replacement

# Lookahead: does a DOT-chain of member segments starting at `index` end at a call (LPAREN)?
func _has_call_after_dot(index: int) -> bool:
	var i := index + 1
	if _type_at(i) != "DOT":
		return false
	while _type_at(i) == "DOT":
		var seg = _tok(i + 1)
		if seg == null or not MEMBER_TOKENS.has(seg.type):
			return false
		i += 2
	return _type_at(i) == "LPAREN"

func _parse_render_directive() -> Dictionary:
	_advance()
	_expect("LPAREN", "Expect '('")
	if _peek().type != "OUTPUT_REF":
		_fail("Expected output reference in render()")
	var out := {"type": "OutputRef", "name": _advance().lexeme}
	_expect("RPAREN", "Expect ')'")
	return out

# ---------------------------------------------------------------- program

func _parse_program() -> Dictionary:
	var plans: Array = []
	var vars: Array = []
	var render = null
	var trailing_comments: Array = []

	while _peek().type != "EOF" and not _err:
		if _peek().type == "SEMICOLON":
			_advance(); continue
		var leading_comments := _collect_comments()
		if _peek().type == "EOF":
			if leading_comments.size() > 0:
				trailing_comments.append_array(leading_comments)
			break
		if _peek().type == "SEARCH":
			if plans.size() or vars.size() or render:
				var t = _peek()
				_fail("'search' directive must appear before other statements at line %d col %d" % [t.line, t.col])
			_parse_search_directive()
			continue
		if _peek().type == "RENDER":
			if render:
				var t = _peek()
				_fail("Duplicate render() directive at line %d col %d" % [t.line, t.col])
			render = _parse_render_directive()
			while _peek().type == "SEMICOLON":
				_advance()
			if leading_comments.size() > 0 and render:
				render["leadingComments"] = leading_comments
			var trailing := _collect_comments()
			if trailing.size() > 0:
				trailing_comments.append_array(trailing)
			break
		var stmt = _parse_statement()
		if leading_comments.size() > 0 and stmt:
			stmt["leadingComments"] = leading_comments
		if stmt != null and stmt is Dictionary:
			if stmt.get("type") == "VarAssign":
				vars.push_back(stmt)
			else:
				plans.push_back(stmt)
		while _peek().type == "SEMICOLON":
			_advance()

	_expect("EOF", "Expected end of input")
	if programSearchOrder == null or programSearchOrder.size() == 0:
		_fail("Missing required 'search' directive. Every program must start with 'search <namespace>, ...' to specify namespace search order.")

	var program := {"type": "Program", "plans": plans, "render": render}
	if vars.size():
		program["vars"] = vars
	if trailing_comments.size():
		program["trailingComments"] = trailing_comments

	var search_order: Array = programSearchOrder.duplicate() if programSearchOrder != null else []
	program["namespace"] = {
		"imports": programNamespace["imports"],
		"default": programNamespace["default"],
		"searchOrder": search_order,
	}.duplicate(true)
	return program

func _parse_search_directive() -> void:
	if programSearchOrder != null:
		var t = _peek()
		_fail("Only one search directive is allowed per program at line %d col %d" % [t.line, t.col])
	_advance()  # consume 'search'
	var namespaces: Array = []
	var first = _peek()
	if not NAMESPACE_TOKENS.has(first.type):
		_fail("Expected namespace identifier after search at line %d col %d" % [first.line, first.col])
	_advance()
	_validate_namespace(first)
	namespaces.push_back(first.lexeme)
	while _peek().type == "COMMA":
		_advance()
		var ns_token = _peek()
		if not NAMESPACE_TOKENS.has(ns_token.type):
			_fail("Expected namespace identifier after comma at line %d col %d" % [ns_token.line, ns_token.col])
		_advance()
		_validate_namespace(ns_token)
		namespaces.push_back(ns_token.lexeme)
	programSearchOrder = namespaces
	var imports: Array = []
	for nm in namespaces:
		imports.push_back({"name": nm, "source": "search", "explicit": true})
	programNamespace["imports"] = imports
	programNamespace["default"] = {"name": namespaces[0], "source": "search", "explicit": true}
	while _peek().type == "SEMICOLON":
		_advance()

func _validate_namespace(token) -> void:
	var ns: String = token.lexeme
	if not Tags.is_valid_namespace(ns):
		_fail("Invalid namespace '%s' at line %d col %d. Valid namespaces: %s" % [ns, token.line, token.col, ", ".join(Tags.VALID_NAMESPACES)])

func _parse_block() -> Array:
	_expect("LBRACE", "Expect '{'")
	var body: Array = []
	while _peek().type != "RBRACE" and not _err:
		var stmt = _parse_statement()
		body.push_back(stmt)
		while _peek().type == "SEMICOLON":
			_advance()
	_expect("RBRACE", "Expect '}'")
	return body

func _parse_statement():
	if _err:
		return null
	if _peek().type == "SEARCH":
		var t = _peek()
		_fail("'search' directive is only allowed at the start of the program at line %d col %d" % [t.line, t.col])
		return null
	if _peek().type == "LET":
		_advance()
		var name = _expect("IDENT", "Expected identifier").lexeme
		_expect("EQUAL", "Expect '='")
		if not EXPR_START.has(_peek().type):
			var t = _peek()
			_fail("Expected expression after '=' at line %d col %d" % [t.line, t.col])
		var expr = _parse_additive()
		return {"type": "VarAssign", "name": name, "expr": expr}

	match _peek().type:
		"IF":
			_advance()
			_expect("LPAREN", "Expect '('")
			var condition = _parse_additive()
			_expect("RPAREN", "Expect ')'")
			var then_block = _parse_block()
			var elif_list: Array = []
			while _peek().type == "ELIF":
				_advance()
				_expect("LPAREN", "Expect '('")
				var ec = _parse_additive()
				_expect("RPAREN", "Expect ')'")
				var body = _parse_block()
				elif_list.push_back({"condition": ec, "then": body})
			var else_branch = null
			if _peek().type == "ELSE":
				_advance()
				else_branch = _parse_block()
			return {"type": "IfStmt", "condition": condition, "then": then_block, "elif": elif_list, "else": else_branch}
		"BREAK":
			_advance()
			return {"type": "Break"}
		"CONTINUE":
			_advance()
			return {"type": "Continue"}
		"RETURN":
			_advance()
			if EXPR_START.has(_peek().type):
				var value = _parse_additive()
				return {"type": "Return", "value": value}
			return {"type": "Return"}

	var chain = _parse_chain()
	var write = null
	var write3d = null
	if chain.size() > 0:
		var last_node = chain[chain.size() - 1]
		if last_node.get("type") == "Write":
			write = last_node.get("surface")
		elif last_node.get("type") == "Write3D":
			write3d = {"tex3d": last_node.get("tex3d"), "geo": last_node.get("geo")}
	return {"chain": chain, "write": write, "write3d": write3d}

func _parse_chain(context: String = "statement") -> Array:
	var first_call = _parse_call()
	var calls: Array = [first_call]
	while not _err:
		var saved_pos := current
		var leading_comments := _collect_comments()
		if _peek().type != "DOT":
			current = saved_pos
			break
		_advance()  # consume '.'
		var post_dot_comments := _collect_comments()
		var all_comments: Array = []
		all_comments.append_array(leading_comments)
		all_comments.append_array(post_dot_comments)

		var next_type: String = _peek().type
		if next_type == "WRITE" or next_type == "WRITE3D":
			if context == "expression":
				var t = _peek()
				_fail("'.write()' is only allowed in statement context at line %d col %d" % [t.line, t.col])
			var write_node = _parse_write_call()
			if all_comments.size() > 0:
				write_node["leadingComments"] = all_comments
			calls.push_back(write_node)
			continue
		if next_type == "SUBCHAIN":
			var subchain_node = _parse_subchain_call()
			if all_comments.size() > 0:
				subchain_node["leadingComments"] = all_comments
			calls.push_back(subchain_node)
			continue
		var call = _parse_call()
		if all_comments.size() > 0:
			call["leadingComments"] = all_comments
		calls.push_back(call)
	return calls

func _parse_write_call() -> Dictionary:
	var token_type: String = _peek().type
	var token_line: int = _peek().line
	var token_col: int = _peek().col

	if token_type == "WRITE":
		_advance()  # consume 'write'
		_expect("LPAREN", "Expect '('")
		var surface = null
		var pt: String = _peek().type
		if pt == "OUTPUT_REF":
			surface = {"type": "OutputRef", "name": _advance().lexeme}
		elif pt == "XYZ_REF":
			surface = {"type": "XyzRef", "name": _advance().lexeme}
		elif pt == "VEL_REF":
			surface = {"type": "VelRef", "name": _advance().lexeme}
		elif pt == "RGBA_REF":
			surface = {"type": "RgbaRef", "name": _advance().lexeme}
		elif pt == "MESH_REF":
			surface = {"type": "MeshRef", "name": _advance().lexeme}
		elif pt == "IDENT" and _peek().lexeme == "none":
			surface = {"type": "OutputRef", "name": _advance().lexeme}
		else:
			_fail("write() requires an explicit surface reference (e.g., o0, o1, xyz0, vel0, rgba0, mesh0, none) at line %d col %d" % [_peek().line, _peek().col])
		_expect("RPAREN", "Expect ')'")
		return {"type": "Write", "surface": surface, "loc": {"line": token_line, "col": token_col}}
	elif token_type == "WRITE3D":
		_advance()  # consume 'write3d'
		_expect("LPAREN", "Expect '('")
		var tex3d = null
		var pt: String = _peek().type
		if pt == "IDENT" or pt == "OUTPUT_REF" or pt == "VOL_REF":
			if pt == "OUTPUT_REF":
				tex3d = {"type": "OutputRef", "name": _advance().lexeme}
			elif pt == "VOL_REF":
				tex3d = {"type": "VolRef", "name": _advance().lexeme}
			else:
				tex3d = {"type": "Ident", "name": _advance().lexeme}
		else:
			_fail("Expected tex3d reference in write3d() at line %d col %d" % [_peek().line, _peek().col])
		_expect("COMMA", "Expect ',' between tex3d and geo in write3d()")
		var geo = null
		var pt2: String = _peek().type
		if pt2 == "IDENT" or pt2 == "OUTPUT_REF" or pt2 == "GEO_REF":
			if pt2 == "OUTPUT_REF":
				geo = {"type": "OutputRef", "name": _advance().lexeme}
			elif pt2 == "GEO_REF":
				geo = {"type": "GeoRef", "name": _advance().lexeme}
			else:
				geo = {"type": "Ident", "name": _advance().lexeme}
		else:
			_fail("Expected geo reference in write3d() at line %d col %d" % [_peek().line, _peek().col])
		_expect("RPAREN", "Expect ')'")
		return {"type": "Write3D", "tex3d": tex3d, "geo": geo, "loc": {"line": token_line, "col": token_col}}
	_fail("Expected write or write3d at line %d col %d" % [token_line, token_col])
	return {}

# subchain(name?, id?) { .effect1() .effect2() } -> Subchain node.
func _parse_subchain_call() -> Dictionary:
	var token_line: int = _peek().line
	var token_col: int = _peek().col
	_advance()  # consume 'subchain'
	_expect("LPAREN", "Expect '(' after subchain")
	var kwargs := {}
	if _peek().type != "RPAREN":
		if _peek().type == "STRING":
			kwargs["name"] = {"type": "String", "value": _advance().lexeme}
		elif _peek().type == "IDENT" and _type_at(current + 1) == "COLON":
			while _peek().type == "IDENT" and _type_at(current + 1) == "COLON" and not _err:
				var key = _advance().lexeme
				_advance()  # consume ':'
				if _peek().type != "STRING":
					_fail("Expected string value for subchain %s at line %d col %d" % [key, _peek().line, _peek().col])
					break
				kwargs[key] = {"type": "String", "value": _advance().lexeme}
				if _peek().type == "COMMA":
					_advance()
	_expect("RPAREN", "Expect ')' after subchain arguments")
	_expect("LBRACE", "Expect '{' to start subchain body")
	var body: Array = []
	while _peek().type != "RBRACE" and not _err:
		var leading_comments := _collect_comments()
		if _peek().type == "RBRACE":
			break
		if _peek().type != "DOT":
			_fail("Expected '.' before chain element in subchain body at line %d col %d" % [_peek().line, _peek().col])
			break
		_advance()  # consume '.'
		var post_dot_comments := _collect_comments()
		var all_comments: Array = []
		all_comments.append_array(leading_comments)
		all_comments.append_array(post_dot_comments)
		var call = _parse_call()
		if all_comments.size() > 0:
			call["leadingComments"] = all_comments
		body.push_back(call)
	_expect("RBRACE", "Expect '}' to end subchain body")
	if body.size() == 0:
		_fail("Subchain body cannot be empty at line %d col %d" % [token_line, token_col])
	return {
		"type": "Subchain",
		"name": (kwargs["name"]["value"] if kwargs.has("name") else null),
		"id": (kwargs["id"]["value"] if kwargs.has("id") else null),
		"body": body,
		"loc": {"line": token_line, "col": token_col},
	}

func _parse_call():
	var name_token = _expect("IDENT", "Expected identifier")
	# Inline namespace syntax (e.g., nd.noise()) is forbidden.
	if _peek().type == "DOT":
		var next = _tok(current + 1)
		if next != null and next.type == "IDENT":
			var after = _tok(current + 2)
			if after != null and after.type == "LPAREN":
				_fail("Inline namespace syntax '%s.%s()' is not allowed. Use 'search %s' at the start of the program instead, at line %d col %d" % [name_token.lexeme, next.lexeme, name_token.lexeme, name_token.line, name_token.col])
	_expect("LPAREN", "Expect '('")
	var args: Array = []
	var kwargs := {}
	var keyword := false
	if _peek().type != "RPAREN":
		if _peek().type == "IDENT" and _type_at(current + 1) == "COLON":
			keyword = true
			_parse_kwarg(kwargs)
			while _peek().type == "COMMA":
				_advance()
				if _peek().type == "RPAREN":
					break
				if not (_peek().type == "IDENT" and _type_at(current + 1) == "COLON"):
					var t = _peek()
					_fail("Cannot mix positional and keyword arguments at line %d col %d" % [t.line, t.col])
					break
				_parse_kwarg(kwargs)
		else:
			args.push_back(_parse_arg())
			while _peek().type == "COMMA":
				_advance()
				if _peek().type == "RPAREN":
					break
				if _peek().type == "IDENT" and _type_at(current + 1) == "COLON":
					var t = _peek()
					_fail("Cannot mix positional and keyword arguments at line %d col %d" % [t.line, t.col])
					break
				args.push_back(_parse_arg())
	_expect("RPAREN", "Expect ')'")
	var call := {"type": "Call", "name": name_token.lexeme, "args": args}
	if keyword:
		call["kwargs"] = kwargs

	var lexeme: String = name_token.lexeme
	if lexeme == "from":
		return _transform_from(call, name_token)
	if lexeme == "osc":
		var osc_kwargs := ["type", "min", "max", "speed", "offset", "seed"]
		var has_type_kwarg := kwargs.has("type")
		var first_arg_is_osckind = args.size() > 0 and args[0] != null and args[0].get("type") == "Member" and args[0].get("path") is Array and args[0].get("path").size() > 0 and args[0].get("path")[0] == "oscKind"
		var is_bare_osc := args.size() == 0 and kwargs.is_empty()
		var has_only_osc_kwargs := not kwargs.is_empty() and _all_keys_in(kwargs, osc_kwargs)
		if has_type_kwarg or first_arg_is_osckind or is_bare_osc or has_only_osc_kwargs:
			return _transform_osc(call, name_token)
		# else fall through: synth.osc generator effect
	if lexeme == "midi":
		return _transform_midi(call, name_token)
	if lexeme == "audio":
		return _transform_audio(call, name_token)
	if lexeme == "read":
		var surface = _arg(args, 0)
		if surface == null:
			surface = kwargs.get("tex")
		if surface == null:
			surface = kwargs.get("surface")
		var node := {"type": "Read", "surface": surface, "loc": {"line": name_token.line, "col": name_token.col}}
		var sk = kwargs.get("_skip")
		if sk is Dictionary and sk.get("type") == "Boolean" and sk.get("value") == true:
			node["_skip"] = true
		return node
	if lexeme == "read3d":
		var tex3d = _arg(args, 0)
		if tex3d == null:
			tex3d = kwargs.get("tex3d")
		var geo = _arg(args, 1)
		if geo == null:
			geo = kwargs.get("geo")
		var node := {"type": "Read3D", "tex3d": tex3d, "geo": (geo if geo != null else null), "loc": {"line": name_token.line, "col": name_token.col}}
		var sk = kwargs.get("_skip")
		if sk is Dictionary and sk.get("type") == "Boolean" and sk.get("value") == true:
			node["_skip"] = true
		return node
	return call

func _all_keys_in(d: Dictionary, allowed: Array) -> bool:
	for k in d.keys():
		if not allowed.has(k):
			return false
	return true

func _arg(args: Array, i: int):
	return args[i] if i < args.size() else null

func _parse_arg():
	return _parse_additive()

func _parse_additive():
	var node = _parse_multiplicative()
	while _peek().type == "PLUS" or _peek().type == "MINUS":
		var op: String = _advance().type
		var right = _parse_multiplicative()
		var l := _to_number(node)
		var r := _to_number(right)
		node = {"type": "Number", "value": (l + r if op == "PLUS" else l - r)}
	return node

func _parse_multiplicative():
	var node = _parse_unary()
	while _peek().type == "STAR" or _peek().type == "SLASH":
		var op: String = _advance().type
		var right = _parse_unary()
		var l := _to_number(node)
		var r := _to_number(right)
		node = {"type": "Number", "value": (l * r if op == "STAR" else l / r)}
	return node

func _parse_unary():
	if _peek().type == "PLUS":
		_advance()
		return _parse_unary()
	if _peek().type == "MINUS":
		_advance()
		var val = _parse_unary()
		return {"type": "Number", "value": -_to_number(val)}
	return _parse_primary()

func _parse_primary():
	var token = _peek()
	match token.type:
		"NUMBER":
			_advance()
			return {"type": "Number", "value": token.lexeme.to_float()}
		"STRING":
			_advance()
			return {"type": "String", "value": token.lexeme}
		"HEX":
			_advance()
			var hex: String = token.lexeme.substr(1)
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var a := 1.0
			if hex.length() == 3:
				r = float((hex[0] + hex[0]).hex_to_int())
				g = float((hex[1] + hex[1]).hex_to_int())
				b = float((hex[2] + hex[2]).hex_to_int())
			elif hex.length() == 6:
				r = float(hex.substr(0, 2).hex_to_int())
				g = float(hex.substr(2, 2).hex_to_int())
				b = float(hex.substr(4, 2).hex_to_int())
			elif hex.length() == 8:
				r = float(hex.substr(0, 2).hex_to_int())
				g = float(hex.substr(2, 2).hex_to_int())
				b = float(hex.substr(4, 2).hex_to_int())
				a = float(hex.substr(6, 2).hex_to_int()) / 255.0
			return {"type": "Color", "value": [r / 255.0, g / 255.0, b / 255.0, a]}
		"LBRACKET":
			var start_line: int = token.line
			var start_col: int = token.col
			_advance()
			var elements: Array = []
			if _peek().type != "RBRACKET":
				elements.push_back(_parse_arg())
				while _peek().type == "COMMA":
					_advance()
					elements.push_back(_parse_arg())
			if _peek().type != "RBRACKET":
				var t = _peek()
				_fail("Expected ']' at line %d col %d" % [t.line, t.col])
			else:
				_advance()
			return {"type": "ArrayLiteral", "elements": elements, "loc": {"line": start_line, "col": start_col}}
		"FUNC":
			_advance()
			return {"type": "Func", "src": token.lexeme}
		"TRUE":
			_advance()
			return {"type": "Boolean", "value": true}
		"FALSE":
			_advance()
			return {"type": "Boolean", "value": false}
		"IDENT":
			if token.lexeme == "Math" and _type_at(current + 1) == "DOT" and _type_at(current + 2) == "IDENT" and _tok(current + 2) != null and _tok(current + 2).lexeme == "PI":
				_advance(); _advance(); _advance()
				return {"type": "Number", "value": PI}
			if _type_at(current + 1) == "LPAREN" or _has_call_after_dot(current):
				var chain = _parse_chain("expression")
				return chain[0] if chain.size() == 1 else {"type": "Chain", "chain": chain}
			_advance()
			var path: Array = [token.lexeme]
			while _peek().type == "DOT":
				var next = _tok(current + 1)
				if next == null:
					break
				if _type_at(current + 2) == "LPAREN":
					break
				if not MEMBER_TOKENS.has(next.type):
					_fail("Expected identifier after '.' at line %d col %d" % [next.line, next.col])
					break
				_advance()  # consume '.'
				_advance()  # consume segment token
				path.push_back(next.lexeme)
			if path.size() > 1:
				return {"type": "Member", "path": path}
			return {"type": "Ident", "name": path[0]}
		"OUTPUT_REF":
			_advance()
			return {"type": "OutputRef", "name": token.lexeme}
		"SOURCE_REF":
			_advance()
			return {"type": "SourceRef", "name": token.lexeme}
		"VOL_REF":
			_advance()
			return {"type": "VolRef", "name": token.lexeme}
		"GEO_REF":
			_advance()
			return {"type": "GeoRef", "name": token.lexeme}
		"XYZ_REF":
			_advance()
			return {"type": "XyzRef", "name": token.lexeme}
		"VEL_REF":
			_advance()
			return {"type": "VelRef", "name": token.lexeme}
		"RGBA_REF":
			_advance()
			return {"type": "RgbaRef", "name": token.lexeme}
		"MESH_REF":
			_advance()
			return {"type": "MeshRef", "name": token.lexeme}
		"LPAREN":
			_advance()
			var expr = _parse_additive()
			_expect("RPAREN", "Expect ')'")
			return expr
	_fail("Unexpected token %s at line %d col %d" % [token.type, token.line, token.col])
	_advance()
	return {"type": "Ident", "name": ""}

func _to_number(node) -> float:
	if not (node is Dictionary) or node.get("type") != "Number":
		_fail("Expected number")
		return 0.0
	return float(node.get("value"))

func _parse_kwarg(obj: Dictionary) -> void:
	var key = _expect("IDENT", "Expected identifier").lexeme
	_expect("COLON", "Expect ':'")
	if not EXPR_START.has(_peek().type):
		var t = _peek()
		_fail("Expected expression after '=' at line %d col %d" % [t.line, t.col])
	obj[key] = _parse_arg()
